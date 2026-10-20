import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/git/git_store.dart';
import 'package:tamtoot/core/git/http_git_service.dart';
import 'package:tamtoot/features/explorer_context_menu.dart';
import 'package:tamtoot/platform/git_service_io.dart';
import 'package:tamtoot/platform/git_shared.dart';
import 'explorer_test.dart' show RepositoryMemory;
import 'git_commit_push_test.dart' show PushTransport;
import 'support.dart';

class FolderStore extends RepositoryMemory {
  bool deleted = false;
  @override
  Future<void> deleteDirectory(String path) async {
    path = directoryDeletionPath(path);
    deleted = true;
    data.removeWhere((name, _) => name.startsWith('$path/'));
  }
}

void main() {
  test(
    'native recursive deletion removes nested files and empty folders, protects roots and metadata',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'tamtoot-folder-delete-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = FileGitRepositoryStore(root);
      await store.createDirectory('folder/nested/empty');
      await store.writeText('folder/nested/a.txt', 'data');
      await store.writeText('folder-copy/keep.txt', 'keep');
      for (final path in [
        '',
        '/',
        '.',
        '..',
        '../outside',
        '.git',
        '.GIT',
        '.tamtoot',
        '.TAMTOOT',
        'folder/../other',
        '/absolute',
      ]) {
        await expectLater(store.deleteDirectory(path), throwsFormatException);
      }
      await store.deleteDirectory('folder/');
      expect(
        await Directory.fromUri(root.uri.resolve('folder/')).exists(),
        false,
      );
      expect(await store.readText('folder-copy/keep.txt'), 'keep');
    },
  );
  test(
    'directory deletion rejects linked ancestors and never follows nested links',
    () async {
      if (Platform.isWindows) return; // Symlink creation may require elevation.
      final root = await Directory.systemTemp.createTemp(
        'tamtoot-folder-link-',
      );
      final outside = await Directory.systemTemp.createTemp(
        'tamtoot-folder-outside-',
      );
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => outside.delete(recursive: true));
      final file = File.fromUri(outside.uri.resolve('keep.txt'));
      await file.writeAsString('keep');
      await Link.fromUri(root.uri.resolve('linked')).create(outside.path);
      final store = FileGitRepositoryStore(root);
      await expectLater(store.deleteDirectory('linked'), throwsA(anything));
      await store.createDirectory('folder');
      await Link.fromUri(root.uri.resolve('folder/link')).create(outside.path);
      await store.deleteDirectory('folder');
      expect(await file.readAsString(), 'keep');
    },
  );
  for (final confirm in [false, true]) {
    testWidgets(
      'folder deletion confirmation=$confirm preserves neighboring tabs',
      (tester) async {
        final store = FolderStore();
        await store.writeText('folder/a.txt', 'saved');
        await store.writeText('folder/sub/b.txt', 'saved');
        await store.writeText('folder-copy/c.txt', 'keep');
        final git = HttpGitService(
          transport: PushTransport(),
          openStore: (_) => store,
          inflateAt: archiveInflateAt,
          deflate: archiveDeflate,
        );
        final session = await testSession(git: git);
        session.workspaceRoot = Uri.parse('memory:///project/');
        final a = session.documents.create(
          'a.txt',
          'saved',
          uri: session.workspaceRoot!.resolve('folder/a.txt'),
          savedText: 'saved',
        );
        final b = session.documents.create(
          'b.txt',
          'saved',
          uri: session.workspaceRoot!.resolve('folder/sub/b.txt'),
          savedText: 'saved',
        );
        final c = session.documents.create(
          'c.txt',
          'keep',
          uri: session.workspaceRoot!.resolve('folder-copy/c.txt'),
          savedText: 'keep',
        );
        a.editor.replaceSelection('unsaved');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showExplorerContextMenu(
                    context,
                    session,
                    session.workspaceRoot!.resolve('folder/'),
                    true,
                    const Offset(20, 20),
                  ),
                  child: const Text('Menu'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Menu'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete folder…'));
        await tester.pumpAndSettle();
        expect(find.text('Delete folder and its contents?'), findsOneWidget);
        expect(find.textContaining('Unsaved changes'), findsOneWidget);
        expect(store.deleted, false);
        await tester.tap(find.text(confirm ? 'Delete' : 'Cancel'));
        await tester.pumpAndSettle();
        expect(store.deleted, confirm);
        expect(session.documents.documents.contains(a), !confirm);
        expect(session.documents.documents.contains(b), !confirm);
        expect(session.documents.documents.contains(c), true);
        expect(await store.exists('folder-copy/c.txt'), true);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(session.dispose);
      },
    );
  }
}
