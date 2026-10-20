import 'dart:io';

/// Local IDE state only: requests and shared environment definitions stay visible.
const workspaceIgnorePatterns = [
  '**/.tamtoot/cache/',
  '**/.tamtoot/agents/',
  '**/.tamtoot/worktrees/',
  '**/.tamtoot/hooks/',
  '**/.tamtoot/project.json',
  '**/.tamtoot/environment.local.json',
  '**/.tamtoot/mcp.json',
];

Future<bool> ensureWorkspaceIgnore(Uri root) async {
  if (root.scheme != 'file') return false;
  final file = File.fromUri(root.resolve('.gitignore'));
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  // Do not follow user symlinks or replace another kind of entity.
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.file) {
    return false;
  }
  final existing = type == FileSystemEntityType.file
      ? await file.readAsString()
      : '';
  final lines = existing.split(RegExp(r'\r?\n')).map((s) => s.trim()).toSet();
  final missing = workspaceIgnorePatterns
      .where((p) => !lines.contains(p) && !lines.contains('/$p'))
      .toList();
  if (missing.isEmpty) return false;
  final newline = existing.contains('\r\n') ? '\r\n' : '\n';
  final separator = existing.isEmpty || existing.endsWith('\n') ? '' : newline;
  await file.writeAsString(
    '$separator$newline# Tamtoot local data$newline${missing.join(newline)}$newline',
    mode: FileMode.append,
    flush: true,
  );
  return true;
}
