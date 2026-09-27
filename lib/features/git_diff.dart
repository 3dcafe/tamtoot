import 'package:flutter/material.dart';
import '../app/ide_session.dart';
import '../app/git_file_changes.dart';
import '../core/git/git_service.dart';
import '../core/git/text_diff.dart';

Future<void> showFileChanges(
  BuildContext context,
  IdeSession session,
  Uri uri,
) => showDialog<void>(
  context: context,
  builder: (_) => GitDiffDialog(session: session, uri: uri),
);

Future<bool> discardFileWithConfirmation(
  BuildContext context,
  IdeSession session,
  Uri uri, {
  FileChangeReview? review,
}) async {
  try {
    final value = review ?? await session.reviewFile(uri);
    if (!context.mounted) return false;
    final untracked = value.snapshot.original == null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(untracked ? 'Delete untracked file?' : 'Discard changes?'),
        content: Text(
          untracked
              ? '${value.snapshot.path}\n\nThis file is not in HEAD. It will be deleted, including any unsaved editor changes.'
              : '${value.snapshot.path}\n\nRestore the last committed version (HEAD)? Saved and unsaved changes in this file will be discarded.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(untracked ? 'Delete file' : 'Discard changes'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    await session.discardReviewedFile(value);
    return true;
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
    return false;
  }
}

Future<void> showFileGitMenu(
  BuildContext context,
  IdeSession session,
  Uri uri,
  Offset position,
) async {
  if (!session.workspaceHasGit ||
      session.git is! GitFileChangesProvider ||
      session.gitPath(uri) == null) {
    return;
  }
  final selected = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(position.dx, position.dy, 0, 0),
      Offset.zero & MediaQuery.sizeOf(context),
    ),
    items: [
      const PopupMenuItem(value: 'compare', child: Text('Compare with HEAD')),
      PopupMenuItem(
        value: 'discard',
        enabled: !session.gitBusy,
        child: const Text('Discard changes…'),
      ),
    ],
  );
  if (!context.mounted) return;
  if (selected == 'compare') await showFileChanges(context, session, uri);
  if (!context.mounted) return;
  if (selected == 'discard') {
    await discardFileWithConfirmation(context, session, uri);
  }
}

class GitDiffDialog extends StatefulWidget {
  const GitDiffDialog({super.key, required this.session, required this.uri});
  final IdeSession session;
  final Uri uri;
  @override
  State<GitDiffDialog> createState() => _GitDiffDialogState();
}

class _GitDiffDialogState extends State<GitDiffDialog> {
  FileChangeReview? review;
  TextDiff? diff;
  String? error, note;
  bool busy = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      busy = true;
      error = null;
      note = null;
      review = null;
      diff = null;
    });
    try {
      final value = await widget.session.reviewFile(widget.uri);
      if (!mounted) return;
      review = value;
      if ((value.snapshot.original?.length ?? 0) +
              (value.snapshot.working?.length ?? 0) +
              (value.unsavedText?.length ?? 0) >
          2 * 1024 * 1024) {
        note = 'File is too large for inline comparison (2 MiB limit).';
      } else {
        try {
          final before = gitText(value.snapshot.original),
              after = value.unsavedText ?? gitText(value.snapshot.working);
          diff = compareText(before, after);
          if (diff!.added == 0 && diff!.removed == 0) {
            note = before == after
                ? 'No text changes relative to HEAD.'
                : 'Only line endings or empty-file presence differ.';
          }
        } on FormatException {
          note = 'Binary or non-UTF-8 file. Text comparison is unavailable.';
        }
      }
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _discard() async {
    setState(() => busy = true);
    final discarded = await discardFileWithConfirmation(
      context,
      widget.session,
      widget.uri,
      review: review,
    );
    if (!mounted) return;
    if (discarded) {
      Navigator.pop(context);
    } else {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.session.theme;
    final value = review;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Text(
          'Compare · ${widget.uri.pathSegments.last}',
          overflow: TextOverflow.ellipsis,
        ),
        content: SizedBox(
          width: 1000,
          height: MediaQuery.sizeOf(context).height * .65,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'HEAD → ${value?.unsavedText != null ? "Editor (unsaved)" : "Working copy"}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (value != null)
                Text(
                  '${value.snapshot.original == null ? "New file · " : ""}${value.snapshot.working == null && value.unsavedText == null ? "Deleted file · " : ""}+${diff?.added ?? 0} / −${diff?.removed ?? 0}',
                ),
              if (busy && review == null) const LinearProgressIndicator(),
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
              if (diff?.coarse == true)
                const Text('Large changed block shown as a full replacement.'),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  itemCount: diff?.lines.length ?? 0,
                  itemBuilder: (_, i) {
                    final line = diff!.lines[i];
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
                            SizedBox(
                              width: 40,
                              child: Text(
                                '${line.oldLine ?? ""}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  color: Color(colors.color('muted')),
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 40,
                              child: Text(
                                '${line.newLine ?? ""}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  color: Color(colors.color('muted')),
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 20,
                              child: Text(
                                line.kind,
                                textAlign: TextAlign.center,
                              ),
                            ),
                            Expanded(
                              child: SelectableText(
                                line.text.isEmpty ? ' ' : line.text,
                                style: const TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 12,
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
            onPressed: busy ? null : _load,
            child: const Text('Refresh'),
          ),
          TextButton(
            onPressed: busy || review == null || widget.session.gitBusy
                ? null
                : _discard,
            child: const Text('Discard changes…'),
          ),
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
