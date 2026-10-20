import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tamtoot/core/agents/agent_engine.dart';
import 'package:tamtoot/core/agents/agent_history.dart';
import 'package:tamtoot/core/agents/model_client.dart';
import 'package:tamtoot/core/agents/project_memory.dart';
import 'package:tamtoot/core/git/http_git_service.dart';
import 'package:tamtoot/features/agent_dialog.dart';
import 'package:tamtoot/platform/git_shared.dart';
import 'agent_local_models_test.dart' show engine, answer;
import 'explorer_test.dart' show RepositoryMemory;
import 'git_commit_push_test.dart' show PushTransport;
import 'support.dart';

Future<void> seed(RepositoryMemory store) async {
  await AgentHistoryStore(
    store,
  ).save([AgentEvent('user', 'obsolete-chat-marker')]);
  final memory = ProjectMemory()
    ..mergeTask(
      task: 'obsolete-task-marker',
      summary: 'obsolete-memory-marker',
      readPaths: ['main.dart'],
      editedPaths: [],
      fileFingerprints: const {},
      learnedFacts: ['obsolete-fact-marker'],
    );
  await ProjectMemoryStore(store).save(memory);
  await store.writeText(
    '.tamtoot/agents/instructions.md',
    'Keep project instructions',
  );
  await store.writeText(
    '.tamtoot/agents/models/local.json',
    '{"id":"local","name":"Local","provider":"ollama","model":"local-model","apiFormat":"ollama","endpoint":"http://localhost:11434/api/chat"}',
  );
  await store.writeText('main.dart', 'void main() {}');
}

class SlowMemoryStore extends RepositoryMemory {
  bool delay = false;
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    if (delay && path == ProjectMemory.storePath) {
      started.complete();
      await release.future;
    }
    await super.writeBytes(path, bytes);
  }
}

void main() {
  test(
    'full clear deletes chat and retained memory; next request has no previous task',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      await AgentHistoryStore(store).clearConversation();
      expect(await AgentHistoryStore(store).load(), isEmpty);
      expect((await ProjectMemoryStore(store).load()).areas, isEmpty);
      expect(await store.exists('.tamtoot/agents/instructions.md'), true);
      expect(await store.exists('.tamtoot/agents/models/local.json'), true);
      final run = engine(store, (request) async {
        expect(request.body, isNot(contains('obsolete-')));
        return answer('{"action":"finish","summary":"Fresh request"}');
      });
      await run.run('Explain this project', const AgentRunOptions());
      expect(
        await store.readText(ProjectMemory.storePath),
        isNot(contains('obsolete-')),
      );
    },
  );

  test('discard waits for in-flight memory writes before clearing', () async {
    final store = SlowMemoryStore();
    await seed(store);
    store.delay = true;
    final run = engine(
      store,
      (_) async => answer('{"action":"finish","summary":"Old task result"}'),
    );
    final running = run.run('Explain main.dart', const AgentRunOptions());
    await store.started.future;
    var discarded = false;
    final discarding = run.discardConversation().then((_) => discarded = true);
    await Future<void>.delayed(Duration.zero);
    expect(discarded, false);
    store.release.complete();
    await discarding;
    await AgentHistoryStore(store).clearConversation();
    await running;
    expect(await store.exists(ProjectMemory.storePath), false);
  });

  test(
    'cancelled request cannot flush old task memory back after reset',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      final waiting = Completer<void>();
      final reply = Completer<void>();
      var requests = 0;
      final run = engine(store, (_) async {
        if (requests++ == 0) {
          return answer('{"action":"read_file","path":"main.dart"}');
        }
        waiting.complete();
        await reply.future;
        return answer('{"action":"finish","summary":"Obsolete task result"}');
      });
      final running = run.run('Explain main.dart', const AgentRunOptions());
      final failure = expectLater(running, throwsA(isA<ModelApiException>()));
      await waiting.future;
      await run.discardConversation();
      await AgentHistoryStore(store).clearConversation();
      reply.complete();
      await failure;
      expect(await store.exists(ProjectMemory.storePath), false);
      expect(await AgentHistoryStore(store).load(), isEmpty);
    },
  );

  testWidgets(
    'clear button deletes persisted memory and chat across panel reopen',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(700, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = RepositoryMemory();
      await seed(store);
      final git = HttpGitService(
        transport: PushTransport(),
        openStore: (_) => store,
        inflateAt: archiveInflateAt,
        deflate: archiveDeflate,
      );
      final session = await testSession(git: git);
      session.workspaceRoot = Uri.parse('memory:///project/');
      Widget panel() => MaterialApp(
        home: Scaffold(body: AgentPanel(session: session)),
      );
      await tester.pumpWidget(panel());
      await tester.pumpAndSettle();
      expect(find.text('obsolete-chat-marker'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-clear-log')));
      await tester.pumpAndSettle();
      expect(await store.exists(ProjectMemory.storePath), false);
      expect(find.text('obsolete-chat-marker'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(panel());
      await tester.pumpAndSettle();
      expect(find.text('obsolete-chat-marker'), findsNothing);
      expect(await AgentHistoryStore(store).load(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.dispose);
    },
  );
}
