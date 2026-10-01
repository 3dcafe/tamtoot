import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tamtoot/core/agents/agent_engine.dart';
import 'package:tamtoot/core/agents/model_client.dart';
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
    final result = await engine.run('Update it', const AgentRunOptions());
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
}
