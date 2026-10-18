import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tamtoot/core/agents/model_api_probe.dart';
import 'package:tamtoot/core/agents/model_profile.dart';
import 'package:tamtoot/core/agents/profile_store.dart';
import 'package:tamtoot/core/git/http_git_service.dart';
import 'package:tamtoot/features/model_profiles_dialog.dart';
import 'package:tamtoot/features/dialogs.dart';
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

class ProbeClient extends http.BaseClient {
  ProbeClient(this.handler);
  final http.StreamedResponse Function(http.BaseRequest request) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      handler(request);
}

void main() {
  testWidgets(
    'settings manages profiles while the editor only edits one profile',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
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
      final profile = ModelProfile(
        id: 'existing',
        name: 'Existing profile',
        provider: 'custom',
        model: 'local-model',
      );
      final store = ProfileStore(files);
      await store.save(store.path(profile.id), profile.encode(), null);
      session.rememberModelApiKey(profile.id, 'local-key');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsDialog(session: session, initialSection: 'agents'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Existing profile'), findsOneWidget);
      expect(find.byTooltip('Delete profile'), findsOneWidget);
      await tester.tap(find.byTooltip('Edit profile'));
      await tester.pumpAndSettle();
      expect(find.text('Edit model profile'), findsOneWidget);
      expect(find.byKey(const ValueKey('model-profile-picker')), findsNothing);
      expect(
        find.descendant(
          of: find.byType(ModelProfilesDialog),
          matching: find.text('New profile'),
        ),
        findsNothing,
      );
      expect(find.text('Delete profile'), findsNothing);
      final nameField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Display name',
      );
      expect(
        tester.widget<TextField>(nameField).controller!.text,
        'Existing profile',
      );
      await tester.enterText(nameField, 'Renamed profile');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('save-profile')));
      await tester.tap(find.byKey(const ValueKey('save-profile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close profile'));
      await tester.pumpAndSettle();
      expect(find.text('Renamed profile'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await store.read(store.path(profile.id)), isNotNull);
      await tester.tap(find.byTooltip('Delete profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(await store.read(store.path(profile.id)), isNull);
      expect(session.modelApiKey(profile.id), isEmpty);
      expect(find.textContaining('No model profiles yet'), findsOneWidget);
      await tester.tap(find.text('Add OpenAI GPT'));
      await tester.pumpAndSettle();
      expect(find.text('Create model profile'), findsOneWidget);
      expect(
        tester.widget<TextField>(nameField).controller!.text,
        'OpenAI GPT',
      );
      expect(find.byKey(const ValueKey('server-openai')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.dispose);
    },
  );
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
  test('API probe validates Ollama and compatible model discovery', () async {
    final ollama = ModelApiProbe(
      client: ProbeClient(
        (request) => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              '{"models":[{"name":"qwen2.5-coder"},{"name":"llama3"}]}',
            ),
          ),
          200,
        ),
      ),
    );
    final ollamaResult = await ollama.check(
      ModelProfile(
        id: 'ollama',
        name: 'Ollama',
        provider: 'ollama',
        model: 'qwen2.5-coder',
        apiFormat: 'ollama',
        endpoint: 'http://localhost:11434/api/chat',
      ),
    );
    expect(ollamaResult.models, ['llama3', 'qwen2.5-coder']);
    expect(ollamaResult.message, contains('is installed'));
    ollama.close();

    late Uri checked;
    final compatible = ModelApiProbe(
      client: ProbeClient((request) {
        checked = request.url;
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"data":[{"id":"local-code"}]}')),
          200,
        );
      }),
    );
    final compatibleResult = await compatible.check(
      ModelProfile(
        id: 'studio',
        name: 'LM Studio',
        provider: 'lm-studio',
        model: 'local-code',
        endpoint: 'http://localhost:1234/v1/chat/completions',
      ),
    );
    expect(checked.path, '/v1/models');
    expect(compatibleResult.models, ['local-code']);
    expect(compatibleResult.message, contains('compatible'));
    compatible.close();

    late Uri customChecked;
    final custom = ModelApiProbe(
      client: ProbeClient((request) {
        customChecked = request.url;
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              '{"models":[{"name":"/models/code.gguf"}],"object":"list"}',
            ),
          ),
          200,
        );
      }),
    );
    final customResult = await custom.check(
      ModelProfile(
        id: 'custom',
        name: 'Custom',
        provider: 'custom',
        model: '/models/code.gguf',
        endpoint: 'https://models.example/v1/models',
      ),
    );
    expect(customChecked.path, '/v1/models');
    expect(customResult.models, ['/models/code.gguf']);
    expect(customResult.message, contains('available'));
    custom.close();
  });
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
      await tester.binding.setSurfaceSize(const Size(430, 900));
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
      String? selectedPath;
      Future<void> open() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: ctx,
                    builder: (_) => ModelProfilesDialog(
                      session: session,
                      initialPath: selectedPath,
                    ),
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
      final saveButton = find.byKey(const ValueKey('save-profile'));
      final saveRect = tester.getRect(saveButton);
      for (final key in [
        'check-model-api',
        'find-models',
        'reset-prompts',
        'preview-prompts',
        'run-model',
        'save-profile',
        'save-instructions',
        'close-profile',
      ]) {
        expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
      }
      await tester.drag(
        find.byType(SingleChildScrollView).last,
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(saveButton), saveRect);
      for (final entry in {
        'Display name': 'Coding',
        'Model name': 'local-model',
      }.entries) {
        await tester.ensureVisible(field(entry.key));
        await tester.enterText(field(entry.key), entry.value);
      }
      await tester.ensureVisible(find.byKey(const ValueKey('save-profile')));
      await tester.tap(find.byKey(const ValueKey('save-profile')));
      await tester.pumpAndSettle();
      expect(
        files.data.containsKey('.tamtoot/agents/models/coding.json'),
        isTrue,
      );
      await tester.ensureVisible(find.byTooltip('Preview prompts'));
      await tester.tap(find.byTooltip('Preview prompts'));
      await tester.pumpAndSettle();
      expect(find.text('Prompt preview · not sent'), findsOneWidget);
      await tester.tap(find.text('Close').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close profile'));
      await tester.pumpAndSettle();
      selectedPath = '.tamtoot/agents/models/coding.json';
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('model-profile-picker')), findsNothing);
      expect(find.text('New profile'), findsNothing);
      expect(find.text('Delete profile'), findsNothing);
      expect(
        tester.widget<TextField>(field('Model name')).controller!.text,
        'local-model',
      );
      await tester.ensureVisible(field('Shared project instructions'));
      await tester.enterText(
        field('Shared project instructions'),
        'Project guidance',
      );
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('Save instructions — unsaved changes'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('save-instructions')));
      await tester.pumpAndSettle();
      expect(
        await ProfileStore(files).read(ProfileStore.instructionsPath),
        'Project guidance',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.dispose);
    },
  );
}
