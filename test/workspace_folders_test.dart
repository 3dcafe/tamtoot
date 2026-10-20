import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/filesystem/filesystem.dart';
import 'support.dart';

class MultipleFolderDialogs extends FakeDialogs
    implements WorkspaceFolderDialogs {
  final roots = [
    Uri.parse('memory:///frontend/'),
    Uri.parse('memory:///backend/'),
  ];
  @override
  Future<List<Uri>> openWorkspaceFolders() async => roots;
  @override
  Future<Uri?> openWorkspace() => throw StateError('Single picker used');
}

void main() {
  test(
    'multi-folder picker is used when available; cancellation falls back safely',
    () async {
      final dialogs = MultipleFolderDialogs();
      expect(await dialogs.selectWorkspaceFolders(), dialogs.roots);
      expect(await FakeDialogs().selectWorkspaceFolders(), isEmpty);
    },
  );

  test(
    'selected folders share one workspace and cancellation preserves it',
    () async {
      final temp = await Directory.systemTemp.createTemp('tamtoot-folders-');
      addTearDown(() => temp.delete(recursive: true));
      final store = MemoryStore();
      final session = await testSession(store: store);
      addTearDown(session.dispose);
      final a = (await Directory('${temp.path}/frontend').create()).uri;
      final b = (await Directory('${temp.path}/backend').create()).uri;
      await session.openWorkspaceFolders([
        a,
        b,
        Uri.parse(b.toString().replaceFirst(RegExp(r'/$'), '')),
      ]);
      expect(session.workspaceRoot, a);
      expect(session.workspaceRoots, [a, b]);
      for (final root in [a, b]) {
        expect(
          await File.fromUri(root.resolve('.gitignore')).readAsString(),
          contains('**/.tamtoot/cache/'),
        );
      }
      expect(session.explorer.roots, [a, b]);
      expect(session.workspaceRootAliases[b], isNotEmpty);
      await session.persistNow();
      final restored = await testSession(store: store);
      addTearDown(restored.dispose);
      expect(restored.workspaceRoots, [a, b]);
      await session.openWorkspaceFolders([]);
      expect(session.workspaceRoots, [a, b]);
      await session.openWorkspaceFolders([b]);
      expect(session.workspaceRoots, [b]);
      expect(session.explorer.roots, [b]);
    },
  );
}
