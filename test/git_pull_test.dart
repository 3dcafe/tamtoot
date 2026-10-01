import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/git/git_http.dart';
import 'package:tamtoot/core/git/git_index.dart';
import 'package:tamtoot/core/git/git_objects.dart';
import 'package:tamtoot/core/git/git_pack.dart';
import 'package:tamtoot/core/git/git_store.dart';
import 'package:tamtoot/core/git/http_git_service.dart';
import 'package:tamtoot/core/git/pkt_line.dart';
import 'package:tamtoot/platform/git_shared.dart';

import 'explorer_test.dart' show RepositoryMemory;

class _PullTransport implements GitHttpTransport {
  _PullTransport(this.tip, this.objects);
  final String tip;
  final List<GitObject> objects;
  int gets = 0, posts = 0;

  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    if (method == 'GET') {
      gets++;
      return GitHttpResponse(
        statusCode: 200,
        body: Uint8List.fromList([
          ...PktLine.encodeText('# service=git-upload-pack'),
          ...PktLine.encodeFlush(),
          ...PktLine.encode(
            utf8.encode(
              '$tip HEAD\x00symref=HEAD:refs/heads/main side-band-64k\n',
            ),
          ),
          ...PktLine.encodeText('$tip refs/heads/main'),
          ...PktLine.encodeFlush(),
        ]),
      );
    }
    posts++;
    final pack = buildPackfile(objects, archiveDeflate);
    return GitHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList([
        ...PktLine.encodeText('NAK'),
        ...PktLine.encode([1, ...pack]),
        ...PktLine.encodeFlush(),
      ]),
    );
  }
}

GitObject _commit(String tree, {String? parent, String message = 'commit'}) =>
    GitObject(
      GitObjectType.commit,
      encodeCommit(
        CommitInfo(
          tree: tree,
          parents: [?parent],
          author: 'Test <test@example.com> 0 +0000',
          committer: 'Test <test@example.com> 0 +0000',
          message: message,
        ),
      ),
    );

void main() {
  const root = 'memory:///project/';

  test(
    'pull fast-forwards, updates index and removes remote deletions',
    () async {
      final store = RepositoryMemory();
      final oldBlob = GitObject(GitObjectType.blob, utf8.encode('old'));
      final keptBlob = GitObject(GitObjectType.blob, utf8.encode('before'));
      final baseTree = GitObject(
        GitObjectType.tree,
        encodeTree([
          TreeEntry('100644', 'old.txt', oldBlob.hash),
          TreeEntry('100644', 'kept.txt', keptBlob.hash),
        ]),
      );
      final base = _commit(baseTree.hash, message: 'base');
      final changedBlob = GitObject(GitObjectType.blob, utf8.encode('after'));
      final addedBlob = GitObject(GitObjectType.blob, utf8.encode('new'));
      final remoteTree = GitObject(
        GitObjectType.tree,
        encodeTree([
          TreeEntry('100644', 'kept.txt', changedBlob.hash),
          TreeEntry('100644', 'new.txt', addedBlob.hash),
        ]),
      );
      final remote = _commit(
        remoteTree.hash,
        parent: base.hash,
        message: 'remote',
      );
      final database = GitObjectDatabase(
        store,
        archiveInflateAt,
        archiveDeflate,
      );
      for (final object in [oldBlob, keptBlob, baseTree, base]) {
        await database.write(object);
      }
      await database.writeHead('refs/heads/main');
      await database.writeRef('refs/heads/main', base.hash);
      await database.writeConfig(
        remote: Uri.parse('https://example.com/repository.git'),
        branch: 'main',
      );
      await store.writeText('old.txt', 'old');
      await store.writeText('kept.txt', 'before');
      final transport = _PullTransport(remote.hash, [
        changedBlob,
        addedBlob,
        remoteTree,
        remote,
      ]);
      final git = HttpGitService(
        transport: transport,
        openStore: (_) => store,
        inflateAt: archiveInflateAt,
        deflate: archiveDeflate,
      );

      final result = await git.pull(Uri.parse(root));
      expect(result.ok, isTrue);
      expect(result.stdout, contains('M  kept.txt'));
      expect(result.stdout, contains('A  new.txt'));
      expect(result.stdout, contains('D  old.txt'));
      expect(await database.readHead(), remote.hash);
      expect(await database.readRef('refs/remotes/origin/main'), remote.hash);
      expect(await store.readText('kept.txt'), 'after');
      expect(await store.readText('new.txt'), 'new');
      expect(await store.exists('old.txt'), isFalse);
      expect(readGitIndex(await store.readBytes('.git/index')).keys, {
        'kept.txt',
        'new.txt',
      });
      expect(await git.statusEntries(Uri.parse(root)), isEmpty);

      await store.writeText('kept.txt', 'local edit');
      final calls = transport.gets + transport.posts;
      final rejected = await git.pull(Uri.parse(root));
      expect(rejected.ok, isFalse);
      expect(rejected.stderr, contains('local changes'));
      expect(transport.gets + transport.posts, calls);
      expect(await store.readText('kept.txt'), 'local edit');
    },
  );

  test('pull keeps a clean local branch that is already ahead', () async {
    final store = RepositoryMemory();
    final blob = GitObject(GitObjectType.blob, utf8.encode('content'));
    final tree = GitObject(
      GitObjectType.tree,
      encodeTree([TreeEntry('100644', 'file.txt', blob.hash)]),
    );
    final remote = _commit(tree.hash, message: 'remote');
    final local = _commit(tree.hash, parent: remote.hash, message: 'local');
    final database = GitObjectDatabase(store, archiveInflateAt, archiveDeflate);
    for (final object in [blob, tree, remote, local]) {
      await database.write(object);
    }
    await database.writeHead('refs/heads/main');
    await database.writeRef('refs/heads/main', local.hash);
    await database.writeConfig(
      remote: Uri.parse('https://example.com/repository.git'),
      branch: 'main',
    );
    await store.writeText('file.txt', 'content');
    final transport = _PullTransport(remote.hash, const []);
    final git = HttpGitService(
      transport: transport,
      openStore: (_) => store,
      inflateAt: archiveInflateAt,
      deflate: archiveDeflate,
    );

    final result = await git.pull(Uri.parse(root));
    expect(result.ok, isTrue);
    expect(result.stdout, contains('ahead'));
    expect(await database.readHead(), local.hash);
    expect(await database.readRef('refs/remotes/origin/main'), remote.hash);
    expect(transport.gets, 1);
    expect(transport.posts, 0);
  });

  test('pull automatically merges non-conflicting divergent commits', () async {
    final store = RepositoryMemory();
    final baseA = GitObject(GitObjectType.blob, utf8.encode('a0'));
    final baseB = GitObject(GitObjectType.blob, utf8.encode('b0'));
    final baseTree = GitObject(
      GitObjectType.tree,
      encodeTree([
        TreeEntry('100644', 'a.txt', baseA.hash),
        TreeEntry('100644', 'b.txt', baseB.hash),
      ]),
    );
    final base = _commit(baseTree.hash, message: 'base');
    final localA = GitObject(GitObjectType.blob, utf8.encode('a-local'));
    final localTree = GitObject(
      GitObjectType.tree,
      encodeTree([
        TreeEntry('100644', 'a.txt', localA.hash),
        TreeEntry('100644', 'b.txt', baseB.hash),
      ]),
    );
    final local = _commit(localTree.hash, parent: base.hash, message: 'local');
    final remoteB = GitObject(GitObjectType.blob, utf8.encode('b-remote'));
    final remoteTree = GitObject(
      GitObjectType.tree,
      encodeTree([
        TreeEntry('100644', 'a.txt', baseA.hash),
        TreeEntry('100644', 'b.txt', remoteB.hash),
      ]),
    );
    final remote = _commit(
      remoteTree.hash,
      parent: base.hash,
      message: 'remote',
    );
    final database = GitObjectDatabase(store, archiveInflateAt, archiveDeflate);
    for (final object in [
      baseA,
      baseB,
      baseTree,
      base,
      localA,
      localTree,
      local,
    ]) {
      await database.write(object);
    }
    await database.writeHead('refs/heads/main');
    await database.writeRef('refs/heads/main', local.hash);
    await database.writeConfig(
      remote: Uri.parse('https://example.com/repository.git'),
      branch: 'main',
    );
    await store.writeText('a.txt', 'a-local');
    await store.writeText('b.txt', 'b0');
    final transport = _PullTransport(remote.hash, [
      remoteB,
      remoteTree,
      remote,
    ]);
    final git = HttpGitService(
      transport: transport,
      openStore: (_) => store,
      inflateAt: archiveInflateAt,
      deflate: archiveDeflate,
    );
    await git.setIdentity(Uri.parse(root), 'Test Author', 'test@example.com');

    final result = await git.pull(Uri.parse(root));

    expect(result.ok, isTrue);
    expect(result.stdout, contains('Merged origin/main into main'));
    expect(await store.readText('a.txt'), 'a-local');
    expect(await store.readText('b.txt'), 'b-remote');
    final mergeHash = await database.readHead();
    final merge = parseCommit((await database.read(mergeHash!)).content);
    expect(merge.parents, [local.hash, remote.hash]);
    expect(await git.statusEntries(Uri.parse(root)), isEmpty);
  });
}
