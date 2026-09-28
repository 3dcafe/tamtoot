import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/agents/model_profile.dart';
import 'package:tamtoot/core/agents/profile_store.dart';
import 'package:tamtoot/core/git/http_git_service.dart';
import 'package:tamtoot/features/model_profiles_dialog.dart';
import 'package:tamtoot/platform/git_service_io.dart';
import 'package:tamtoot/platform/git_shared.dart';
import 'explorer_test.dart' show RepositoryMemory;
import 'git_commit_push_test.dart' show PushTransport;
import 'support.dart';

class ProfileMemory extends RepositoryMemory {
  @override
  Future<bool> exists(String path) async =>
      data.containsKey(path) || data.keys.any((p) => p.startsWith('$path/'));
}

void main() {
  ModelProfile profile({
    String id = 'local-code',
    Map<String, dynamic> parameters = const {},
  }) => ModelProfile(
    id: id,
    name: 'Local code',
    provider: 'custom',
    model: 'my-model',
    parameters: parameters,
  );
  test(
    'profiles round-trip and expand context once without interpreting code as templates',
    () {
      final p = ModelProfile.parse(
        profile(parameters: {'temperature': 0.2}).encode(),
      );
      final preview = p.preview(
        task: 'Fix',
        instructions: 'Use Dart.',
        file: '{{task}}',
        selection: 'x',
      );
      expect(preview['userPrompt'], contains('Task:\nFix'));
      expect(preview['userPrompt'], contains('{{task}}'));
      expect(preview['systemPrompt'], endsWith('Use Dart.'));
      expect(preview['parameters'], {'temperature': 0.2});
      expect(
        () => ModelProfile.parse('{"schemaVersion":2}'),
        throwsFormatException,
      );
      expect(() => profile(id: '../escape').encode(), throwsFormatException);
      expect(
        () => profile(parameters: {'api_key': 'secret'}).encode(),
        throwsFormatException,
      );
      expect(
        () => profile(
          parameters: {
            'options': {'Authorization': 'secret'},
          },
        ).encode(),
        throwsFormatException,
      );
      expect(
        () => ModelProfile(
          id: 'x',
          name: 'X',
          provider: 'p',
          model: 'm',
          userTemplate: '{{unknown}}',
        ).encode(),
        throwsFormatException,
      );
    },
  );
  test(
    'native storage persists profiles and instructions, rejects stale writes and isolates projects',
    () async {
      final dir = await Directory.systemTemp.createTemp('tamtoot-profiles-');
      addTearDown(() => dir.delete(recursive: true));
      final a = ProfileStore(
        FileGitRepositoryStore(Directory('${dir.path}/a')),
      );
      final b = ProfileStore(
        FileGitRepositoryStore(Directory('${dir.path}/b')),
      );
      expect(await a.list(), isEmpty);
      final text = profile().encode(), path = a.path('local-code');
      await a.save(path, text, null);
      expect(await a.list(), [path]);
      expect(await b.list(), isEmpty);
      expect(await a.read(path), text);
      await expectLater(a.save(path, 'changed', null), throwsStateError);
      await a.save(ProfileStore.instructionsPath, 'Use tests.', null);
      expect(await a.read(ProfileStore.instructionsPath), 'Use tests.');
      await a.delete('local-code', text);
      expect(await a.list(), isEmpty);
    },
  );
  test('native storage refuses symlinked metadata folders', () async {
    final dir = await Directory.systemTemp.createTemp('tamtoot-profile-links-');
    addTearDown(() => dir.delete(recursive: true));
    final outside = await Directory('${dir.path}/outside').create();
    final root = await Directory('${dir.path}/project').create();
    await Link('${root.path}/.tamtoot').create(outside.path);
    final store = ProfileStore(FileGitRepositoryStore(root));
    await expectLater(
      store.save(store.path('x'), profile(id: 'x').encode(), null),
      throwsA(isA<Exception>()),
    );
    expect(await outside.list().toList(), isEmpty);
  }, skip: Platform.isWindows);

  testWidgets(
    'create, preview and reopen a saved model profile in narrow dialog',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final files = ProfileMemory();
      final session = await testSession(
        git: HttpGitService(
          transport: PushTransport(),
          openStore: (_) => files,
          inflateAt: archiveInflateAt,
          deflate: archiveDeflate,
        ),
      );
      session.workspaceRoot = Uri.parse('memory:///project/');
      Future<void> open() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: ctx,
                    builder: (_) => ModelProfilesDialog(session: session),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
      }

      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      await open();
      for (final entry in {
        'Profile ID': 'coding',
        'Display name': 'Coding',
        'Provider ID': 'custom',
        'Model ID': 'local-model',
      }.entries) {
        await tester.ensureVisible(field(entry.key));
        await tester.enterText(field(entry.key), entry.value);
      }
      await tester.ensureVisible(find.text('Save profile *'));
      await tester.tap(find.text('Save profile *'));
      await tester.pumpAndSettle();
      expect(
        files.data.containsKey('.tamtoot/agents/models/coding.json'),
        isTrue,
      );
      await tester.ensureVisible(find.text('Preview prompts'));
      await tester.tap(find.text('Preview prompts'));
      await tester.pumpAndSettle();
      expect(find.text('Prompt preview · not sent'), findsOneWidget);
      await tester.tap(find.text('Close').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('model-profile-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('coding.json').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('Model ID')).controller!.text,
        'local-model',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.dispose);
    },
  );
}
