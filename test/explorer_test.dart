import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/filesystem/filesystem.dart';
import 'package:tamtoot/core/git/git_objects.dart';
import 'package:tamtoot/core/git/git_publication.dart';
import 'package:tamtoot/core/git/git_service.dart';
import 'package:tamtoot/core/git/git_store.dart';
import 'package:tamtoot/platform/workspace_roots.dart';
import 'package:tamtoot/workspace/explorer/explorer_tree.dart';
import 'support.dart';

class RepositoryMemory extends GitRepositoryStore {
  final data = <String, Uint8List>{};
  @override
  Future<bool> exists(String path) async => data.containsKey(path);
  @override
  Future<Uint8List> readBytes(String path) async => data[path]!;
  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    data[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String path) async {
    data.remove(path);
  }

  @override
  Future<void> createDirectory(String path) async {}
  @override
  Future<List<String>> listFiles(String dir) async => data.keys
      .where(
        (p) => !p.startsWith('.git/') && (dir.isEmpty || p.startsWith('$dir/')),
      )
      .toList();
}

class IndicatorGit implements GitService, GitPublicationProvider {
  List<GitStatusEntry> entries = [
    const GitStatusEntry(' ', 'M', 'lib/a.dart'),
    const GitStatusEntry('?', '?', 'new.dart'),
  ];
  @override
  bool get available => true;
  @override
  Future<bool> isRepository(Uri directory) async => true;
  @override
  Future<List<GitStatusEntry>> statusEntries(Uri directory) async => entries;
  @override
  Future<GitPublicationState> publicationState(Uri directory) async =>
      const GitPublicationState(
        upstream: 'refs/remotes/origin/main',
        paths: {'lib/a.dart', 'sent-later.dart'},
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'folder expansion preserves siblings, root and nested expansion',
    () async {
      final root = Uri.parse('memory:///project/'),
          lib = Uri.parse('memory:///project/lib/');
      var calls = 0;
      final tree = ExplorerTree((uri) async {
        calls++;
        if (uri == root) {
          return [
            FileEntry(lib, 'lib', directory: true),
            FileEntry(root.resolve('README.md'), 'README.md'),
          ];
        }
        return [FileEntry(lib.resolve('main.dart'), 'main.dart')];
      }, () {});
      await tree.open(root);
      expect(calls, 1);
      await tree.toggle(lib);
      expect(tree.root, root);
      expect(tree.rows.map((r) => r.entry.name), [
        'lib',
        'main.dart',
        'README.md',
      ]);
      expect(tree.rows[1].depth, 1);
      await tree.toggle(lib);
      expect(tree.rows.length, 2);
      await tree.toggle(lib);
      expect(calls, 2);
    },
  );
  test('late directory result cannot replace a newly opened project', () async {
    final pending = Completer<List<FileEntry>>();
    final a = Uri.parse('memory:///a/'), b = Uri.parse('memory:///b/');
    final tree = ExplorerTree(
      (uri) => uri == a ? pending.future : Future.value([]),
      () {},
    );
    final opening = tree.open(a);
    await tree.open(b);
    pending.complete([FileEntry(a.resolve('old'), 'old')]);
    await opening;
    expect(tree.root, b);
    expect(tree.rows, isEmpty);
    expect(tree.loading, isEmpty);
  });
  test('directory errors are visible and retryable', () async {
    var fail = true;
    final root = Uri.parse('memory:///project/');
    final tree = ExplorerTree((_) async {
      if (fail) throw StateError('Permission denied');
      return [];
    }, () {});
    await tree.open(root);
    expect(tree.errors[root], contains('Permission denied'));
    fail = false;
    await tree.refresh();
    expect(tree.errors, isEmpty);
  });
  test('web workspace children list relative to selected directory', () async {
    final store = RepositoryMemory();
    await store.writeText('README.md', '');
    await store.writeText('lib/space name.dart', 'ok');
    await store.writeText('lib/nested/a.dart', '');
    final root = Uri.parse('fsa://test/project/');
    WorkspaceRoots.register(root, store);
    final entries = await WorkspaceRoots.listEntries(root.resolve('lib/'));
    expect(entries.map((e) => e.name), ['nested', 'space name.dart']);
    expect(await WorkspaceRoots.readText(entries.last.uri), 'ok');
    expect(await WorkspaceRoots.writeText(entries.last.uri, 'changed'), true);
    expect(await store.readText('lib/space name.dart'), 'changed');
    expect(WorkspaceRoots.contains(root.resolve('lib/')), true);
    expect(
      WorkspaceRoots.contains(Uri.parse('fsa://test/project-other/')),
      false,
    );
  });
  test(
    'theme is immediately persisted as IDE preference, not workspace preference',
    () async {
      final store = MemoryStore();
      final session = await testSession(store: store);
      session.settings.set('theme', 'night', forWorkspace: true);
      await session.selectTheme('day');
      final saved = jsonDecode(store.data['settings']!);
      expect(saved['user']['theme'], 'day');
      expect(session.theme.id, 'day');
      final restored = await testSession(store: store);
      expect(restored.theme.id, 'day');
      await session.dispose();
      await restored.dispose();
    },
  );
  test(
    'file and parent indicators distinguish dirty, untracked and unpublished',
    () async {
      final session = await testSession();
      // Reuse bootstrap-independent settings/themes with a fake read-only Git provider.
      final gitSession = await testSession(git: IndicatorGit());
      gitSession.workspaceRoot = Uri.parse('memory:///project/');
      await gitSession.refreshGitIndicators();
      final file = gitSession.workspaceRoot!.resolve('lib/a.dart');
      final d = gitSession.documents.create(
        'a.dart',
        'saved',
        uri: file,
        savedText: 'saved',
      );
      d.editor.replaceSelection('edit');
      final flags = gitSession.indicators(file);
      expect(flags.unsaved, true);
      expect(flags.modified, true);
      expect(flags.unpublished, true);
      expect(
        gitSession
            .indicators(
              gitSession.workspaceRoot!.resolve('lib/'),
              directory: true,
            )
            .modified,
        true,
      );
      expect(
        gitSession
            .indicators(gitSession.workspaceRoot!.resolve('new.dart'))
            .untracked,
        true,
      );
      expect(
        gitSession
            .indicators(gitSession.workspaceRoot!.resolve('clean.dart'))
            .any,
        false,
      );
      await session.dispose();
      await gitSession.dispose();
    },
  );
  group('unpublished commit history', () {
    late RepositoryMemory store;
    late GitObjectDatabase db;
    Future<String> commit(String contents, {String? parent}) async {
      final blob = GitObject(
        GitObjectType.blob,
        Uint8List.fromList(utf8.encode(contents)),
      );
      await db.write(blob);
      final tree = GitObject(
        GitObjectType.tree,
        encodeTree([TreeEntry('100644', 'file.dart', blob.hash)]),
      );
      await db.write(tree);
      final commit = GitObject(
        GitObjectType.commit,
        encodeCommit(
          CommitInfo(
            tree: tree.hash,
            parents: [?parent],
            author: 'A <a@local> 1 +0000',
            committer: 'A <a@local> 1 +0000',
            message: contents,
          ),
        ),
      );
      await db.write(commit);
      return commit.hash;
    }

    setUp(() async {
      store = RepositoryMemory();
      db = GitObjectDatabase(
        store,
        (bytes, offset) => (
          data: Uint8List.fromList(zlib.decode(bytes.sublist(offset))),
          next: bytes.length,
        ),
        (bytes) => Uint8List.fromList(zlib.encode(bytes)),
      );
      await db.writeHead('refs/heads/main');
      await db.writeConfig(
        remote: Uri.parse('https://example.invalid/repo.git'),
        branch: 'main',
      );
    });
    test(
      'local commits are marked and equal remote head clears them',
      () async {
        final base = await commit('base'), local = await commit('local');
        await db.writeRef('refs/heads/main', local);
        await db.writeRef('refs/remotes/origin/main', base);
        expect((await readPublicationState(db)).paths, {'file.dart'});
        await db.writeRef('refs/remotes/origin/main', local);
        expect((await readPublicationState(db)).paths, isEmpty);
      },
    );
    test('reverted changes still belong to unpublished commits', () async {
      final base = await commit('base');
      final edit = await commit('edit', parent: base);
      final revert = await commit('base', parent: edit);
      await db.writeRef('refs/heads/main', revert);
      await db.writeRef('refs/remotes/origin/main', base);
      expect((await readPublicationState(db)).paths, {'file.dart'});
    });
    test('branch only behind remote is not unpublished', () async {
      final base = await commit('base'), remote = await commit('remote');
      final advance = await commit('advance', parent: base);
      await db.writeRef('refs/heads/main', base);
      await db.writeRef('refs/remotes/origin/main', advance);
      expect((await readPublicationState(db)).paths, isEmpty);
      expect(remote, isNotEmpty);
    });
    test('missing upstream is unknown rather than falsely clean', () async {
      expect((await readPublicationState(db)).note, isNotNull);
    });
  });
}
