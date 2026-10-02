import 'package:flutter/material.dart';

import '../app/git_file_changes.dart';
import '../app/ide_session.dart';
import '../core/git/git_service.dart';
import '../core/git/text_diff.dart';

class GitHistoryDialog extends StatelessWidget {
  const GitHistoryDialog({
    super.key,
    required this.session,
    required this.root,
    required this.branch,
    required this.safeError,
  });

  final IdeSession session;
  final Uri root;
  final String branch;
  final String Function(Object error) safeError;

  @override
  Widget build(BuildContext context) {
    final provider = session.git as GitHistoryProvider;
    return AlertDialog(
      title: Text('Commit history · $branch'),
      content: SizedBox(
        width: 760,
        height: MediaQuery.sizeOf(context).height * .68,
        child: FutureBuilder<List<GitCommitSummary>>(
          future: _loadHistory(provider),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return SelectableText(safeError(snapshot.error!));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final commits = snapshot.data!;
            if (commits.isEmpty) {
              return const Center(child: Text('No commits yet.'));
            }
            return ListView.separated(
              itemCount: commits.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, index) {
                final commit = commits[index];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.commit, size: 18),
                  title: Text(
                    commit.message.split('\n').first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(_commitSubtitle(commit)),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => _CommitDetailsDialog(
                      session: session,
                      root: root,
                      commit: commit,
                      provider: provider,
                      safeError: safeError,
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Future<List<GitCommitSummary>> _loadHistory(
    GitHistoryProvider provider,
  ) async {
    final histories = await Future.wait([
      provider.history(root, limit: 100),
      provider.history(
        root,
        limit: 100,
        startRef: 'refs/remotes/origin/$branch',
      ),
    ]);
    final byHash = <String, GitCommitSummary>{};
    for (final history in histories) {
      for (final commit in history) {
        byHash[commit.hash] = commit;
      }
    }
    final result = byHash.values.toList()
      ..sort((left, right) {
        final leftDate =
            left.committedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final rightDate =
            right.committedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return rightDate.compareTo(leftDate);
      });
    return result;
  }

  static String _commitSubtitle(GitCommitSummary commit) {
    final date = commit.committedAt?.toLocal();
    final dateText = date == null
        ? ''
        : '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
              '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final author = commit.authorEmail.isEmpty
        ? commit.author
        : '${commit.author} <${commit.authorEmail}>';
    return '${commit.hash.substring(0, 7)} · $author${dateText.isEmpty ? '' : ' · $dateText'}';
  }
}

class _CommitDetailsDialog extends StatelessWidget {
  const _CommitDetailsDialog({
    required this.session,
    required this.root,
    required this.commit,
    required this.provider,
    required this.safeError,
  });

  final IdeSession session;
  final Uri root;
  final GitCommitSummary commit;
  final GitHistoryProvider provider;
  final String Function(Object error) safeError;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      commit.message.split('\n').first,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    content: SizedBox(
      width: 820,
      height: MediaQuery.sizeOf(context).height * .68,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            '${commit.hash}\nAuthor: ${commit.author}${commit.authorEmail.isEmpty ? '' : ' <${commit.authorEmail}>'}'
            '${commit.committer.isEmpty || commit.committer == commit.author ? '' : '\nCommitter: ${commit.committer}'}',
            style: const TextStyle(fontSize: 12),
          ),
          if (commit.message.contains('\n')) ...[
            const SizedBox(height: 8),
            SelectableText(commit.message.trim()),
          ],
          const Divider(),
          const Text(
            'Changed files',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          Expanded(
            child: FutureBuilder<List<GitCommitFileChange>>(
              future: provider.commitChanges(root, commit.hash),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return SelectableText(safeError(snapshot.error!));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final changes = snapshot.data!;
                if (changes.isEmpty) {
                  return const Center(child: Text('No file changes.'));
                }
                return ListView.builder(
                  itemCount: changes.length,
                  itemBuilder: (_, index) {
                    final change = changes[index];
                    return ListTile(
                      dense: true,
                      leading: _statusBadge(context, change.status),
                      title: Text(change.path, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.compare_arrows, size: 18),
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => _CommitFileDiffDialog(
                          session: session,
                          root: root,
                          commitHash: commit.hash,
                          change: change,
                          provider: provider,
                          safeError: safeError,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );

  Widget _statusBadge(BuildContext context, String status) {
    final color = switch (status) {
      'A' => Colors.green,
      'D' => Colors.red,
      _ => Theme.of(context).colorScheme.primary,
    };
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        status,
        style: TextStyle(color: color, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _CommitFileDiffDialog extends StatefulWidget {
  const _CommitFileDiffDialog({
    required this.session,
    required this.root,
    required this.commitHash,
    required this.change,
    required this.provider,
    required this.safeError,
  });

  final IdeSession session;
  final Uri root;
  final String commitHash;
  final GitCommitFileChange change;
  final GitHistoryProvider provider;
  final String Function(Object error) safeError;

  @override
  State<_CommitFileDiffDialog> createState() => _CommitFileDiffDialogState();
}

class _CommitFileDiffDialogState extends State<_CommitFileDiffDialog> {
  TextDiff? diff;
  String? error, note;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snapshot = await widget.provider.commitFileSnapshot(
        widget.root,
        widget.commitHash,
        widget.change.path,
      );
      if ((snapshot.before?.length ?? 0) + (snapshot.after?.length ?? 0) >
          2 * 1024 * 1024) {
        note = 'File is too large for inline comparison (2 MiB limit).';
      } else {
        try {
          diff = compareText(gitText(snapshot.before), gitText(snapshot.after));
        } on FormatException {
          note = 'Binary or non-UTF-8 file. Text comparison is unavailable.';
        }
      }
    } catch (value) {
      error = widget.safeError(value);
    } finally {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.session.theme;
    return AlertDialog(
      title: Text(
        '${widget.change.status} · ${widget.change.path}',
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 1000,
        height: MediaQuery.sizeOf(context).height * .68,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.commitHash.substring(0, 7)} · +${diff?.added ?? 0} / −${diff?.removed ?? 0}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (diff == null && error == null && note == null)
              const LinearProgressIndicator(),
            if (error != null)
              SelectableText(
                error!,
                style: TextStyle(color: Color(colors.color('error'))),
              ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(note!),
              ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: diff?.lines.length ?? 0,
                itemBuilder: (_, index) {
                  final line = diff!.lines[index];
                  final tint = line.kind == '+'
                      ? Colors.green
                      : line.kind == '-'
                      ? Colors.red
                      : Colors.transparent;
                  return ColoredBox(
                    color: tint.withValues(alpha: line.kind == ' ' ? 0 : .12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 2,
                        horizontal: 4,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _lineNumber(line.oldLine, colors),
                          _lineNumber(line.newLine, colors),
                          SizedBox(
                            width: 20,
                            child: Text(line.kind, textAlign: TextAlign.center),
                          ),
                          Expanded(
                            child: SelectableText(
                              line.text.isEmpty ? ' ' : line.text,
                              style: const TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontSize: 12,
                                fontFeatures: [
                                  FontFeature.disable('liga'),
                                  FontFeature.disable('calt'),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _lineNumber(int? value, dynamic colors) => SizedBox(
    width: 40,
    child: Text(
      '${value ?? ''}',
      textAlign: TextAlign.right,
      style: TextStyle(color: Color(colors.color('muted')), fontSize: 11),
    ),
  );
}
