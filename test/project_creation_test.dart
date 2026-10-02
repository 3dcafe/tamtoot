import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tamtoot/core/git/git_service.dart';
import 'package:tamtoot/features/dialogs.dart';
import 'package:tamtoot/features/new_project_dialog.dart';
import 'package:tamtoot/platform/clone_paths.dart';
import 'package:tamtoot/platform/platform_services.dart';
import 'package:tamtoot/platform/project_storage.dart';

import 'support.dart';

class ProjectDialogs extends FakeDialogs {
  ProjectDialogs(this.parent);
  final Uri? parent;
  int picks = 0;
  @override
  bool get supportsDirectories => true;
  @override
  Future<Uri?> openWorkspace() async {
    picks++;
    return parent;
  }
}

class RecordingClone extends Fake implements GitService {
  Uri? destination;
  @override
  bool get available => true;
  @override
  Future<bool> isRepository(Uri directory) async => false;
  @override
  Future<GitResult> clone(
    Uri remote,
    Uri directory, {
    GitCredentials? credentials,
    String? branch,
    bool shallow = false,
  }) async {
    destination = directory;
    expect(await Directory.fromUri(directory).exists(), isTrue);
    await File.fromUri(directory.resolve('README.md')).writeAsString('cloned');
    return const GitResult(
      exitCode: 0,
      stdout: '',
      stderr: '',
      arguments: ['clone'],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(
    () async =>
        temp = await Directory.systemTemp.createTemp('tamtoot-project-'),
  );
  tearDown(() async => temp.delete(recursive: true));

  test(
    'new project is durable, discoverable and never overwrites an existing folder',
    () async {
      final root = await createProjectDirectory(temp.path, 'example');
      expect(await Directory.fromUri(root).exists(), isTrue);
      expect(await looksLikeManagedWorkspace(root.toFilePath()), isTrue);
      await File.fromUri(root.resolve('hello.txt')).writeAsString('keep');
      await expectLater(
        createProjectDirectory(temp.path, 'example'),
        throwsStateError,
      );
      expect(
        await File.fromUri(root.resolve('hello.txt')).readAsString(),
        'keep',
      );
      expect(await uniqueCloneFolderName(temp.path, 'example'), 'example-2');
      final file = File('${temp.path}/taken');
      await file.writeAsString('keep');
      expect(await cloneTargetBusy(file.path), isTrue);
      await expectLater(
        createProjectDirectory(temp.path, 'taken'),
        throwsStateError,
      );
    },
  );

  test('project names cannot escape the parent directory', () async {
    for (final name in [
      '../escape',
      'a/b',
      r'a\b',
      '..',
      '.',
      'CON',
      'NUL.txt',
    ]) {
      expect(projectNameError(name), isNotNull);
      await expectLater(
        createProjectDirectory(temp.path, name),
        throwsArgumentError,
      );
    }
    expect(projectNameError('My project'), isNull);
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      'creation and cloning use the correct destination on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        debugDefaultTargetPlatformOverride = platform;
        final mobile =
            platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS;
        final dialogs = ProjectDialogs(temp.uri);
        final git = RecordingClone();
        final session = await testSession(
          files: PlatformFiles(),
          dialogs: dialogs,
          git: git,
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => temp.path,
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => NewProjectDialog(session: session),
                    ),
                    child: const Text('New'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('New'));
          await tester.pumpAndSettle();
          expect(find.text('Browse'), mobile ? findsNothing : findsOneWidget);
          await tester.enterText(find.byType(TextField).first, 'created');
          final create = tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
              .onPressed!;
          await tester.runAsync(() async => await (create as dynamic)());
          await tester.pumpAndSettle();
          final parent = mobile ? '${temp.path}/TamtootRepos' : temp.path;
          expect(session.workspaceRoot, Uri.directory('$parent/created/'));
          expect(dialogs.picks, mobile ? 0 : 1);

          await tester.pumpWidget(
            MaterialApp(home: CloneRepositoryDialog(session: session)),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byType(TextField).first,
            'https://example.com/cloned.git',
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Clone'));
          final clone = tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Clone'))
              .onPressed!;
          await tester.runAsync(() async => await (clone as dynamic)());
          await tester.pumpAndSettle();
          expect(git.destination, Uri.directory('$parent/cloned'));
          expect(
            await tester.runAsync(
              () => File('$parent/cloned/README.md').readAsString(),
            ),
            'cloned',
          );
          expect(dialogs.picks, mobile ? 0 : 2);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(session.dispose);
          messenger.setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}
