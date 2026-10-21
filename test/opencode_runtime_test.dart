// Focused regressions; no real model required. Live smoke: tool/agent_readme_diagnostic.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/opencode/config.dart';
import 'package:tamtoot/core/opencode/llm.dart';
import 'package:tamtoot/core/opencode/message.dart';
import 'package:tamtoot/core/opencode/runner.dart';
import 'package:tamtoot/core/opencode/session.dart';

class ScriptClient extends LlmClient {
  ScriptClient(this.respond);
  final List<LlmEvent> Function(LlmRequest) respond;
  final requests = <LlmRequest>[];
  @override
  Stream<LlmEvent> stream(LlmRequest request) async* {
    requests.add(request);
    yield* Stream.fromIterable(respond(request));
  }
}

void main() {
  late Directory root;
  late SessionStore store;
  late AgentSession session;
  late OpencodeConfig config;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-runtime-');
    store = SessionStore(root.path);
    session = await store.create();
    config = OpencodeConfig(
      selectedModel: 'ollama/test',
      providers: {
        'ollama': ProviderConfig(
          id: 'ollama',
          type: 'ollama',
          baseURL: 'http://localhost',
        ),
      },
    );
  });
  tearDown(() => root.delete(recursive: true));

  Future<void> run(
    SessionRunner runner,
    String task, {
    AgentMode mode = AgentMode.agent,
  }) async {
    await runner.prompt(session, task, mode: mode);
    await Future<void>(() async {
      while (runner.isBusy(session.id)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }).timeout(const Duration(seconds: 5));
  }

  test(
    'refusal retries once, reads selected README, returns tool result',
    () async {
      await File(
        '${root.path}/README.md',
      ).writeAsString('# Test CRM\nActual project facts');
      late ScriptClient client;
      client = ScriptClient((request) {
        expect(request.tools.map((t) => t.name), contains('read'));
        if (client.requests.length == 1) {
          return [
            LlmTextDelta("I can't directly access the project"),
            LlmFinish('stop'),
          ];
        }
        if (client.requests.length == 2) {
          return [
            LlmToolCallEvent(
              LlmToolCall(
                id: 'read-1',
                name: 'read',
                arguments: {'path': 'README.md'},
              ),
            ),
            LlmFinish('tool-calls'),
          ];
        }
        final result = request.messages.last;
        expect(result.role, 'tool');
        expect(result.toolName, 'read');
        expect(result.toolCallId, 'read-1');
        expect(result.text, contains('Actual project facts'));
        return [
          LlmTextDelta('Это Test CRM: Actual project facts.'),
          LlmFinish('stop'),
        ];
      });
      await run(
        SessionRunner(
          root: root.path,
          config: config,
          store: store,
          client: client,
        ),
        'О чем этот проект?',
      );
      expect(client.requests, hasLength(3));
      expect(session.messages.where((m) => m.diagnostic), hasLength(1));
    },
  );

  test('repeated refusal stops without claiming successful access', () async {
    final client = ScriptClient(
      (_) => [LlmTextDelta('I cannot access the project'), LlmFinish('stop')],
    );
    await run(
      SessionRunner(
        root: root.path,
        config: config,
        store: store,
        client: client,
      ),
      'О чем этот проект?',
    );
    expect(client.requests, hasLength(2));
    expect(session.messages.last.diagnostic, isTrue);
    expect(
      session.messages.expand((m) => m.parts).whereType<ToolPart>(),
      isEmpty,
    );
  });

  test('Chat mode does not advertise or execute repository tools', () async {
    final client = ScriptClient((request) {
      expect(request.tools, isEmpty);
      expect(request.toolChoice, 'none');
      return [LlmTextDelta('Привет!'), LlmFinish('stop')];
    });
    await run(
      SessionRunner(
        root: root.path,
        config: config,
        store: store,
        client: client,
      ),
      'Привет',
      mode: AgentMode.chat,
    );
    expect(client.requests, hasLength(1));
  });

  test('read edit verify uses real code and preserves handlers', () async {
    final file = File('${root.path}/card.dart');
    await file.writeAsString(
      'Widget card() => Card(color: Colors.red, child: InkWell(onTap: openCard));',
    );
    late ScriptClient client;
    client = ScriptClient((_) {
      final index = client.requests.length;
      final call = switch (index) {
        1 || 3 => LlmToolCall(
          id: 'read-$index',
          name: 'read',
          arguments: {'path': 'card.dart'},
        ),
        2 => LlmToolCall(
          id: 'edit',
          name: 'edit',
          arguments: {
            'path': 'card.dart',
            'oldString': 'Colors.red',
            'newString': 'Colors.blue',
          },
        ),
        _ => null,
      };
      return call == null
          ? [LlmTextDelta('Готово, проверено.'), LlmFinish('stop')]
          : [LlmToolCallEvent(call), LlmFinish('tool-calls')];
    });
    await run(
      SessionRunner(
        root: root.path,
        config: config,
        store: store,
        client: client,
      ),
      'Измени цвет card.dart на синий',
    );
    expect(await file.readAsString(), contains('Colors.blue'));
    expect(await file.readAsString(), contains('onTap: openCard'));
    expect(
      session.messages
          .expand((m) => m.parts)
          .whereType<ToolPart>()
          .every((p) => p.state.status == 'completed'),
      isTrue,
    );
  });

  test('deleted session cannot be resurrected by late persistence', () async {
    final pending = store.persist(session);
    await store.delete(session.id);
    await pending;
    await store.persist(session);
    expect(await SessionStore(root.path).list(), isEmpty);
  });
}
