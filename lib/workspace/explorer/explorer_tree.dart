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
  final List<Uri> roots = [];
  int _generation = 0;
  final Map<Uri, List<FileEntry>> children = {};
  final Set<Uri> expanded = {}, loading = {};
  final Map<Uri, String> errors = {};

  void clear() {
    _generation++;
    root = null;
    roots.clear();
    children.clear();
    expanded.clear();
    loading.clear();
    errors.clear();
    notify();
  }

  Future<void> open(Uri uri) async {
    _generation++;
    root = uri;
    roots
      ..clear()
      ..add(uri);
    children.clear();
    expanded.clear();
    loading.clear();
    errors.clear();
    expanded.add(uri);
    await _load(uri);
  }

  Future<void> addRoot(Uri uri) async {
    if (roots.contains(uri)) return;
    roots.add(uri);
    expanded.add(uri);
    await _load(uri);
  }

  void removeRoot(Uri uri) {
    if (uri == root) return;
    roots.remove(uri);
    children.removeWhere((key, _) => _isUnder(uri, key));
    expanded.removeWhere((key) => _isUnder(uri, key));
    loading.removeWhere((key) => _isUnder(uri, key));
    errors.removeWhere((key, _) => _isUnder(uri, key));
    notify();
  }

  Future<void> _load(Uri uri) async {
    if (loading.contains(uri)) return;
    final generation = _generation;
    loading.add(uri);
    errors.remove(uri);
    notify();
    try {
      final entries = await list(uri);
      if (generation != _generation ||
          !roots.any((root) => _isUnder(root, uri))) {
        return;
      }
      children[uri] = [...entries]
        ..sort(
          (a, b) => a.directory == b.directory
              ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
              : a.directory
              ? -1
              : 1,
        );
    } catch (error) {
      if (generation == _generation &&
          roots.any((root) => _isUnder(root, uri))) {
        errors[uri] = '$error';
      }
    } finally {
      loading.remove(uri);
      if (generation == _generation) {
        notify();
      }
    }
  }

  Future<void> toggle(Uri uri) async {
    if (!roots.contains(uri) &&
        !rows.any((row) => row.entry.uri == uri && row.entry.directory)) {
      return;
    }
    if (!expanded.remove(uri)) {
      expanded.add(uri);
      if (!children.containsKey(uri) || errors.containsKey(uri)) {
        await _load(uri);
      }
    }
    notify();
  }

  Future<void> refresh() async {
    if (roots.isEmpty) return;
    final generation = _generation;
    for (final uri in roots.toList()) {
      await _load(uri);
      if (generation != _generation) return;
    }
    for (final dir in expanded.toList()) {
      if (generation != _generation) return;
      if (!roots.contains(dir) && rows.any((row) => row.entry.uri == dir)) {
        await _load(dir);
      }
    }
  }

  List<ExplorerRow> rowsFor(Uri root) {
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

    if (expanded.contains(root)) visit(root, 0);
    return result;
  }

  List<ExplorerRow> get rows => [for (final root in roots) ...rowsFor(root)];
}

bool _isUnder(Uri root, Uri child) {
  final parent = root.toString().replaceAll(RegExp(r'/+$'), '');
  final value = child.toString();
  return value == parent || value.startsWith('$parent/');
}
