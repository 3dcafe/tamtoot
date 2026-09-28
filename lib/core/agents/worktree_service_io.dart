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
    if (!existing.split('\n').contains('/.tamtoot/')) {
      await exclude.parent.create(recursive: true);
      await exclude.writeAsString(
        '${existing.trimRight()}${existing.trim().isEmpty ? '' : '\n'}/.tamtoot/\n',
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
