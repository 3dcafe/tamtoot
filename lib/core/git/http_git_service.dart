import 'dart:convert';
import 'dart:typed_data';

import 'git_http.dart';
import 'git_objects.dart';
import 'git_pack.dart';
import 'git_service.dart';
import 'git_store.dart';
import '../workspace/tamtoot_meta.dart';

/// Pure Dart Smart-HTTP git client. Works on Android / iOS / desktop via
/// [GitHttpTransport] + [GitRepositoryStore] (no system `git` binary).
class HttpGitService implements GitService {
  HttpGitService({
    required this.transport,
    required this.openStore,
    required this.inflateAt,
    required this.deflate,
  });

  final GitHttpTransport transport;

  /// Opens a store rooted at the given workspace / clone directory.
  final GitRepositoryStore Function(Uri directory) openStore;
  final GitInflaterAt inflateAt;
  final GitDeflater deflate;

  static const _zero = '0000000000000000000000000000000000000000';

  @override
  bool get available => true;

  @override
  Future<GitResult> version() async => _ok(
    'tamtoot-http-git 0.1 (Smart HTTP, no system git)',
    const ['version'],
  );

  @override
  Future<bool> isRepository(Uri directory) async {
    final store = openStore(directory);
    return store.exists('.git/HEAD');
  }

  @override
  Future<GitResult> clone(
    Uri remote,
    Uri directory, {
    GitCredentials? credentials,
    String? branch,
    bool shallow = false,
  }) async {
    if (shallow) {
      return _fail('Shallow clone is not supported yet', const ['clone']);
    }
    final store = openStore(directory);
    await store.createDirectory('.git/objects');
    await store.createDirectory('.git/refs/heads');
    await store.createDirectory('.git/refs/remotes');

    final discovery = await discoverRefs(
      transport,
      remote,
      'git-upload-pack',
      credentials: credentials,
    );
    final refName = branch == null || branch.isEmpty
        ? discovery.defaultBranch
        : (branch.startsWith('refs/') ? branch : 'refs/heads/$branch');
    if (refName == null) {
      return _fail('Remote has no branches', const ['clone']);
    }
    final want = discovery.hashFor(refName) ?? discovery.hashFor('HEAD');
    if (want == null) {
      return _fail('Unable to resolve $refName', const ['clone']);
    }

    final pack = await _fetchPack(
      remote,
      wantHash: want,
      capabilities: discovery.capabilities,
      credentials: credentials,
    );
    final db = GitObjectDatabase(store, inflateAt, deflate);
    for (final obj in unpackPackfile(pack, inflateAt)) {
      await db.writeUnpacked(obj);
    }

    final short = refName.replaceFirst('refs/heads/', '');
    await db.writeRef(refName, want);
    await db.writeRef('refs/remotes/origin/$short', want);
    await db.writeHead(refName);
    await db.writeConfig(remote: remote, branch: short);
    await _checkout(db, store, want);
    await store.writeText(
      TamtootProjectMeta.relativePath,
      TamtootProjectMeta(
        remoteUrl: remote.toString(),
        branch: short,
        head: want,
        clonedAt: DateTime.now().toUtc(),
        lastOpenedAt: DateTime.now().toUtc(),
      ).encode(),
    );

    return _ok('Cloned $remote → $refName ($want)', [
      'clone',
      remote.toString(),
    ]);
  }

  @override
  Future<GitResult> fetch(
    Uri directory, {
    GitCredentials? credentials,
    String remote = 'origin',
  }) async {
    final store = openStore(directory);
    final db = GitObjectDatabase(store, inflateAt, deflate);
    final urlText = await db.remoteUrl(name: remote);
    if (urlText == null) {
      return _fail('Remote "$remote" not configured', const ['fetch']);
    }
    final remoteUrl = Uri.parse(urlText);
    final discovery = await discoverRefs(
      transport,
      remoteUrl,
      'git-upload-pack',
      credentials: credentials,
    );
    final branchRef = await _currentBranchRef(store);
    final wantRef = branchRef ?? discovery.defaultBranch;
    if (wantRef == null) {
      return _fail('Nothing to fetch', const ['fetch']);
    }
    final want =
        discovery.hashFor(wantRef) ??
        discovery.hashFor(wantRef.replaceFirst('refs/heads/', 'refs/heads/'));
    final resolvedWant =
        want ?? discovery.hashFor(discovery.defaultBranch ?? '');
    if (resolvedWant == null) {
      return _fail('Remote ref not found', const ['fetch']);
    }
    final have = await db.readHead();
    if (have == resolvedWant) {
      return _ok('Already up to date', const ['fetch']);
    }
    final pack = await _fetchPack(
      remoteUrl,
      wantHash: resolvedWant,
      haveHashes: have == null ? const [] : [have],
      capabilities: discovery.capabilities,
      credentials: credentials,
    );
    for (final obj in unpackPackfile(pack, inflateAt)) {
      await db.writeUnpacked(obj);
    }
    final short = wantRef.replaceFirst('refs/heads/', '');
    await db.writeRef('refs/remotes/$remote/$short', resolvedWant);
    return _ok('Fetched $resolvedWant', ['fetch', remote]);
  }

  @override
  Future<GitResult> pull(
    Uri directory, {
    GitCredentials? credentials,
    String remote = 'origin',
    String? branch,
  }) async {
    final fetchResult = await fetch(
      directory,
      credentials: credentials,
      remote: remote,
    );
    if (!fetchResult.ok) return fetchResult;

    final store = openStore(directory);
    final db = GitObjectDatabase(store, inflateAt, deflate);
    final branchRef = branch == null || branch.isEmpty
        ? await _currentBranchRef(store)
        : (branch.startsWith('refs/') ? branch : 'refs/heads/$branch');
    if (branchRef == null) {
      return _fail('Detached HEAD pull is not supported', const ['pull']);
    }
    final short = branchRef.replaceFirst('refs/heads/', '');
    final remoteHash = await db.readRef('refs/remotes/$remote/$short');
    final localHash = await db.readRef(branchRef);
    if (remoteHash == null) {
      return _fail('Missing remote-tracking ref', const ['pull']);
    }
    if (remoteHash == localHash) {
      return _ok('Already up to date', const ['pull']);
    }
    if (localHash != null &&
        !await _isAncestor(db, ancestor: localHash, tip: remoteHash)) {
      return _fail(
        'Non fast-forward pull; merge is not supported in this client',
        const ['pull'],
      );
    }
    await db.writeRef(branchRef, remoteHash);
    await _checkout(db, store, remoteHash);
    return _ok('Fast-forward to $remoteHash', const ['pull']);
  }

  @override
  Future<GitResult> push(
    Uri directory, {
    GitCredentials? credentials,
    String remote = 'origin',
    String? branch,
    bool setUpstream = false,
  }) async {
    final store = openStore(directory);
    final db = GitObjectDatabase(store, inflateAt, deflate);
    final urlText = await db.remoteUrl(name: remote);
    if (urlText == null) {
      return _fail('Remote "$remote" not configured', const ['push']);
    }
    final remoteUrl = Uri.parse(urlText);
    final branchRef = branch == null || branch.isEmpty
        ? await _currentBranchRef(store)
        : (branch.startsWith('refs/') ? branch : 'refs/heads/$branch');
    if (branchRef == null) {
      return _fail('No branch to push', const ['push']);
    }
    final newHash = await db.readRef(branchRef);
    if (newHash == null) {
      return _fail('Local branch has no commits', const ['push']);
    }

    final discovery = await discoverRefs(
      transport,
      remoteUrl,
      'git-receive-pack',
      credentials: credentials,
    );
    final oldHash = discovery.hashFor(branchRef) ?? _zero;

    if (oldHash == newHash) {
      return _ok('Everything up-to-date', const ['push']);
    }

    final objects = await _objectsToPush(
      db,
      newHash: newHash,
      oldHash: oldHash,
    );
    final pack = buildPackfile(objects, deflate);
    final body = buildReceivePackRequest(
      oldHash: oldHash,
      newHash: newHash,
      refName: branchRef,
      serverCapabilities: discovery.capabilities,
      packfile: pack,
    );

    final response = await transport.send(
      method: 'POST',
      url: gitRpcUrl(remoteUrl, 'git-receive-pack'),
      headers: {
        'Content-Type': 'application/x-git-receive-pack-request',
        'Accept': 'application/x-git-receive-pack-result',
        ...gitAuthHeaders(credentials),
      },
      body: body,
    );
    if (response.statusCode != 200) {
      return _fail(
        'Push failed (${response.statusCode}): ${utf8.decode(response.body)}',
        const ['push'],
      );
    }
    final text = utf8.decode(response.body);
    if (text.contains('ng ')) {
      return _fail('Push rejected: $text', const ['push']);
    }
    final short = branchRef.replaceFirst('refs/heads/', '');
    await db.writeRef('refs/remotes/$remote/$short', newHash);
    return _ok('Pushed $branchRef → $newHash', const ['push']);
  }

  @override
  Future<GitResult> status(Uri directory, {bool porcelain = true}) async {
    final entries = await statusEntries(directory);
    if (!porcelain) {
      final buffer = StringBuffer();
      for (final e in entries) {
        buffer.writeln('${e.index}${e.workTree} ${e.path}');
      }
      return _ok(buffer.toString(), const ['status']);
    }
    final buffer = StringBuffer();
    for (final e in entries) {
      buffer.writeln('${e.index}${e.workTree} ${e.path}');
    }
    return _ok(buffer.toString(), const ['status', '--porcelain']);
  }

  @override
  Future<List<GitStatusEntry>> statusEntries(Uri directory) async {
    final store = openStore(directory);
    final db = GitObjectDatabase(store, inflateAt, deflate);
    final head = await db.readHead();
    final headFiles = <String, String>{};
    if (head != null) {
      final commit = parseCommit((await db.read(head)).content);
      await _walkTree(db, commit.tree, '', headFiles);
    }
    final workFiles = <String, String>{};
    final paths = await store.listFiles('');
    for (final path in paths) {
      if (path == '.git' || path.startsWith('.git/')) continue;
      final bytes = await store.readBytes(path);
      workFiles[path] = hashObject(GitObjectType.blob, bytes);
    }
    final entries = <GitStatusEntry>[];
    final all = {...headFiles.keys, ...workFiles.keys};
    for (final path in all.toList()..sort()) {
      final headHash = headFiles[path];
      final workHash = workFiles[path];
      if (headHash == null && workHash != null) {
        entries.add(GitStatusEntry('?', '?', path));
      } else if (headHash != null && workHash == null) {
        entries.add(GitStatusEntry('D', ' ', path));
      } else if (headHash != workHash) {
        entries.add(GitStatusEntry(' ', 'M', path));
      }
    }
    return entries;
  }

  @override
  Future<GitResult> add(
    Uri directory, {
    List<String> paths = const ['.'],
  }) async {
    // Snapshot staging is implicit at commit time for this MVP.
    return _ok('OK (staging applied at commit)', ['add', ...paths]);
  }

  @override
  Future<GitResult> commit(
    Uri directory,
    String message, {
    bool allowEmpty = false,
  }) async {
    final store = openStore(directory);
    final db = GitObjectDatabase(store, inflateAt, deflate);
    final parent = await db.readHead();
    final entries = <TreeEntry>[];
    final paths = await store.listFiles('');
    for (final path in paths) {
      if (path.startsWith('.git/') || path == '.git') continue;
      final bytes = await store.readBytes(path);
      final blob = GitObject(GitObjectType.blob, Uint8List.fromList(bytes));
      await db.write(blob);
      entries.add(TreeEntry('100644', path, blob.hash));
    }
    // Build nested trees from flat paths
    final rootHash = await _writePathTree(db, entries);
    if (!allowEmpty && parent != null) {
      final parentCommit = parseCommit((await db.read(parent)).content);
      if (parentCommit.tree == rootHash) {
        return _fail('Nothing to commit', const ['commit']);
      }
    }
    final now = DateTime.now().toUtc();
    final ident = formatIdent('Tamtoot', 'tamtoot@local', now);
    final commit = GitObject(
      GitObjectType.commit,
      encodeCommit(
        CommitInfo(
          tree: rootHash,
          parents: parent == null ? const [] : [parent],
          author: ident,
          committer: ident,
          message: message,
        ),
      ),
    );
    await db.write(commit);
    final branchRef = await _currentBranchRef(store) ?? 'refs/heads/main';
    await db.writeRef(branchRef, commit.hash);
    await db.writeHead(branchRef);
    return _ok(commit.hash, const ['commit']);
  }

  @override
  Future<GitResult> remoteUrl(Uri directory, {String name = 'origin'}) async {
    final db = GitObjectDatabase(openStore(directory), inflateAt, deflate);
    final url = await db.remoteUrl(name: name);
    if (url == null) return _fail('Remote not found', ['remote', 'get-url']);
    return _ok(url, ['remote', 'get-url', name]);
  }

  @override
  Future<GitResult> setRemoteUrl(
    Uri directory,
    Uri url, {
    String name = 'origin',
    GitCredentials? credentials,
  }) async {
    final store = openStore(directory);
    final db = GitObjectDatabase(store, inflateAt, deflate);
    final branchRef = await _currentBranchRef(store);
    final branch = branchRef?.replaceFirst('refs/heads/', '') ?? 'main';
    await db.writeConfig(remote: url, branch: branch, remoteName: name);
    return _ok(url.toString(), ['remote', 'set-url', name]);
  }

  Future<Uint8List> _fetchPack(
    Uri remote, {
    required String wantHash,
    required Set<String> capabilities,
    List<String> haveHashes = const [],
    GitCredentials? credentials,
  }) async {
    final request = buildUploadPackRequest(
      wantHash: wantHash,
      serverCapabilities: capabilities,
      haveHashes: haveHashes,
    );
    final response = await transport.send(
      method: 'POST',
      url: gitRpcUrl(remote, 'git-upload-pack'),
      headers: {
        'Content-Type': 'application/x-git-upload-pack-request',
        'Accept': 'application/x-git-upload-pack-result',
        ...gitAuthHeaders(credentials),
      },
      body: request,
    );
    if (response.statusCode != 200) {
      throw GitException(
        'upload-pack failed (${response.statusCode}): '
        '${utf8.decode(response.body)}',
      );
    }
    return extractPackFromUploadResponse(response.body);
  }

  Future<void> _checkout(
    GitObjectDatabase db,
    GitRepositoryStore store,
    String commitHash,
  ) async {
    final commit = parseCommit((await db.read(commitHash)).content);
    final files = <String, String>{};
    await _walkTree(db, commit.tree, '', files);
    for (final entry in files.entries) {
      final blob = await db.read(entry.value);
      await store.writeBytes(entry.key, blob.content);
    }
  }

  Future<void> _walkTree(
    GitObjectDatabase db,
    String treeHash,
    String prefix,
    Map<String, String> out,
  ) async {
    final tree = parseTree((await db.read(treeHash)).content);
    for (final entry in tree) {
      final path = prefix.isEmpty ? entry.name : '$prefix/${entry.name}';
      if (entry.isTree) {
        await _walkTree(db, entry.hash, path, out);
      } else {
        out[path] = entry.hash;
      }
    }
  }

  Future<String> _writePathTree(
    GitObjectDatabase db,
    List<TreeEntry> flatFiles,
  ) async {
    final root = <String, dynamic>{};
    for (final file in flatFiles) {
      final parts = file.name.split('/');
      var node = root;
      for (var i = 0; i < parts.length - 1; i++) {
        final next = node.putIfAbsent(parts[i], () => <String, dynamic>{});
        node = next as Map<String, dynamic>;
      }
      node[parts.last] = file;
    }

    Future<String> encode(Map<String, dynamic> node) async {
      final entries = <TreeEntry>[];
      for (final key in node.keys.toList()..sort()) {
        final value = node[key];
        if (value is TreeEntry) {
          entries.add(TreeEntry(value.mode, key, value.hash));
        } else {
          final hash = await encode(value as Map<String, dynamic>);
          entries.add(TreeEntry('40000', key, hash));
        }
      }
      final tree = GitObject(GitObjectType.tree, encodeTree(entries));
      await db.write(tree);
      return tree.hash;
    }

    return encode(root);
  }

  Future<bool> _isAncestor(
    GitObjectDatabase db, {
    required String ancestor,
    required String tip,
  }) async {
    if (ancestor == tip) return true;
    final queue = <String>[tip];
    final seen = <String>{};
    while (queue.isNotEmpty) {
      final hash = queue.removeLast();
      if (!seen.add(hash)) continue;
      if (hash == ancestor) return true;
      final obj = await db.read(hash);
      if (obj.type != GitObjectType.commit) continue;
      queue.addAll(parseCommit(obj.content).parents);
    }
    return false;
  }

  Future<List<GitObject>> _objectsToPush(
    GitObjectDatabase db, {
    required String newHash,
    required String oldHash,
  }) async {
    final result = <GitObject>[];
    final seen = <String>{};
    if (oldHash != _zero) seen.add(oldHash);

    Future<void> walk(String hash) async {
      if (!seen.add(hash)) return;
      // Stop if we hit old history
      if (oldHash != _zero &&
          await _isAncestor(db, ancestor: oldHash, tip: hash) &&
          hash != newHash) {
        // Still need objects not on old? Simpler: walk all from newHash and skip
        // any commit that is ancestor of oldHash...
      }
      final obj = await db.read(hash);
      result.add(obj);
      if (obj.type == GitObjectType.commit) {
        final info = parseCommit(obj.content);
        await walk(info.tree);
        for (final parent in info.parents) {
          if (parent == oldHash) continue;
          if (oldHash != _zero &&
              await _isAncestor(db, ancestor: oldHash, tip: parent)) {
            continue;
          }
          await walk(parent);
        }
      } else if (obj.type == GitObjectType.tree) {
        for (final entry in parseTree(obj.content)) {
          await walk(entry.hash);
        }
      }
    }

    await walk(newHash);
    // Filter out anything reachable from oldHash
    if (oldHash != _zero) {
      final oldReachable = <String>{};
      Future<void> mark(String hash) async {
        if (!oldReachable.add(hash)) return;
        final obj = await db.read(hash);
        if (obj.type == GitObjectType.commit) {
          final info = parseCommit(obj.content);
          await mark(info.tree);
          for (final p in info.parents) {
            await mark(p);
          }
        } else if (obj.type == GitObjectType.tree) {
          for (final e in parseTree(obj.content)) {
            await mark(e.hash);
          }
        }
      }

      await mark(oldHash);
      result.removeWhere((o) => oldReachable.contains(o.hash));
    }
    return result;
  }

  Future<String?> _currentBranchRef(GitRepositoryStore store) async {
    if (!await store.exists('.git/HEAD')) return null;
    final text = (await store.readText('.git/HEAD')).trim();
    if (text.startsWith('ref: ')) return text.substring(5);
    return null;
  }

  GitResult _ok(String stdout, List<String> args) =>
      GitResult(exitCode: 0, stdout: stdout, stderr: '', arguments: args);

  GitResult _fail(String stderr, List<String> args) =>
      GitResult(exitCode: 1, stdout: '', stderr: stderr, arguments: args);
}
