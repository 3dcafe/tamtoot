import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/agents/kanban.dart';
import 'package:tamtoot/core/agents/worktree_service_io.dart';
import 'package:tamtoot/platform/git_service_io.dart';

void main() {
  test('Kanban persists statuses, outputs and validates dependencies', () async {
    final dir = await Directory.systemTemp.createTemp('tamtoot-kanban-');
    addTearDown(() => dir.delete(recursive: true));
    final store = KanbanStore(FileGitRepositoryStore(dir));
    final first = KanbanCard(
      id: 'first',
      title: 'First',
      description: 'Prepare',
      status: KanbanStatus.done,
    );
    final second = KanbanCard(
      id: 'second',
      title: 'Second',
      description: 'Build',
      dependencies: const ['first'],
      lastOutput: 'Waiting',
    );
    final board = KanbanBoard([first, second]);
    expect(board.ready(second), isTrue);
    await store.load();
    await store.save(board);
    final restored = await KanbanStore(FileGitRepositoryStore(dir)).load();
    expect(restored.cards.last.dependencies, ['first']);
    expect(restored.cards.last.lastOutput, 'Waiting');
    expect(
      () => KanbanBoard.parse(
        '{"schemaVersion":1,"cards":[{"id":"a","title":"A","dependencies":["missing"]}]}',
      ),
      throwsFormatException,
    );
  });

  test(
    'desktop worktree creates an isolated branch and excludes metadata',
    () async {
      if (Platform.isWindows) return;
      final dir = await Directory.systemTemp.createTemp('tamtoot-worktree-');
      addTearDown(() => dir.delete(recursive: true));
      Future<ProcessResult> git(List<String> args) =>
          Process.run('git', args, workingDirectory: dir.path);
      expect((await git(['init', '-b', 'main'])).exitCode, 0);
      await git(['config', 'user.name', 'Test']);
      await git(['config', 'user.email', 'test@example.com']);
      await File('${dir.path}/README.md').writeAsString('root');
      await git(['add', 'README.md']);
      expect((await git(['commit', '-m', 'initial'])).exitCode, 0);
      final uri = await AgentWorktreeService().create(dir.uri, 'task-one');
      expect(
        await File.fromUri(uri.resolve('README.md')).readAsString(),
        'root',
      );
      final branch = await Process.run('git', [
        'branch',
        '--show-current',
      ], workingDirectory: Directory.fromUri(uri).path);
      expect((branch.stdout as String).trim(), 'tamtoot/task-one');
      final status = await git(['status', '--porcelain']);
      expect((status.stdout as String).trim(), isEmpty);
    },
  );
}
