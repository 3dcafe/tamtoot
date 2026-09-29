import 'dart:io';

class AgentWorktreeService {
  Future<Uri> create(Uri root, String taskId) async {
    if (root.scheme != 'file' ||
        !RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(taskId)) {
      throw const FormatException('Invalid worktree request.');
    }
    final repository = Directory.fromUri(root);
    final exclude = File('${repository.path}/.git/info/exclude');
    final existing = await exclude.exists() ? await exclude.readAsString() : '';
    const localPatterns = [
      '/.tamtoot/project.json',
      '/.tamtoot/environment.local.json',
      '/.tamtoot/agents/',
      '/.tamtoot/hooks/',
      '/.tamtoot/mcp.json',
      '/.tamtoot/worktrees/',
    ];
    final existingLines = existing.split('\n').toSet();
    if (existingLines.contains('/.tamtoot/') ||
        localPatterns.any((pattern) => !existingLines.contains(pattern))) {
      await exclude.parent.create(recursive: true);
      final retained = existing
          .split('\n')
          .where((line) => line.trim() != '/.tamtoot/')
          .where((line) => line.trim().isNotEmpty)
          .toList();
      for (final pattern in localPatterns) {
        if (!retained.contains(pattern)) retained.add(pattern);
      }
      await exclude.writeAsString(
        '${retained.join('\n')}\n',
        flush: true,
      );
    }
    final directory = Directory(
      '${repository.path}/.tamtoot/worktrees/$taskId',
    );
    if (await directory.exists()) {
      final marker = File('${directory.path}/.git');
      if (await marker.exists()) return directory.uri;
      throw StateError('Worktree path already exists: ${directory.path}');
    }
    final branch = 'tamtoot/$taskId';
    final result = await Process.run(
      'git',
      ['worktree', 'add', '-b', branch, directory.path, 'HEAD'],
      workingDirectory: repository.path,
      runInShell: false,
    );
    if (result.exitCode != 0) {
      throw StateError('git worktree add failed: ${result.stderr}');
    }
    return directory.uri;
  }
}
