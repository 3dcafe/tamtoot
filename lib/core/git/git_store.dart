import 'dart:convert';
import 'dart:typed_data';

import 'git_delta.dart';
import 'git_ignore.dart';
import 'git_objects.dart';
import 'git_pack.dart';
import 'git_service.dart';

/// Byte-oriented repository filesystem (relative paths use `/`).
abstract class GitRepositoryStore {
  Future<bool> exists(String path);
  Future<Uint8List> readBytes(String path);
  Future<int> byteLength(String path) async => (await readBytes(path)).length;
  Future<Uint8List> readByteRange(String path, int start, int end) async {
    final bytes = await readBytes(path);
    return Uint8List.sublistView(bytes, start, end);
  }

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

  /// Work-tree files after repository ignore rules. Native stores override this
  /// to prune ignored directories before enumerating their contents.
  Future<List<String>> listGitWorkFiles() async {
    final ignore = GitIgnore();
    if (await exists('.git/info/exclude')) {
      ignore.add(await readText('.git/info/exclude'));
    }
    if (await exists('.gitignore')) ignore.add(await readText('.gitignore'));
    final files = await listFiles('');
    final nested = files.where((path) => path.endsWith('/.gitignore')).toList()
      ..sort((a, b) {
        final depth = '/'
            .allMatches(a)
            .length
            .compareTo('/'.allMatches(b).length);
        return depth != 0 ? depth : a.compareTo(b);
      });
    for (final path in nested) {
      ignore.add(
        await readText(path),
        base: path.substring(0, path.length - '/.gitignore'.length),
      );
    }
    return files
        .where((path) => !ignore.ignores(path, directory: false))
        .toList();
  }
}

final class GitObjectDatabase {
  GitObjectDatabase(this.store, this.inflateAt, this.deflate);
  final GitRepositoryStore store;
  final GitInflaterAt inflateAt;
  final GitDeflater deflate;
  List<_PackFiles>? _packs;
  final _packedByHash = <String, GitObject>{};
  final _packedByOffset = <String, Map<int, GitObject>>{};

  String _loosePath(String hash) =>
      '.git/objects/${hash.substring(0, 2)}/${hash.substring(2)}';

  Future<bool> has(String hash) async {
    if (await store.exists(_loosePath(hash))) return true;
    if (_packedByHash.containsKey(hash)) return true;
    return await _packForHash(hash) != null;
  }

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
    if (await store.exists(path)) {
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
    final cached = _packedByHash[hash];
    if (cached != null) return cached;
    final location = await _packForHash(hash);
    if (location == null) throw GitException('Missing object $hash');
    final object = await _readPackedAt(location.pack, location.offset);
    if (object.hash != hash) {
      throw FormatException('Pack index points to the wrong object for $hash');
    }
    return object;
  }

  Future<_PackLocation?> _packForHash(String hash) async {
    for (final pack in await _packFiles()) {
      final offset = pack.index.offsetForHash(hash);
      if (offset != null) return _PackLocation(pack, offset);
    }
    return null;
  }

  Future<List<_PackFiles>> _packFiles() async {
    final cached = _packs;
    if (cached != null) return cached;
    final result = <_PackFiles>[];
    final files = await store.listFiles('.git/objects/pack');
    for (final indexPath in files.where((path) => path.endsWith('.idx'))) {
      final packPath = '${indexPath.substring(0, indexPath.length - 4)}.pack';
      if (!await store.exists(packPath)) continue;
      final index = readGitPackIndex(await store.readBytes(indexPath));
      result.add(_PackFiles(packPath, index));
    }
    return _packs = result;
  }

  Future<GitObject> _readPackedAt(_PackFiles pack, int offset) async {
    final cache = _packedByOffset.putIfAbsent(pack.path, () => {});
    final cached = cache[offset];
    if (cached != null) return cached;
    final packLength = await store.byteLength(pack.path);
    final end = pack.index.endForOffset(offset, packLength);
    if (offset < 12 || end <= offset || end > packLength - 20) {
      throw const FormatException('Invalid packed object offset');
    }
    final record = await store.readByteRange(pack.path, offset, end);
    var cursor = 0;
    var byte = record[cursor++];
    final typeCode = (byte >> 4) & 0x7;
    while ((byte & 0x80) != 0) {
      if (cursor >= record.length) {
        throw const FormatException('Truncated packed object header');
      }
      byte = record[cursor++];
    }

    late final GitObject object;
    if (typeCode == 6) {
      if (cursor >= record.length) {
        throw const FormatException('Truncated ofs-delta header');
      }
      var value = record[cursor++];
      var distance = value & 0x7f;
      while ((value & 0x80) != 0) {
        if (cursor >= record.length) {
          throw const FormatException('Truncated ofs-delta offset');
        }
        value = record[cursor++];
        distance = ((distance + 1) << 7) | (value & 0x7f);
      }
      final baseOffset = offset - distance;
      final inflated = inflateAt(record, cursor).data;
      final base = await _readPackedAt(pack, baseOffset);
      object = GitObject(base.type, applyGitDelta(base.content, inflated));
    } else if (typeCode == 7) {
      if (cursor + 20 > record.length) {
        throw const FormatException('Truncated ref-delta hash');
      }
      final baseHash = bytesToHex(record.sublist(cursor, cursor + 20));
      cursor += 20;
      final inflated = inflateAt(record, cursor).data;
      final base = await read(baseHash);
      object = GitObject(base.type, applyGitDelta(base.content, inflated));
    } else {
      if (typeCode < 1 || typeCode > 4) {
        throw FormatException('Unsupported packed object type $typeCode');
      }
      object = GitObject(
        GitObjectType.fromCode(typeCode),
        inflateAt(record, cursor).data,
      );
    }
    cache[offset] = object;
    _packedByHash[object.hash] = object;
    return object;
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

final class _PackFiles {
  const _PackFiles(this.path, this.index);
  final String path;
  final GitPackIndex index;
}

final class _PackLocation {
  const _PackLocation(this.pack, this.offset);
  final _PackFiles pack;
  final int offset;
}
