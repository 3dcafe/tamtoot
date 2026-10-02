import 'dart:typed_data';

import 'git_store.dart';

/// Presents several workspace folders as one agent filesystem.
///
/// The primary project keeps its ordinary relative paths. Additional folders
/// are mounted below stable `@name/` prefixes, so equally named files cannot be
/// confused and project-scoped `.tamtoot` data stays in the primary project.
final class MultiRootGitRepositoryStore extends GitRepositoryStore {
  MultiRootGitRepositoryStore({
    required this.primary,
    required Map<String, GitRepositoryStore> additional,
  }) : additional = Map.unmodifiable(additional);

  final GitRepositoryStore primary;
  final Map<String, GitRepositoryStore> additional;

  bool get hasAdditionalRoots => additional.isNotEmpty;

  String get mountDescription => additional.keys
      .map((name) => '@$name/ is an additional workspace folder')
      .join('\n');

  ({GitRepositoryStore store, String path}) _resolve(String path) {
    for (final entry in additional.entries) {
      final prefix = '@${entry.key}';
      if (path == prefix) return (store: entry.value, path: '');
      if (path.startsWith('$prefix/')) {
        return (store: entry.value, path: path.substring(prefix.length + 1));
      }
    }
    return (store: primary, path: path);
  }

  @override
  Future<bool> exists(String path) {
    final target = _resolve(path);
    return target.store.exists(target.path);
  }

  @override
  Future<Uint8List> readBytes(String path) {
    final target = _resolve(path);
    return target.store.readBytes(target.path);
  }

  @override
  Future<int> byteLength(String path) {
    final target = _resolve(path);
    return target.store.byteLength(target.path);
  }

  @override
  Future<Uint8List> readByteRange(String path, int start, int end) {
    final target = _resolve(path);
    return target.store.readByteRange(target.path, start, end);
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) {
    final target = _resolve(path);
    return target.store.writeBytes(target.path, bytes);
  }

  @override
  Future<void> delete(String path) {
    final target = _resolve(path);
    return target.store.delete(target.path);
  }

  @override
  Future<void> createDirectory(String path) {
    final target = _resolve(path);
    return target.store.createDirectory(target.path);
  }

  @override
  Future<void> validateRegularFilePath(String path) {
    final target = _resolve(path);
    return target.store.validateRegularFilePath(target.path);
  }

  @override
  Future<List<String>> listFiles(String dir) async {
    final target = _resolve(dir);
    if (target.store != primary || target.path != dir) {
      final files = await target.store.listFiles(target.path);
      final alias = dir.split('/').first;
      return [for (final path in files) '$alias/$path'];
    }
    final files = await primary.listFiles(dir);
    if (dir.isNotEmpty) return files;
    final result = <String>[...files];
    for (final entry in additional.entries) {
      result.addAll(
        (await entry.value.listFiles('')).map((path) => '@${entry.key}/$path'),
      );
    }
    return result;
  }
}
