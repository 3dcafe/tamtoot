import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tamtoot/core/agents/agent_engine.dart';
import 'package:tamtoot/core/agents/model_client.dart';
import 'package:tamtoot/core/agents/command_runner.dart';
import 'package:tamtoot/core/agents/test_command.dart';
import 'agent_engine_test.dart' show agentProfile, AgentGit, NoHooks;
import 'explorer_test.dart' show RepositoryMemory;

class TestRunner extends AgentCommandRunner {
  TestRunner({this.exit = 0, this.enabled = true})
    : super(Uri.parse('file:///test/'));
  final int exit;
  final bool enabled;
  int calls = 0;
  @override
  bool get available => enabled;
  @override
  Future<AgentCommandResult> runTests(
    String executable,
    List<String> args,
  ) async {
    calls++;
    return AgentCommandResult(
      exit,
      exit == 0 ? '2 tests passed' : 'SDK unavailable or test failure',
    );
  }
}

void main() {
  test(
    'test commands reject shells, arbitrary programs and script injection',
    () {
      for (final entry in {
        'sh': ['-c', 'rm -rf .'],
        'python3': ['-c', 'print(1)'],
        'npm': ['install'],
        'dotnet': ['run'],
        '../flutter': ['test'],
        'flutter': ['test', '../outside_test.dart'],
        'pnpm': ['test', '--dir=/tmp/outside'],
      }.entries) {
        expect(
          () => validateAgentTestCommand(entry.key, entry.value),
          throwsFormatException,
        );
      }
      for (final entry in {
        'flutter': ['test', 'test/example_test.dart'],
        'dotnet': ['test'],
        'python3': ['-m', 'unittest', 'discover'],
        'npm': ['test'],
        'cargo': ['test'],
      }.entries) {
        expect(
          () => validateAgentTestCommand(entry.key, entry.value),
          returnsNormally,
        );
      }
    },
  );
  for (final consent in [false, true]) {
    for (final exit in [0, 127, 1]) {
      test(
        'desktop tests consent=$consent exit=$exit need explicit approval even with YOLO',
        () async {
          final store = RepositoryMemory(), runner = TestRunner(exit: exit);
          final bodies = <String>[];
          var approvals = 0;
          final actions = [
            {
              'action': 'write_file',
              'path': 'test/example_test.dart',
              'content': 'test content',
            },
            {
              'action': 'run_tests',
              'executable': 'flutter',
              'args': ['test', 'test/example_test.dart'],
            },
            {'action': 'finish', 'summary': 'Changes written'},
          ];
          final engine = AgentTaskEngine(
            profile: agentProfile(),
            store: store,
            git: AgentGit(),
            root: Uri.parse('file:///test/'),
            apiKey: '',
            hooks: NoHooks(),
            commands: runner,
            onEvent: (_) {},
            approve: (name, _) async {
              expect(name, 'run_tests');
              approvals++;
              return consent;
            },
            clientFactory: () => ModelClient(
              client: MockClient((request) async {
                bodies.add(request.body);
                return http.Response(
                  jsonEncode({
                    'choices': [
                      {
                        'message': {'content': jsonEncode(actions.removeAt(0))},
                        'finish_reason': 'stop',
                      },
                    ],
                  }),
                  200,
                );
              }),
            ),
          );
          final result = await engine.run(
            'Change code and test it',
            const AgentRunOptions(writeAndRunTests: true),
          );
          expect(approvals, 1);
          expect(runner.calls, consent ? 1 : 0);
          expect(result.success, !consent || exit == 0 || exit == 127);
          expect(
            result.message,
            contains(
              !consent
                  ? 'denied'
                  : exit == 127
                  ? 'unavailable'
                  : 'code $exit',
            ),
          );
          expect(
            bodies.first,
            contains('The user enabled Write and run tests'),
          );
        },
      );
    }
  }
  test(
    'unavailable platform never exposes or executes the test runner',
    () async {
      final runner = TestRunner(enabled: false);
      var calls = 0;
      final engine = AgentTaskEngine(
        profile: agentProfile(),
        store: RepositoryMemory(),
        git: AgentGit(),
        root: Uri.parse('memory:///project/'),
        apiKey: '',
        hooks: NoHooks(),
        commands: runner,
        onEvent: (_) {},
        approve: (_, _) async => fail('must not ask to run a disabled tool'),
        clientFactory: () => ModelClient(
          client: MockClient((request) async {
            expect(
              request.body,
              isNot(contains('The user enabled Write and run tests')),
            );
            calls++;
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content': calls == 1
                          ? '{"action":"run_tests","executable":"flutter","args":["test"]}'
                          : '{"action":"finish","summary":"No tests ran"}',
                    },
                  },
                ],
              }),
              200,
            );
          }),
        ),
      );
      await engine.run('Test', const AgentRunOptions(writeAndRunTests: true));
      expect(runner.calls, 0);
    },
  );
}
