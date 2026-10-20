import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tamtoot/core/agents/agent_engine.dart';
import 'package:tamtoot/core/agents/agent_generation.dart';
import 'package:tamtoot/core/agents/model_client.dart';
import 'package:tamtoot/core/agents/model_profile.dart';
import 'explorer_test.dart' show RepositoryMemory;
import 'agent_engine_test.dart' show AgentGit, NoHooks;

ModelProfile localProfile([String format = 'chat-completions']) => ModelProfile(
  id: 'local',
  name: 'Local',
  provider: 'ollama',
  model: 'local-model',
  apiFormat: format,
  endpoint: 'http://192.168.0.85:11434/api/tags',
);
http.Response answer(
  String text, {
  String format = 'chat-completions',
  String finish = 'stop',
  String? reasoning,
}) => http.Response(
  jsonEncode(
    format == 'ollama'
        ? {
            'message': {'content': text, 'thinking': ?reasoning},
            'done_reason': finish,
          }
        : {
            'choices': [
              {
                'message': {'content': text, 'reasoning': ?reasoning},
                'finish_reason': finish,
              },
            ],
          },
  ),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
AgentTaskEngine engine(
  RepositoryMemory store,
  Future<http.Response> Function(http.Request) respond, {
  String format = 'chat-completions',
  List<AgentEvent>? events,
}) => AgentTaskEngine(
  profile: localProfile(format),
  store: store,
  git: AgentGit(),
  root: Uri.parse('memory:///project/'),
  apiKey: '',
  hooks: NoHooks(),
  onEvent: (e) => events?.add(e),
  approve: (_, _) async => true,
  clientFactory: () => ModelClient(client: MockClient(respond)),
);
void main() {
  for (final batch in [false, true]) {
    test(
      'missing ${batch ? "batch" : "single"} read recovers using actual library files',
      () async {
        final store = RepositoryMemory();
        await store.writeText(
          'Dialog.DAL.csproj',
          '<Project Sdk="Microsoft.NET.Sdk" />',
        );
        await store.writeText('Repository.cs', 'public class Repository {}');
        final actions = [
          batch
              ? {
                  'action': 'read_files',
                  'paths': ['Program.cs', 'Repository.cs'],
                }
              : {'action': 'read_file', 'path': 'Program.cs'},
          {'action': 'read_file', 'path': 'Dialog.DAL.csproj'},
          {'action': 'finish', 'summary': 'This project is a class library.'},
        ];
        final events = <AgentEvent>[];
        var requests = 0;
        final run = engine(store, (request) async {
          if (requests == 1) {
            expect(request.body, contains('does not exist'));
            expect(request.body, contains('Repository.cs'));
          }
          return answer(jsonEncode(actions[requests++]));
        }, events: events);
        final result = await run.run(
          'О чем этот проект',
          const AgentRunOptions(maxConsecutiveMistakes: 1),
        );
        expect(result.success, true);
        expect(requests, 3);
        expect(await store.exists('Program.cs'), false);
        expect(events.where((e) => e.type == 'error'), isEmpty);
      },
    );
  }

  test(
    'phase schema requires complete writes and excludes unavailable tools',
    () {
      final schema = AgentGeneration.schemaFor(
        allowedActions: {'write_file'},
        newPathPattern: r'^.+\.cs$',
      );
      final variants = schema['oneOf'] as List;
      expect(variants.length, 1);
      expect(variants.single['required'], ['action', 'path', 'content']);
      expect(variants.single['properties']['path']['pattern'], r'^.+\.cs$');
    },
  );
  test(
    'empty local project creates and verifies both C# 8 project files after malformed JSON',
    () async {
      final store = RepositoryMemory(), bodies = <Map<String, dynamic>>[];
      const project =
          '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><LangVersion>8.0</LangVersion></PropertyGroup></Project>';
      const program =
          'using System; class Program { static void Main() { Console.WriteLine("Привет мир"); } }';
      final actions = [
        'invalid JSON',
        jsonEncode({
          'action': 'write_file',
          'path': 'Hello.csproj',
          'content': project,
        }),
        jsonEncode({
          'action': 'write_file',
          'path': 'Program.cs',
          'content': program,
        }),
        jsonEncode({
          'action': 'read_files',
          'paths': ['Hello.csproj', 'Program.cs'],
        }),
        jsonEncode({
          'action': 'finish',
          'summary': 'Created project files; build not run.',
        }),
      ];
      final recorded = <AgentEvent>[];
      final run = engine(store, (request) async {
        expect(request.headers.containsKey('authorization'), false);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        expect(body['max_tokens'], 4096);
        expect(body['temperature'], 0.15);
        expect(body['stream'], false);
        expect(body['reasoning_effort'], 'none');
        for (final key in [
          'enable_thinking',
          'thinking',
          'chat_template_kwargs',
        ]) {
          expect(body.containsKey(key), false);
        }
        return answer(actions.removeAt(0));
      }, events: recorded);
      late final AgentRunResult result;
      try {
        result = await run.run(
          'Создай консольный проект C# 8 с Привет мир',
          const AgentRunOptions(yolo: false),
        );
      } catch (e) {
        fail('$e\n${recorded.map((e) => '${e.type}: ${e.text}').join('\n')}');
      }
      expect(result.success, true);
      expect(await store.readText('Hello.csproj'), project);
      expect(await store.readText('Program.cs'), program);
      expect(jsonEncode(bodies.first), contains('Project is empty'));
      expect(
        jsonEncode(bodies[1]).length,
        lessThan(jsonEncode(bodies[0]).length),
      );
      expect(result.message, contains('build not run'));
      expect(actions, isEmpty);
    },
  );
  test(
    'reasoning-only actions are never executed and recovery stops after two calls',
    () async {
      for (final format in ['chat-completions', 'ollama']) {
        var requests = 0;
        final store = RepositoryMemory(), events = <AgentEvent>[];
        final run = engine(
          store,
          (request) async {
            requests++;
            expect(request.body, isNot(contains('secret-reasoning-marker')));
            return answer(
              '',
              format: format,
              finish: 'length',
              reasoning:
                  '{"action":"write_file","path":"injected.txt","content":"secret-reasoning-marker"}',
            );
          },
          format: format,
          events: events,
        );
        await expectLater(
          run.run('Create a text file', const AgentRunOptions()),
          throwsA(isA<ModelEmptyAnswerException>()),
        );
        expect(requests, 2);
        expect(await store.exists('injected.txt'), false);
        expect(
          events.map((e) => e.text).join(),
          isNot(contains('secret-reasoning-marker')),
        );
      }
    },
  );
  test(
    'truncated JSON cannot write a partial file and gets a minimal repair',
    () async {
      final store = RepositoryMemory(), bodies = <String>[];
      final actions = [
        '{"action":"write_file","path":"partial.txt","content":"oops',
        '{"action":"finish","summary":"No writes performed"}',
      ];
      final run = engine(store, (request) async {
        bodies.add(request.body);
        return answer(
          actions.removeAt(0),
          finish: bodies.length == 1 ? 'length' : 'stop',
        );
      });
      expect(
        (await run.run('Create a file', const AgentRunOptions())).success,
        true,
      );
      expect(await store.exists('partial.txt'), false);
      expect(bodies[1], contains('truncated'));
      expect(bodies[1].length, lessThan(bodies[0].length));
    },
  );
  test(
    'native Ollama schema/temperature/thinking settings are in documented fields',
    () async {
      final run = engine(RepositoryMemory(), (request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(
          body['format'],
          AgentGeneration.schemaFor(
            allowedActions: AgentGeneration.actionNames
                .where((a) => a != 'list_files' && a != 'search_files')
                .toSet(),
          ),
        );
        expect(body['think'], false);
        expect(body['stream'], false);
        expect(body['options']['num_predict'], 6144);
        expect(body['options']['temperature'], 0.2);
        expect(body['options'].containsKey('format'), false);
        expect(body['options'].containsKey('think'), false);
        return answer('{"action":"finish","summary":"done"}', format: 'ollama');
      }, format: 'ollama');
      await run.run(
        'Say hello',
        const AgentRunOptions(
          localMaxTokens: 6144,
          localTemperature: 0.2,
          localResponseFormat: 'json_schema',
        ),
      );
    },
  );
  test('schema rejection falls back once to JSON Object then text', () async {
    final modes = <dynamic>[];
    final run = engine(RepositoryMemory(), (request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      modes.add(body['response_format']);
      if (modes.length < 3) {
        return http.Response(
          jsonEncode({
            'error': {'message': 'response_format unsupported'},
          }),
          400,
        );
      }
      return answer('{"action":"finish","summary":"done"}');
    });
    expect(
      (await run.run(
        'Say hello',
        const AgentRunOptions(localResponseFormat: 'json_schema'),
      )).success,
      true,
    );
    expect(modes[0]['type'], 'json_schema');
    expect(modes[1], {'type': 'json_object'});
    expect(modes[2], null);
  });
  test(
    'invalid required fields cannot invoke tools and retries are bounded',
    () async {
      var requests = 0;
      final store = RepositoryMemory();
      final run = engine(store, (_) async {
        requests++;
        return answer('{"action":"write_file","path":"bad.txt"}');
      });
      await expectLater(
        run.run(
          'Create a file',
          const AgentRunOptions(maxConsecutiveMistakes: 2),
        ),
        throwsA(isA<ModelApiException>()),
      );
      expect(requests, 2);
      expect(await store.exists('bad.txt'), false);
    },
  );
}
