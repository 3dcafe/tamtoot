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

  static Future<List<FileEntry>> listEntries(Uri root) async {
    final store = storeFor(root);
    if (store == null) return const [];
    final paths = await store.listFiles('');
    final entries = <FileEntry>[];
    final seenDirs = <String>{};
    for (final path in paths) {
      final parts = path.split('/');
      if (parts.length > 1) {
        final top = parts.first;
        if (seenDirs.add(top)) {
          entries.add(FileEntry(root.resolve('$top/'), top, directory: true));
        }
      } else {
        entries.add(FileEntry(root.resolve(path), path));
      }
    }
    // Also include nested files when browsing a subdirectory — caller passes root.
    if (root.pathSegments.where((s) => s.isNotEmpty).isNotEmpty) {
      // listing is always from store root relative paths; IdeSession uses flat list
      // at workspace root only for MVP.
    }
    entries.sort(
      (a, b) => a.directory == b.directory
          ? a.name.compareTo(b.name)
          : a.directory
          ? -1
          : 1,
    );
    return entries;
  }

  static Future<String?> readText(Uri fileUri) async {
    // fsa://local/repo/path/to/file
    for (final entry in _stores.entries) {
      final root = Uri.parse(entry.key);
      if (!_isUnder(root, fileUri)) continue;
      final relative = _relative(root, fileUri);
      if (relative == null) continue;
      try {
        return await entry.value.readText(relative);
      } catch (_) {
        return null;
      }
    }
    return null;
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
