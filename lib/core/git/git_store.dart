import 'dart:convert';
import 'dart:typed_data';

import 'git_objects.dart';
import 'git_pack.dart';
import 'git_service.dart';

/// Byte-oriented repository filesystem (relative paths use `/`).
abstract class GitRepositoryStore {
  Future<bool> exists(String path);
  Future<Uint8List> readBytes(String path);
  Future<String> readText(String path) async =>
      utf8.decode(await readBytes(path));
  Future<void> writeBytes(String path, List<int> bytes);
  Future<void> writeText(String path, String text) =>
      writeBytes(path, utf8.encode(text));
  Future<void> delete(String path);
  Future<void> createDirectory(String path);

  /// Stores with symlinks must reject paths that would escape through a link.
  Future<void> validateRegularFilePath(String path) async {}

  /// Relative file paths under [dir], recursive, using `/` separators.
  /// Skips `.git` when listing the work tree root.
  Future<List<String>> listFiles(String dir);
}

final class GitObjectDatabase {
  GitObjectDatabase(this.store, this.inflateAt, this.deflate);
  final GitRepositoryStore store;
  final GitInflaterAt inflateAt;
  final GitDeflater deflate;

  String _loosePath(String hash) =>
      '.git/objects/${hash.substring(0, 2)}/${hash.substring(2)}';

  Future<bool> has(String hash) => store.exists(_loosePath(hash));

  Future<void> write(GitObject object) async {
    final hash = object.hash;
    final path = _loosePath(hash);
    if (await store.exists(path)) return;
    await store.writeBytes(path, deflate(object.looseBytes));
  }

  Future<void> writeUnpacked(UnpackedObject object) async {
    await write(GitObject(object.type, object.data));
  }

  Future<GitObject> read(String hash) async {
    final path = _loosePath(hash);
    if (!await store.exists(path)) {
      throw GitException('Missing object $hash');
    }
    final raw = await store.readBytes(path);
    final inflated = inflateAt(raw, 0).data;
    final nul = inflated.indexOf(0);
    if (nul <= 0) throw FormatException('Corrupt loose object $hash');
    final header = utf8.decode(inflated.sublist(0, nul));
    final space = header.indexOf(' ');
    final type = GitObjectType.fromName(header.substring(0, space));
    final content = inflated.sublist(nul + 1);
    return GitObject(type, content);
  }

  Future<String?> readHead() async {
    if (!await store.exists('.git/HEAD')) return null;
    final text = (await store.readText('.git/HEAD')).trim();
    if (text.startsWith('ref: ')) {
      final ref = text.substring(5);
      return readRef(ref);
    }
    return text;
  }

  Future<String?> readRef(String name) async {
    final path = name.startsWith('refs/') ? '.git/$name' : '.git/refs/$name';
    // also packed-refs later
    if (await store.exists(path)) {
      return (await store.readText(path)).trim().split('\n').first;
    }
    if (await store.exists('.git/packed-refs')) {
      final lines = (await store.readText('.git/packed-refs')).split('\n');
      for (final line in lines) {
        if (line.startsWith('#') || line.isEmpty) continue;
        final parts = line.split(' ');
        if (parts.length >= 2 && parts[1] == name) return parts[0];
      }
    }
    return null;
  }

  Future<void> writeRef(String name, String hash) async {
    final path = name.startsWith('refs/') ? '.git/$name' : '.git/refs/$name';
    await store.writeText(path, '$hash\n');
  }

  Future<void> writeHead(String refName) async {
    await store.writeText('.git/HEAD', 'ref: $refName\n');
  }

  Future<String?> remoteUrl({String name = 'origin'}) async {
    if (!await store.exists('.git/config')) return null;
    final text = await store.readText('.git/config');
    final section = RegExp(
      '\\[remote "$name"\\]([\\s\\S]*?)(\\n\\[|\$)',
    ).firstMatch(text);
    if (section == null) return null;
    final url = RegExp(r'url\s*=\s*(.+)').firstMatch(section.group(1)!);
    return url?.group(1)?.trim();
  }

  Future<void> writeConfig({
    required Uri remote,
    required String branch,
    String remoteName = 'origin',
  }) async {
    final text =
        '''
[core]
	repositoryformatversion = 0
	filemode = true
	bare = false
[remote "$remoteName"]
	url = $remote
	fetch = +refs/heads/*:refs/remotes/$remoteName/*
[branch "$branch"]
	remote = $remoteName
	merge = refs/heads/$branch
''';
    await store.writeText('.git/config', text);
  }
}
