import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app/ide_session.dart';
import '../app/git_file_changes.dart';
import '../core/filesystem/filesystem.dart';
import '../core/git/http_git_service.dart';
import '../platform/project_storage.dart';
import '../platform/reveal_path.dart';
import '../core/flutter/flutter_runner.dart';
import 'new_file_dialog.dart';
import 'git_diff.dart';

Future<void> showExplorerContextMenu(
  BuildContext context,
  IdeSession session,
  Uri uri,
  bool directory,
  Offset position,
) async {
  final roots =
      session.workspaceRoots
          .where((root) => uri.toString().startsWith(root.toString()))
          .toList()
        ..sort((a, b) => b.path.length.compareTo(a.path.length));
  if (roots.isEmpty) return;
  final root = roots.first;
  final relative = Uri.decodeComponent(uri.path.substring(root.path.length));
  final git = session.git;
  final editable =
      git is HttpGitService && !session.gitBusy && relative.isNotEmpty;
  final action = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(position.dx, position.dy, 0, 0),
      Offset.zero & MediaQuery.sizeOf(context),
    ),
    items: [
      if (!directory) const PopupMenuItem(value: 'open', child: Text('Open')),
      const PopupMenuItem(value: 'newFile', child: Text('New file…')),
      const PopupMenuItem(value: 'newFolder', child: Text('New folder…')),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'path', child: Text('Copy path')),
      const PopupMenuItem(value: 'relative', child: Text('Copy relative path')),
      if (supportsFlutterTools && uri.scheme == 'file')
        const PopupMenuItem(
          value: 'reveal',
          child: Text('Show in file manager'),
        ),
      if (!directory) ...[
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'rename',
          enabled: editable,
          child: const Text('Rename…'),
        ),
        PopupMenuItem(
          value: 'delete',
          enabled: editable,
          child: const Text('Delete…'),
        ),
        if (session.gitPath(uri) != null && session.workspaceHasGit)
          const PopupMenuItem(value: 'git', child: Text('Git…')),
      ],
    ],
  );
  if (!context.mounted || action == null) return;
  try {
    final filename = Uri.decodeComponent(
      uri.pathSegments.where((part) => part.isNotEmpty).last,
    );
    if (action == 'open') {
      await session.run('file.openEntry', FileEntry(uri, filename));
    }
    if (action == 'path' || action == 'relative') {
      await Clipboard.setData(
        ClipboardData(
          text: action == 'relative'
              ? relative
              : uri.scheme == 'file'
              ? uri.toFilePath()
              : uri.toString(),
        ),
      );
    }
    if (action == 'reveal') await revealInFileManager(uri.toFilePath());
    if (action == 'git' && context.mounted) {
      await showFileGitMenu(context, session, uri, position);
    }
    if ((action == 'newFile' || action == 'newFolder') && context.mounted) {
      final parent = directory ? uri : uri.resolve('.');
      await showDialog<void>(
        context: context,
        builder: (_) => NewFileDialog(
          session: session,
          folder: action == 'newFolder',
          initialDirectory: parent,
        ),
      );
    }
    if ((action == 'rename' || action == 'delete') &&
        git is HttpGitService &&
        context.mounted) {
      final store = git.openStore(root);
      await store.validateRegularFilePath(relative);
      if (!context.mounted) return;
      final doc = session.documents.documents
          .where((doc) => doc.uri == uri)
          .firstOrNull;
      if (action == 'delete') {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete file?'),
            content: Text(
              'Delete $filename?${doc?.dirty == true ? '\nUnsaved changes will also be lost.' : ''}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        await store.delete(relative);
        if (doc != null) await session.documents.close(doc);
      } else {
        final controller = TextEditingController(text: filename);
        String? validation;
        final route = DialogRoute<String>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              title: const Text('Rename file'),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'File name with extension',
                  errorText: validation,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final value = controller.text.trim();
                    final error = projectNameError(value);
                    if (error != null ||
                        value == '.git' ||
                        value == '.tamtoot') {
                      setState(() => validation = error ?? 'Reserved name');
                      return;
                    }
                    Navigator.pop(context, value);
                  },
                  child: const Text('Rename'),
                ),
              ],
            ),
          ),
        );
        final renamed = await Navigator.of(context).push(route);
        await route.completed;
        controller.dispose();
        if (renamed == null || renamed == filename) return;
        final targetUri = uri.resolveUri(Uri(path: renamed));
        final targetPath = Uri.decodeComponent(
          targetUri.path.substring(root.path.length),
        );
        await store.validateRegularFilePath(targetPath);
        if (await store.exists(targetPath)) {
          throw StateError('A file with this name already exists');
        }
        if (doc?.dirty == true && !await session.documents.save(doc!)) return;
        await store.writeBytes(targetPath, await store.readBytes(relative));
        await store.delete(relative);
        if (doc != null) {
          doc.uri = targetUri;
          doc.name = renamed;
        }
      }
      await session.refreshExplorer();
      session.changed();
    }
  } catch (error) {
    session.log('File action failed: $error', error: true);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('File action failed: $error')));
    }
  }
}
