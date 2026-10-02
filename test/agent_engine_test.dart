import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tamtoot/core/agents/agent_engine.dart';
import 'package:tamtoot/core/agents/model_client.dart';
import 'package:tamtoot/core/agents/model_attachment.dart';
import 'package:tamtoot/core/agents/model_profile.dart';
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
  test('agent sends attachments once and retains investigation context', () async {
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

  test('agent batches several files with read_files in one iteration', () async {
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
  });

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

  test('YOLO requires clean Git and then writes without approval', () async {
    final dirty = AgentTaskEngine(
      profile: agentProfile(),
      store: RepositoryMemory(),
      git: AgentGit(dirty: true),
      root: root,
      apiKey: '',
      onEvent: (_) {},
      approve: (_, _) async => false,
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    await expectLater(
      dirty.run('Task', const AgentRunOptions(yolo: true)),
      throwsA(
        isA<ModelApiException>().having(
          (e) => e.message,
          'message',
          contains('clean Git'),
        ),
      ),
    );

    final store = RepositoryMemory();
    final actions = [
      '{"action":"write_file","path":"new.txt","content":"created"}',
      '{"action":"finish","summary":"done"}',
    ];
    final clean = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: root,
      apiKey: '',
      onEvent: (_) {},
      approve: (_, _) async => throw StateError('must not ask'),
      clientFactory: () => queueClient(actions),
      hooks: NoHooks(),
      commands: FakeCommands(),
    );
    await clean.run('Create', const AgentRunOptions(yolo: true));
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

  test('agent caps max_tokens for JSON actions', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/a.dart', 'const x = 1;');
    final bodies = <Map<String, dynamic>>[];
    final actions = [
      '{"action":"finish","summary":"done"}',
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
      profile: ModelProfile(
        id: 'agent',
        name: 'Agent',
        provider: 'test',
        model: 'model',
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
    expect(bodies.single['max_tokens'], AgentTaskEngine.agentMaxTokens);
  });
}
