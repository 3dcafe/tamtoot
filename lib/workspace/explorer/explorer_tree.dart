import '../../core/filesystem/filesystem.dart';

class ExplorerRow {
  const ExplorerRow(this.entry, this.depth);
  final FileEntry entry;
  final int depth;
}

/// Lazy directory tree. Expanding a child never changes the workspace root.
class ExplorerTree {
  ExplorerTree(this.list, this.notify);
  final Future<List<FileEntry>> Function(Uri) list;
  final void Function() notify;
  Uri? root;
  int _generation = 0;
  final Map<Uri, List<FileEntry>> children = {};
  final Set<Uri> expanded = {}, loading = {};
  final Map<Uri, String> errors = {};

  Future<void> open(Uri uri) async {
    _generation++;
    root = uri;
    children.clear();
    expanded.clear();
    loading.clear();
    errors.clear();
    expanded.add(uri);
    await _load(uri);
  }

  Future<void> _load(Uri uri) async {
    if (loading.contains(uri)) return;
    final generation = _generation;
    loading.add(uri);
    errors.remove(uri);
    notify();
    try {
      final entries = await list(uri);
      if (generation != _generation) return;
      children[uri] = [...entries]
        ..sort(
          (a, b) => a.directory == b.directory
              ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
              : a.directory
              ? -1
              : 1,
        );
    } catch (error) {
      if (generation == _generation) errors[uri] = '$error';
    } finally {
      if (generation == _generation) {
        loading.remove(uri);
        notify();
      }
    }
  }

  Future<void> toggle(Uri uri) async {
    if (!rows.any((row) => row.entry.uri == uri && row.entry.directory)) return;
    if (!expanded.remove(uri)) {
      expanded.add(uri);
      if (!children.containsKey(uri) || errors.containsKey(uri)) {
        await _load(uri);
      }
    }
    notify();
  }

  Future<void> refresh() async {
    final uri = root;
    if (uri == null) return;
    final generation = _generation;
    await _load(uri);
    for (final dir in expanded.toList()) {
      if (generation != _generation) return;
      if (dir != uri && rows.any((row) => row.entry.uri == dir)) {
        await _load(dir);
      }
    }
  }

  List<ExplorerRow> get rows {
    final result = <ExplorerRow>[];
    void visit(Uri directory, int depth) {
      if (depth > 64) return;
      for (final entry in children[directory] ?? const <FileEntry>[]) {
        result.add(ExplorerRow(entry, depth));
        if (entry.directory && expanded.contains(entry.uri)) {
          visit(entry.uri, depth + 1);
        }
      }
    }

    if (root != null) visit(root!, 0);
    return result;
  }
}
