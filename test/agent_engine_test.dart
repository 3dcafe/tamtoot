import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tamtoot/core/agents/agent_engine.dart';
import 'package:tamtoot/core/agents/model_client.dart';
import 'package:tamtoot/core/agents/model_attachment.dart';
import 'package:tamtoot/core/agents/model_profile.dart';
import 'package:tamtoot/core/agents/project_memory.dart';
import 'package:tamtoot/core/agents/hook_runner.dart';
import 'package:tamtoot/core/agents/command_runner.dart';
import 'package:tamtoot/core/git/git_service.dart';
import 'explorer_test.dart' show RepositoryMemory;

class AgentGit implements GitService {
  AgentGit({this.dirty = false});
  final bool dirty;
  @override
  bool get available => true;
  @override
  Future<List<GitStatusEntry>> statusEntries(Uri directory) async =>
      dirty ? [const GitStatusEntry(' ', 'M', 'a.txt')] : [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class NoHooks extends AgentHookRunner {
  NoHooks() : super(Uri());
  @override
  Future<HookResult> run(String type, Map<String, dynamic> input) async =>
      const HookResult();
}

class FakeCommands extends AgentCommandRunner {
  FakeCommands() : super(Uri());
  int calls = 0;
  @override
  Future<AgentCommandResult> run(
    String executable,
    List<String> arguments,
  ) async {
    calls++;
    return const AgentCommandResult(0, 'unexpected');
  }
}

ModelProfile agentProfile() => ModelProfile(
  id: 'agent',
  name: 'Agent',
  provider: 'test',
  model: 'model',
  endpoint: 'https://example.test/v1/chat/completions',
);

ModelClient queueClient(List<String> actions) => ModelClient(
  client: MockClient((request) async {
    final next = actions.removeAt(0);
    return http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'content': next},
            'finish_reason': 'stop',
          },
        ],
      }),
      200,
    );
  }),
);

void main() {
  final root = Uri.parse('memory:///project/');
  test(
    'enhanced privacy sends minimal context and restores hosts before edits',
    () async {
      final store = RepositoryMemory();
      const original = 'const endpoint = "https://customer.example.com/v1";';
      await store.writeText(
        'lib/a.dart',
        [original, ...List.generate(60, (i) => '// line ${i + 2}')].join('\n'),
      );
      await store.writeText(
        'docs/private.md',
        'unrelated documentation secret',
      );
      final oldMemory = ProjectMemory().encode();
      await store.writeText(ProjectMemory.storePath, oldMemory);
      final bodies = <String>[];
      var turn = 0;
      ModelClient client() => ModelClient(
        client: MockClient((request) async {
          bodies.add(request.body);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final text = (body['messages'] as List).last['content'] as String;
          late Map<String, dynamic> action;
          if (turn == 0) {
            expect(request.body, isNot(contains('Project file index')));
            expect(request.body, isNot(contains('docs/private.md')));
            expect(request.body, isNot(contains('custom project secret')));
            action = {
              'action': 'read_files',
              'paths': ['lib/a.dart', 'docs/private.md'],
              'lineCount': 500,
            };
          } else if (turn == 1) {
            expect(text, contains('// line 40'));
            expect(text, isNot(contains('// line 41')));
            expect(text, isNot(contains('unrelated documentation secret')));
            final alias = RegExp(
              r'https://(private-[a-z0-9-]+\.invalid)/v1',
            ).firstMatch(text)!.group(1)!;
            action = {
              'action': 'replace_in_file',
              'path': 'lib/a.dart',
              'oldText': 'const endpoint = "https://$alias/v1";',
              'newText': 'const endpoint = "https://$alias/v2";',
            };
          } else {
            action = {'action': 'finish', 'summary': 'Updated endpoint path.'};
          }
          turn++;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': jsonEncode(action)},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        }),
      );
      final engine = AgentTaskEngine(
        profile: ModelProfile(
          id: 'private',
          name: 'Private',
          provider: 'test',
          model: 'model',
          endpoint: 'https://example.test/v1/chat/completions',
          systemPrompt: 'custom project secret https://internal.example.com',
        ),
        store: store,
        git: AgentGit(),
        root: root,
        apiKey: '',
        onEvent: (_) {},
        approve: (_, _) async => true,
        clientFactory: client,
        hooks: NoHooks(),
        commands: FakeCommands(),
      );
      final result = await engine.run(
        'Update the path for customer.example.com',
        const AgentRunOptions(enhancedPrivacy: true),
      );
      expect(result.success, isTrue);
      expect(bodies, hasLength(3));
      for (final body in bodies) {
        expect(body, isNot(contains('customer.example.com')));
        expect(body, isNot(contains('internal.example.com')));
        expect(body, isNot(contains('unrelated documentation secret')));
      }
      expect(
        await store.readText('lib/a.dart'),
        startsWith('const endpoint = "https://customer.example.com/v2";'),
      );
      expect(await store.readText(ProjectMemory.storePath), oldMemory);
    },
  );

  test(
    'agent sends attachments once and retains investigation context',
    () async {
      final store = RepositoryMemory();
      await store.writeText(
        'lib/target.dart',
        'const needle = "project-value";',
      );
      await store.writeText('lib/unrelated.dart', 'const other = 1;');
      final bodies = <Map<String, dynamic>>[];
      final actions = [
        '{"action":"search_files","query":"needle","path":"lib"}',
        '{"action":"read_file","path":"lib/target.dart"}',
        '{"action":"finish","summary":"Inspected the relevant file."}',
      ];
      ModelClient client() => ModelClient(
        client: MockClient((request) async {
          bodies.add(
            Map<String, dynamic>.from(
              jsonDecode(request.body) as Map<String, dynamic>,
            ),
          );
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': actions.removeAt(0)},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        }),
      );
      final engine = AgentTaskEngine(
        profile: agentProfile(),
        store: store,
        git: AgentGit(),
        root: root,
        apiKey: '',
        attachments: [
          ModelAttachment(
            name: 'brief.txt',
            mimeType: 'text/plain',
            bytes: Uint8List.fromList(utf8.encode('unique-attachment-context')),
          ),
        ],
        onEvent: (_) {},
        approve: (_, _) async => true,
        clientFactory: client,
        hooks: NoHooks(),
        commands: FakeCommands(),
      );

      final result = await engine.run(
        'Inspect needle',
        const AgentRunOptions(),
      );

      expect(result.success, isTrue);
      expect(bodies, hasLength(3));
      expect(jsonEncode(bodies[0]), contains('unique-attachment-context'));
      expect(jsonEncode(bodies[0]), contains('Project file index'));
      expect(
        jsonEncode(bodies[1]),
        isNot(contains('unique-attachment-context')),
      );
      expect(jsonEncode(bodies[1]), contains('lib/target.dart:1'));
      expect(jsonEncode(bodies[1]), contains('already provided once'));
      expect(jsonEncode(bodies[2]), contains('project-value'));
      expect(jsonEncode(bodies[2]), contains('Search lib::needle'));
    },
  );

  test(
    'agent can replace an exact fragment without rewriting a file',
    () async {
      final store = RepositoryMemory();
      await store.writeText(
        'lib/example.dart',
        'class Example {\n  final value = 1;\n}\n',
      );
      final actions = [
        '{"action":"read_file","path":"lib/example.dart"}',
        '{"action":"replace_in_file","path":"lib/example.dart",'
            '"oldText":"final value = 1;","newText":"final value = 2;"}',
        '{"action":"read_file","path":"lib/example.dart"}',
        '{"action":"finish","summary":"Updated the value."}',
      ];
      var approvals = 0;
      final engine = AgentTaskEngine(
        profile: agentProfile(),
        store: store,
        git: AgentGit(),
        root: root,
        apiKey: '',
        onEvent: (_) {},
        approve: (action, _) async {
          expect(action, 'replace_in_file');
          approvals++;
          return true;
        },
        clientFactory: () => queueClient(actions),
        hooks: NoHooks(),
        commands: FakeCommands(),
      );

      final result = await engine.run(
        'Change the value',
        const AgentRunOptions(yolo: false),
      );

      expect(result.success, isTrue);
      expect(await store.readText('lib/example.dart'), contains('value = 2'));
      expect(approvals, 1);
    },
  );

  test(
    'agent batches several files with read_files in one iteration',
    () async {
      final store = RepositoryMemory();
      await store.writeText('lib/a.dart', 'const alpha = "A";');
      await store.writeText('lib/b.dart', 'const beta = "B";');
      final bodies = <String>[];
      final events = <AgentEvent>[];
      final actions = [
        '{"action":"read_files","paths":["lib/a.dart","lib/b.dart"]}',
        '{"action":"finish","summary":"Loaded both files."}',
      ];
      ModelClient client() => ModelClient(
        client: MockClient((request) async {
          bodies.add(request.body);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': actions.removeAt(0)},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        }),
      );
      final engine = AgentTaskEngine(
        profile: agentProfile(),
        store: store,
        git: AgentGit(),
        root: root,
        apiKey: '',
        onEvent: events.add,
        approve: (_, _) async => true,
        clientFactory: client,
        hooks: NoHooks(),
        commands: FakeCommands(),
      );

      final result = await engine.run(
        'Read both helpers',
        const AgentRunOptions(),
      );

      expect(result.success, isTrue);
      expect(
        events.map((event) => event.text),
        contains(contains('Read 2 files')),
      );
      expect(bodies, hasLength(2));
      expect(bodies[1], contains('lib/a.dart'));
      expect(bodies[1], contains('const alpha'));
      expect(bodies[1], contains('lib/b.dart'));
      expect(bodies[1], contains('const beta'));
      expect(bodies[1], contains('Active file context'));
    },
  );

  test(
    'agent accepts the first JSON object when the model emits NDJSON',
    () async {
      final store = RepositoryMemory();
      await store.writeText('a.txt', 'content');
      final events = <AgentEvent>[];
      final actions = [
        '{\n"action":"list_files","path":"."\n}\n{"action":"read_file","path":"a.txt"}',
        '{"action":"finish","summary":"ok"}',
      ];
      final engine = AgentTaskEngine(
        profile: agentProfile(),
        store: store,
        git: AgentGit(),
        root: root,
        apiKey: '',
        onEvent: events.add,
        approve: (_, _) async => true,
        clientFactory: () => queueClient(actions),
        hooks: NoHooks(),
        commands: FakeCommands(),
      );

      final result = await engine.run('Inspect', const AgentRunOptions());
      expect(result.success, isTrue);
      expect(events.map((event) => event.text), contains('Listed .'));
      expect(
        events.where((event) => event.type == 'error'),
        isEmpty,
        reason: 'extra JSON lines must not crash the action decoder',
      );
    },
  );

  test('agent accepts dot as the project root when listing files', () async {
    final store = RepositoryMemory();
    await store.writeText('a.txt', 'content');
    final events = <AgentEvent>[];
    final actions = [
      '{"action":"list_files","path":"."}',
      '{"action":"finish","summary":"Inspected project root"}',
    ];
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => true,
      clientFactory: () => queueClient(actions),
      hooks: NoHooks(),
      commands: FakeCommands(),
    );

    final result = await engine.run('Inspect files', const AgentRunOptions());

    expect(result.success, isTrue);
    expect(events.map((event) => event.text), contains('Listed .'));
    expect(events.where((event) => event.type == 'model'), isNotEmpty);
  });

  test('agent reads, asks before writing, writes and finishes', () async {
    final store = RepositoryMemory();
    await store.writeText('a.txt', 'before');
    final actions = [
      '{"action":"read_file","path":"a.txt"}',
      '{"action":"write_file","path":"a.txt","content":"after"}',
      '{"action":"read_file","path":"a.txt"}',
      '{"action":"finish","summary":"Updated a.txt"}',
    ];
    final events = <AgentEvent>[];
    var approvals = 0;
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (action, arguments) async {
        if (action == 'write_file') approvals++;
        expect(action, 'write_file');
        return true;
      },
      clientFactory: () => queueClient(actions),
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    final result = await engine.run(
      'Update it',
      const AgentRunOptions(yolo: false),
    );
    expect(result.success, isTrue);
    expect(await store.readText('a.txt'), 'after');
    expect(approvals, 1);
    expect(events.map((e) => e.type), containsAll(['tool', 'done']));
  });

  test('agent never executes a command proposed by the model', () async {
    final commands = FakeCommands();
    final events = <AgentEvent>[];
    final actions = [
      '{"action":"run_command","executable":"flutter","args":["test"]}',
      '{"action":"finish","summary":"Finished without runtime checks"}',
    ];
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: RepositoryMemory(),
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => throw StateError('must not ask'),
      clientFactory: () => queueClient(actions),
      hooks: NoHooks(),
      commands: commands,
    );

    final result = await engine.run('Inspect only', const AgentRunOptions());

    expect(result.success, isTrue);
    expect(commands.calls, 0);
    expect(
      events.map((event) => event.text),
      contains(
        'Command skipped: this mobile IDE has no runtime or test runner.',
      ),
    );
  });

  test('YOLO writes with uncommitted Git changes without approval', () async {
    final store = RepositoryMemory();
    final actions = [
      '{"action":"write_file","path":"new.txt","content":"created"}',
      '{"action":"finish","summary":"done"}',
    ];
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(dirty: true),
      root: root,
      apiKey: '',
      onEvent: (_) {},
      approve: (_, _) async => throw StateError('must not ask'),
      clientFactory: () => queueClient(actions),
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    await engine.run('Create', const AgentRunOptions(yolo: true));
    expect(await store.readText('new.txt'), 'created');
  });

  test('agent rejects protected paths and stops after mistake limit', () async {
    final actions = ['{"action":"read_file","path":"../secret"}'];
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: RepositoryMemory(),
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: (_) {},
      approve: (_, _) async => true,
      clientFactory: () => queueClient(actions),
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    await expectLater(
      engine.run('Read', const AgentRunOptions(maxConsecutiveMistakes: 1)),
      throwsA(
        isA<ModelApiException>().having(
          (e) => e.message,
          'message',
          contains('consecutive mistakes'),
        ),
      ),
    );
  });

  test('agent rejects repeated say without tools', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/a.dart', 'const x = 1;');
    final events = <AgentEvent>[];
    final actions = [
      '{"action":"say","text":"Plan: edit a.dart"}',
      '{"action":"say","text":"Still planning"}',
      '{"action":"say","text":"Planning again"}',
      '{"action":"say","text":"And again"}',
    ];
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => true,
      clientFactory: () => queueClient(actions),
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    await expectLater(
      engine.run(
        'Edit a',
        const AgentRunOptions(maxConsecutiveMistakes: 2, maxIterations: 8),
      ),
      throwsA(
        isA<ModelApiException>().having(
          (e) => e.message,
          'message',
          contains('consecutive mistakes'),
        ),
      ),
    );
    expect(
      events.where((event) => event.type == 'error').map((e) => e.text),
      anyElement(contains('Repeated say')),
    );
  });

  test('agent compacts project index after the first tool', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/a.dart', 'const needle = 1;');
    final bodies = <String>[];
    final actions = [
      '{"action":"search_files","query":"needle","path":"lib"}',
      '{"action":"finish","summary":"done"}',
    ];
    ModelClient client() => ModelClient(
      client: MockClient((request) async {
        bodies.add(request.body);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': actions.removeAt(0)},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: (_) {},
      approve: (_, _) async => true,
      clientFactory: client,
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    await engine.run('Find', const AgentRunOptions());
    expect(bodies[0], contains('Project file index'));
    expect(bodies[0], isNot(contains('already provided once')));
    expect(bodies[1], contains('already provided once'));
  });

  test('agent blocks a third consecutive search_files', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/a.dart', 'const alpha = 1;');
    final events = <AgentEvent>[];
    final bodies = <String>[];
    final actions = [
      '{"action":"search_files","query":"zzzone","path":"lib"}',
      '{"action":"search_files","query":"zzztwo","path":"lib"}',
      '{"action":"search_files","query":"zzzthree","path":"lib"}',
      '{"action":"finish","summary":"done"}',
    ];
    ModelClient client() => ModelClient(
      client: MockClient((request) async {
        bodies.add(request.body);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': actions.removeAt(0)},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => true,
      clientFactory: client,
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    final result = await engine.run(
      'Find symbols',
      const AgentRunOptions(maxConsecutiveMistakes: 3, maxIterations: 10),
    );
    expect(result.success, isTrue);
    expect(
      events.where((event) => event.type == 'denied').map((e) => e.text),
      anyElement(contains('search_files blocked')),
    );
    expect(bodies[3], contains('Search rejected'));
    expect(bodies[3], contains('2 search_files'));
  });

  test('agent soft-rejects duplicate search with known matches', () async {
    final store = RepositoryMemory();
    await store.writeText(
      'lib/session_commands.dart',
      '${List.generate(80, (i) => 'line${i + 1};').join('\n')}\n'
          'documents.open();\n'
          'documents.open();\n',
    );
    final events = <AgentEvent>[];
    final bodies = <String>[];
    final actions = [
      '{"action":"search_files","query":"documents.open","path":"lib"}',
      '{"action":"search_files","query":"documents.open","path":"lib"}',
      '{"action":"read_file","path":"lib/session_commands.dart"}',
      '{"action":"finish","summary":"done"}',
    ];
    ModelClient client() => ModelClient(
      client: MockClient((request) async {
        bodies.add(request.body);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': actions.removeAt(0)},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => true,
      clientFactory: client,
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    final result = await engine.run(
      'Open documents',
      const AgentRunOptions(maxConsecutiveMistakes: 1, maxIterations: 10),
    );
    expect(result.success, isTrue);
    expect(bodies[2], contains('Search rejected'));
    expect(bodies[2], contains('already searched'));
    expect(bodies[2], contains('Known matches'));
    expect(bodies[2], contains('session_commands.dart'));
    expect(events.where((e) => e.type == 'error'), isEmpty);
  });

  test('agent reads around search match lines not from line 1', () async {
    final store = RepositoryMemory();
    final lines = [
      for (var i = 1; i <= 120; i++)
        i == 59 ? 'const targetMarker = 1;' : 'const filler$i = $i;',
    ];
    await store.writeText('lib/session_commands.dart', lines.join('\n'));
    final bodies = <String>[];
    final actions = [
      '{"action":"search_files","query":"targetMarker","path":"lib"}',
      '{"action":"read_file","path":"lib/session_commands.dart"}',
      '{"action":"finish","summary":"done"}',
    ];
    ModelClient client() => ModelClient(
      client: MockClient((request) async {
        bodies.add(request.body);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': actions.removeAt(0)},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: (_) {},
      approve: (_, _) async => true,
      clientFactory: client,
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    await engine.run('Find marker', const AgentRunOptions());
    expect(bodies[2], contains('targetMarker'));
    expect(bodies[2], contains('around search matches'));
    expect(bodies[2], isNot(contains('filler1 =')));
    expect(bodies[2], contains('filler39'));
  });

  test('agent rejects similar search queries', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/a.dart', 'const x = 1;');
    final events = <AgentEvent>[];
    final bodies = <String>[];
    final actions = [
      '{"action":"search_files","query":"locked input","path":"lib"}',
      '{"action":"search_files","query":"locked input field","path":"lib"}',
      '{"action":"finish","summary":"done"}',
    ];
    ModelClient client() => ModelClient(
      client: MockClient((request) async {
        bodies.add(request.body);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': actions.removeAt(0)},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => true,
      clientFactory: client,
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    final result = await engine.run(
      'Find lock',
      const AgentRunOptions(maxConsecutiveMistakes: 1, maxIterations: 10),
    );
    expect(result.success, isTrue);
    expect(bodies[2], contains('Search rejected'));
    expect(events.where((e) => e.type == 'error'), isEmpty);
  });

  test('agent requires read after search hits before another search', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/target.dart', 'const TextField = 1;');
    final events = <AgentEvent>[];
    final bodies = <String>[];
    final actions = [
      '{"action":"search_files","query":"TextField","path":"lib"}',
      '{"action":"search_files","query":"AgentDialog","path":"lib"}',
      '{"action":"read_file","path":"lib/target.dart"}',
      '{"action":"finish","summary":"done"}',
    ];
    ModelClient client() => ModelClient(
      client: MockClient((request) async {
        bodies.add(request.body);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': actions.removeAt(0)},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => true,
      clientFactory: client,
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    final result = await engine.run(
      'Inspect TextField',
      const AgentRunOptions(maxConsecutiveMistakes: 1, maxIterations: 10),
    );
    expect(result.success, isTrue);
    expect(bodies[2], contains('Search rejected'));
    expect(bodies[2], contains('≤4 implementation'));
    expect(events.where((e) => e.type == 'error'), isEmpty);
  });

  test(
    'agent injects investigation budget after two searches and reads',
    () async {
      final store = RepositoryMemory();
      await store.writeText('lib/a.dart', 'const alpha = 1;');
      await store.writeText('lib/b.dart', 'const beta = 2;');
      final bodies = <String>[];
      final actions = [
        '{"action":"search_files","query":"alpha","path":"lib"}',
        '{"action":"read_file","path":"lib/a.dart"}',
        '{"action":"search_files","query":"beta","path":"lib"}',
        '{"action":"read_file","path":"lib/b.dart"}',
        '{"action":"replace_in_file","path":"lib/a.dart","oldText":"const alpha = 1;","newText":"const alpha = 2;"}',
        '{"action":"finish","summary":"done"}',
      ];
      ModelClient client() => ModelClient(
        client: MockClient((request) async {
          bodies.add(request.body);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': actions.removeAt(0)},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        }),
      );
      final engine = AgentTaskEngine(
        profile: agentProfile(),
        store: store,
        git: AgentGit(),
        root: root,
        apiKey: '',
        onEvent: (_) {},
        approve: (_, _) async => true,
        clientFactory: client,
        hooks: NoHooks(),
        commands: FakeCommands(),
      );
      await engine.run('Fix alpha', const AgentRunOptions(yolo: false));
      expect(bodies[4], contains('Investigation budget reached'));
      expect(bodies[4], contains('replace_in_file'));
    },
  );

  test('agent blocks fourth search before first edit', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/a.dart', 'one two three four');
    final bodies = <String>[];
    final events = <AgentEvent>[];
    final actions = [
      '{"action":"search_files","query":"one","path":"lib"}',
      '{"action":"read_file","path":"lib/a.dart"}',
      '{"action":"search_files","query":"two","path":"lib"}',
      '{"action":"read_file","path":"lib/a.dart"}',
      '{"action":"search_files","query":"three","path":"lib"}',
      '{"action":"search_files","query":"four","path":"lib"}',
      '{"action":"replace_in_file","path":"lib/a.dart","oldText":"one","newText":"ONE"}',
      '{"action":"finish","summary":"done"}',
    ];
    ModelClient client() => ModelClient(
      client: MockClient((request) async {
        bodies.add(request.body);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': actions.removeAt(0)},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => true,
      clientFactory: client,
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    await engine.run(
      'Fix',
      const AgentRunOptions(yolo: false, maxConsecutiveMistakes: 3),
    );
    expect(bodies[5], contains('Investigation budget reached'));
    expect(
      events.where((event) => event.type == 'denied').map((e) => e.text),
      anyElement(contains('search_files blocked')),
    );
    expect(events.where((e) => e.type == 'error'), isEmpty);
  });

  test(
    'agent recovers from empty model answers within mistake budget',
    () async {
      final store = RepositoryMemory();
      await store.writeText('lib/a.dart', 'const x = 1;');
      final events = <AgentEvent>[];
      final actions = <String?>[
        null, // force empty answer once
        '{"action":"finish","summary":"recovered"}',
      ];
      ModelClient client() => ModelClient(
        client: MockClient((request) async {
          final next = actions.removeAt(0);
          if (next == null) {
            return http.Response(
              jsonEncode({
                'model': 'glm-5.3-flash',
                'choices': [
                  {
                    'finish_reason': 'length',
                    'message': {'role': 'assistant', 'content': ''},
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': next},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        }),
      );
      final engine = AgentTaskEngine(
        profile: agentProfile(),
        store: store,
        git: AgentGit(),
        root: root,
        apiKey: '',
        onEvent: events.add,
        approve: (_, _) async => true,
        clientFactory: client,
        hooks: NoHooks(),
        commands: FakeCommands(),
      );
      final result = await engine.run(
        'Recover',
        const AgentRunOptions(maxConsecutiveMistakes: 2),
      );
      expect(result.success, isTrue);
      expect(
        events.where((e) => e.type == 'error').map((e) => e.text),
        anyElement(contains('finish_reason: length')),
      );
    },
  );

  test('agent recovers from truncated replace_in_file JSON', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/a.dart', 'class A {\n  final value = 1;\n}\n');
    final events = <AgentEvent>[];
    final actions = [
      // Truncated mid-string like a max_tokens cut.
      '{"action":"replace_in_file","path":"lib/a.dart","oldText":"final value = 1;","newText":"/// huge rewrite that never finishes',
      '{"action":"replace_in_file","path":"lib/a.dart","oldText":"final value = 1;","newText":"final value = 2;"}',
      '{"action":"finish","summary":"Small edit applied."}',
    ];
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => true,
      clientFactory: () => queueClient(actions),
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    final result = await engine.run(
      'Bump value',
      const AgentRunOptions(yolo: false, maxConsecutiveMistakes: 2),
    );
    expect(result.success, isTrue);
    expect(await store.readText('lib/a.dart'), contains('value = 2'));
    expect(
      events.where((e) => e.type == 'error').map((e) => e.text),
      anyElement(contains('truncated')),
    );
  });

  test('agent rejects oversized replace_in_file fragments', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/a.dart', 'const x = 1;');
    final events = <AgentEvent>[];
    final huge = 'x' * (AgentTaskEngine.maxReplaceFragmentCharacters + 50);
    final actions = [
      '{"action":"replace_in_file","path":"lib/a.dart","oldText":"const x = 1;","newText":"$huge"}',
      '{"action":"replace_in_file","path":"lib/a.dart","oldText":"const x = 1;","newText":"const x = 2;"}',
      '{"action":"finish","summary":"done"}',
    ];
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => true,
      clientFactory: () => queueClient(actions),
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    final result = await engine.run(
      'Edit',
      const AgentRunOptions(yolo: false, maxConsecutiveMistakes: 2),
    );
    expect(result.success, isTrue);
    expect(
      events.where((e) => e.type == 'error').map((e) => e.text),
      anyElement(contains('too large')),
    );
  });

  test('agent caps max_tokens for JSON actions', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/a.dart', 'const x = 1;');
    final bodies = <Map<String, dynamic>>[];
    final actions = ['{"action":"finish","summary":"done"}'];
    ModelClient client() => ModelClient(
      client: MockClient((request) async {
        bodies.add(
          Map<String, dynamic>.from(
            jsonDecode(request.body) as Map<String, dynamic>,
          ),
        );
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': actions.removeAt(0)},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );
    final engine = AgentTaskEngine(
      profile: ModelProfile(
        id: 'agent',
        name: 'Agent',
        provider: 'ai-star',
        model: 'glm-5.3-flash',
        endpoint: 'https://example.test/v1/chat/completions',
        parameters: const {'temperature': 0.1, 'max_tokens': 8192},
      ),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: (_) {},
      approve: (_, _) async => true,
      clientFactory: client,
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    await engine.run('Done', const AgentRunOptions());
    expect(bodies.single['max_tokens'], AgentTaskEngine.agentActionTokens);
    expect(bodies.single['enable_thinking'], isFalse);
    expect(bodies.single['thinking'], {'type': 'disabled'});
    expect(bodies.single['response_format'], {'type': 'json_object'});
  });

  test('empty content triggers a cheap recovery request', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/a.dart', 'const x = 1;');
    final bodies = <Map<String, dynamic>>[];
    final actions = <String?>[
      null, // reasoning-only failure
      '{"action":"finish","summary":"recovered"}',
    ];
    ModelClient client() => ModelClient(
      client: MockClient((request) async {
        bodies.add(
          Map<String, dynamic>.from(
            jsonDecode(request.body) as Map<String, dynamic>,
          ),
        );
        final next = actions.removeAt(0);
        if (next == null) {
          return http.Response(
            jsonEncode({
              'model': 'glm-5.3-flash',
              'choices': [
                {
                  'finish_reason': 'length',
                  'message': {
                    'role': 'assistant',
                    'content': '',
                    'reasoning_content':
                        'Long analysis mentioning unrepeatable-reasoning-marker.',
                  },
                },
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': next},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );
    final engine = AgentTaskEngine(
      profile: ModelProfile(
        id: 'agent',
        name: 'Agent',
        provider: 'ai-star',
        model: 'glm-5.3-flash',
        endpoint: 'https://example.test/v1/chat/completions',
      ),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: (_) {},
      approve: (_, _) async => true,
      clientFactory: client,
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    final result = await engine.run(
      'Recover',
      const AgentRunOptions(maxConsecutiveMistakes: 1),
    );
    expect(result.success, isTrue);
    expect(bodies, hasLength(2));
    // Recovery stays cheap in both directions and never echoes the reasoning.
    expect(bodies[1]['max_tokens'], AgentTaskEngine.agentRecoveryTokens);
    expect(
      jsonEncode(bodies[1]),
      isNot(contains('unrepeatable-reasoning-marker')),
    );
    expect(jsonEncode(bodies[1]), isNot(contains('Project file index')));
    expect(jsonEncode(bodies[1]), contains('Return the next action only'));
    expect(
      jsonEncode(bodies[1]).length,
      lessThan(jsonEncode(bodies[0]).length),
    );
  });

  test('investigation budget narrows read_files instead of denying it', () async {
    final store = RepositoryMemory();
    for (final name in ['a', 'b', 'c', 'd']) {
      await store.writeText(
        'lib/$name.dart',
        List.generate(200, (i) => 'const ${name}_$i = $i;').join('\n'),
      );
    }
    final events = <AgentEvent>[];
    final actions = [
      '{"action":"search_files","query":"a_0","path":"lib"}',
      '{"action":"read_file","path":"lib/a.dart","startLine":1,"lineCount":200}',
      '{"action":"search_files","query":"b_0","path":"lib"}',
      '{"action":"read_file","path":"lib/b.dart","startLine":1,"lineCount":200}',
      '{"action":"read_file","path":"lib/c.dart","startLine":1,"lineCount":200}',
      '{"action":"read_files","paths":["lib/a.dart","lib/b.dart","lib/c.dart","lib/d.dart"],'
          '"startLine":1,"lineCount":200}',
      '{"action":"replace_in_file","path":"lib/c.dart",'
          '"oldText":"const c_0 = 0;","newText":"const c_0 = 1;"}',
      '{"action":"finish","summary":"done"}',
    ];
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => true,
      clientFactory: () => queueClient(actions),
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    final result = await engine.run(
      'Fix c',
      const AgentRunOptions(
        yolo: false,
        maxConsecutiveMistakes: 1,
        maxReadsBeforeFirstEdit: 3,
      ),
    );
    expect(result.success, isTrue);
    expect(actions, isEmpty, reason: 'no action may be denied and repeated');
    expect(
      events.where((e) => e.type == 'denied'),
      isEmpty,
      reason: 'reads are narrowed, not blocked',
    );
    expect(
      events.map((e) => e.text),
      contains(
        contains(
          'Final targeted read: max ${AgentTaskEngine.maxFinalReadFiles} files',
        ),
      ),
    );
    expect(
      events.map((e) => e.text),
      contains(contains('Read ${AgentTaskEngine.maxFinalReadFiles} files')),
    );
  });

  test(
    'blocked read in NDJSON yields the following edit from the same reply',
    () async {
      final store = RepositoryMemory();
      for (final name in ['a', 'b', 'c']) {
        await store.writeText(
          'lib/$name.dart',
          List.generate(40, (i) => 'const ${name}_$i = $i;').join('\n'),
        );
      }
      final events = <AgentEvent>[];
      final actions = [
        '{"action":"search_files","query":"a_0","path":"lib"}',
        '{"action":"read_file","path":"lib/a.dart"}',
        '{"action":"search_files","query":"b_0","path":"lib"}',
        '{"action":"read_file","path":"lib/b.dart"}',
        // Budget reached (2 reads); this consumes the one final targeted read.
        '{"action":"read_file","path":"lib/c.dart"}',
        // Another read would be blocked — but the same reply also has an edit.
        '{"action":"read_file","path":"lib/c.dart","startLine":1,"lineCount":60}\n'
            '{"action":"replace_in_file","path":"lib/c.dart",'
            '"oldText":"const c_0 = 0;","newText":"const c_0 = 1;"}',
        '{"action":"finish","summary":"done"}',
      ];
      final engine = AgentTaskEngine(
        profile: agentProfile(),
        store: store,
        git: AgentGit(),
        root: root,
        apiKey: '',
        onEvent: events.add,
        approve: (_, _) async => true,
        clientFactory: () => queueClient(actions),
        hooks: NoHooks(),
        commands: FakeCommands(),
      );
      final result = await engine.run(
        'Fix c',
        const AgentRunOptions(
          yolo: false,
          maxConsecutiveMistakes: 1,
          maxReadsBeforeFirstEdit: 2,
        ),
      );
      expect(result.success, isTrue);
      expect(await store.readText('lib/c.dart'), contains('const c_0 = 1;'));
      expect(
        events.map((e) => e.text),
        contains(
          contains(
            'Normalized: skipped blocked read_file, ran replace_in_file',
          ),
        ),
      );
      expect(
        events.where((e) => e.type == 'denied'),
        isEmpty,
        reason:
            'blocked read must be skipped, not soft-denied as a wasted turn',
      );
      expect(actions, isEmpty);
    },
  );

  test(
    'repeated blocked reads after final targeted read stop the loop',
    () async {
      final store = RepositoryMemory();
      for (final name in ['a', 'b', 'c']) {
        await store.writeText('lib/$name.dart', 'const ${name}_0 = 0;');
      }
      final events = <AgentEvent>[];
      final actions = [
        '{"action":"search_files","query":"a_0","path":"lib"}',
        '{"action":"read_file","path":"lib/a.dart"}',
        '{"action":"search_files","query":"b_0","path":"lib"}',
        '{"action":"read_file","path":"lib/b.dart"}',
        '{"action":"read_file","path":"lib/c.dart"}', // final targeted read
        '{"action":"read_file","path":"lib/c.dart"}', // blocked #1
        '{"action":"read_file","path":"lib/c.dart"}', // blocked #2 → stop
        '{"action":"read_file","path":"lib/c.dart"}',
        '{"action":"finish","summary":"should not reach"}',
      ];
      final engine = AgentTaskEngine(
        profile: agentProfile(),
        store: store,
        git: AgentGit(),
        root: root,
        apiKey: '',
        onEvent: events.add,
        approve: (_, _) async => true,
        clientFactory: () => queueClient(actions),
        hooks: NoHooks(),
        commands: FakeCommands(),
      );
      await expectLater(
        engine.run(
          'Fix c',
          const AgentRunOptions(
            yolo: false,
            maxConsecutiveMistakes: 5,
            maxReadsBeforeFirstEdit: 2,
            maxIterations: 40,
          ),
        ),
        throwsA(
          isA<ModelApiException>().having(
            (e) => e.message,
            'message',
            contains('kept calling read_file'),
          ),
        ),
      );
      expect(
        events.where((e) => e.type == 'denied').length,
        greaterThanOrEqualTo(2),
      );
      expect(
        actions,
        contains(contains('should not reach')),
        reason: 'The finish action must remain unconsumed after the loop stops',
      );
    },
  );

  test('build-error line in the task is seeded into active context', () async {
    final store = RepositoryMemory();
    await store.writeText(
      'Pages/Index.cshtml',
      '${List.generate(110, (i) => '<!-- line ${i + 1} -->').join('\n')}\n</body>\n</html>\n',
    );
    final events = <AgentEvent>[];
    final bodies = <Map<String, dynamic>>[];
    final actions = [
      '{"action":"replace_in_file","path":"Pages/Index.cshtml",'
          '"oldText":"<!-- line 103 -->","newText":"<!-- fixed -->"}',
      '{"action":"finish","summary":"fixed malformed body"}',
    ];
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => true,
      clientFactory: () => ModelClient(
        client: MockClient((request) async {
          bodies.add(
            Map<String, dynamic>.from(
              jsonDecode(request.body) as Map<String, dynamic>,
            ),
          );
          final next = actions.removeAt(0);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': next},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        }),
      ),
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    final result = await engine.run(
      'dotnet run failed:\n'
      '/Users/latin/Documents/Source/Krotogon/Pages/Index.cshtml(103,3): '
      'error RZ1034: Found a malformed body tag helper.\n'
      'Ошибка сборки.',
      const AgentRunOptions(yolo: false, maxConsecutiveMistakes: 1),
    );
    expect(result.success, isTrue);
    expect(
      events.map((e) => e.text),
      contains(contains('Seeded build-error context')),
    );
    final firstPrompt = jsonEncode(bodies.first);
    expect(firstPrompt, contains('line 103'));
    expect(firstPrompt, contains('Build error context'));
  });

  test('aborted runs still persist what they learned', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/platform_services.dart', 'String readLocal();');
    final actions = [
      '{"action":"read_file","path":"lib/platform_services.dart"}',
      '{"action":"read_file","path":"lib/does_not_exist.dart"}',
    ];
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: (_) {},
      approve: (_, _) async => true,
      clientFactory: () => queueClient(actions),
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    await expectLater(
      engine.run(
        'Investigate readLocal',
        const AgentRunOptions(maxConsecutiveMistakes: 1),
      ),
      throwsA(isA<ModelApiException>()),
    );
    final memory = await ProjectMemoryStore(store).load();
    expect(
      memory.areas.expand((area) => area.files),
      contains('lib/platform_services.dart'),
    );
    expect(memory.areas.last.status, 'unresolved');
  });

  test('memory stays pinned in the prompt and is offered up front', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/platform_services.dart', 'String readLocal();');
    final memory = ProjectMemory();
    memory.mergeTask(
      task: 'Opening a PNG fails with a UTF-8 decode error',
      summary: 'readLocal decodes bytes as UTF-8 text',
      readPaths: const ['lib/platform_services.dart'],
      editedPaths: const [],
      fileFingerprints: const {},
      learnedFacts: const ['readAsString → lib/platform_services.dart:12'],
    );
    await ProjectMemoryStore(store).save(memory);
    final bodies = <String>[];
    final actions = [
      '{"action":"read_file","path":"lib/platform_services.dart"}',
      '{"action":"finish","summary":"done"}',
    ];
    ModelClient client() => ModelClient(
      client: MockClient((request) async {
        bodies.add(request.body);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': actions.removeAt(0)},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );
    final events = <AgentEvent>[];
    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => true,
      clientFactory: client,
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    await engine.run(
      'Opening a JPG fails with a UTF-8 decode error',
      const AgentRunOptions(),
    );
    for (final body in bodies) {
      expect(body, contains('Retained project memory (persistent)'));
      expect(body, contains('lib/platform_services.dart'));
    }
    expect(bodies.first, contains('Retained memory already points to'));
    expect(
      events.where((e) => e.type == 'memory').map((e) => e.text),
      anyElement(contains('Reused known location')),
    );
  });
}
