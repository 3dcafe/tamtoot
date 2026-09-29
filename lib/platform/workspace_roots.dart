/// In-process registry of workspace stores (used by web File System Access roots).
library;

import '../core/filesystem/filesystem.dart';
import '../core/git/git_store.dart';

final class WorkspaceRoots {
  static final Map<String, GitRepositoryStore> _stores = {};

  static void register(Uri root, GitRepositoryStore store) {
    _stores[root.toString()] = store;
  }

  static GitRepositoryStore? storeFor(Uri root) => _stores[root.toString()];

  static bool contains(Uri uri) =>
      _stores.keys.any((key) => _isUnder(Uri.parse(key), uri));

  static Future<List<FileEntry>> listEntries(Uri directory) async {
    final roots =
        _stores.keys
            .where((key) => _isUnder(Uri.parse(key), directory))
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    if (roots.isEmpty) return const [];
    final root = Uri.parse(roots.first), store = _stores[roots.first]!;
    final relative = Uri.decodeComponent(
      _relative(root, directory)!,
    ).replaceAll(RegExp(r'/+$'), '');
    final prefix = relative.isEmpty ? '' : '$relative/';
    final paths = await store.listFiles(relative);
    final entries = <String, FileEntry>{};
    final base = Uri.parse(
      '${directory.toString().replaceAll(RegExp(r'/+$'), '')}/',
    );
    for (final path in paths) {
      if (!path.startsWith(prefix)) continue;
      final remainder = path.substring(prefix.length);
      if (remainder.isEmpty) continue;
      final parts = remainder.split('/'), name = remainder.split('/').first;
      if (name == '.git') continue;
      final isDirectory = parts.length > 1;
      entries[name] = FileEntry(
        base.resolve('${Uri.encodeComponent(name)}${isDirectory ? '/' : ''}'),
        name,
        directory: isDirectory,
      );
    }
    return entries.values.toList()..sort(
      (a, b) => a.directory == b.directory
          ? a.name.compareTo(b.name)
          : a.directory
          ? -1
          : 1,
    );
  }

  static Future<String?> readText(Uri fileUri) async {
    // fsa://local/repo/path/to/file
    for (final entry in _stores.entries) {
      final root = Uri.parse(entry.key);
      if (!_isUnder(root, fileUri)) continue;
      final relative = _relative(root, fileUri);
      if (relative == null) continue;
      try {
        return await entry.value.readText(Uri.decodeComponent(relative));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Future<bool> writeText(Uri fileUri, String text) async {
    for (final entry in _stores.entries) {
      final root = Uri.parse(entry.key);
      if (!_isUnder(root, fileUri)) continue;
      final relative = _relative(root, fileUri);
      if (relative == null || relative.isEmpty) continue;
      await entry.value.writeText(Uri.decodeComponent(relative), text);
      return true;
    }
    return false;
  }
}

bool _isUnder(Uri root, Uri child) {
  final r = root.toString().replaceAll(RegExp(r'/+$'), '');
  final c = child.toString();
  return c == r || c.startsWith('$r/');
}

String? _relative(Uri root, Uri child) {
  final r = root.toString().replaceAll(RegExp(r'/+$'), '');
  final c = child.toString();
  if (c == r) return '';
  if (!c.startsWith('$r/')) return null;
  return c.substring(r.length + 1);
}
