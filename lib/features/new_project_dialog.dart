import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../app/ide_session.dart';
import '../platform/clone_paths.dart';
import '../platform/project_storage.dart';
import '../platform/security_scoped_roots.dart';
import '../platform/workspace_roots.dart';

class NewProjectDialog extends StatefulWidget {
  const NewProjectDialog({super.key, required this.session});
  final IdeSession session;

  @override
  State<NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<NewProjectDialog> {
  final _name = TextEditingController();
  String? _parent;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (usesManagedProjectStorage) unawaited(_loadParent());
  }

  Future<void> _loadParent() async {
    try {
      final parent = await defaultCloneParentPath();
      if (mounted) setState(() => _parent = parent);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _browse() async {
    try {
      await _pickParent();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _pickParent() async {
    if (!widget.session.documents.dialogs.supportsDirectories) {
      if (mounted) setState(() => _error = 'Folder selection is unavailable');
      return;
    }
    final parent = await widget.session.documents.dialogs.openWorkspace();
    if (parent != null && mounted) {
      setState(() {
        _parent = parent.toFilePath();
        _error = null;
      });
    }
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    final error = projectNameError(name);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      Uri root;
      if (webDirectoryPickerSupported) {
        final picked = await pickCloneDestination(folderName: name);
        if (picked == null) return;
        final store = WorkspaceRoots.storeFor(picked)!;
        if ((await store.listFiles('')).isNotEmpty) {
          throw StateError(
            '“$name” already contains files. Choose another name.',
          );
        }
        await store.writeText(
          '.tamtoot/project.json',
          jsonEncode({
            'schemaVersion': 1,
            'name': name,
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          }),
        );
        root = picked;
      } else {
        if (!usesManagedProjectStorage && _parent == null) await _browse();
        if (!mounted) return;
        final parent = _parent;
        if (parent == null) {
          throw StateError(
            usesManagedProjectStorage
                ? 'App documents folder is unavailable'
                : 'Choose a parent folder on disk using Browse',
          );
        }
        root = await createProjectDirectory(parent, name);
        await SecurityScopedRoots.rememberPickedFolder(root);
      }
      await widget.session.openWorkspaceFolder(root);
      widget.session.log('Created project $name');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('New project'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Project name'),
              ),
              const SizedBox(height: 12),
              if (usesManagedProjectStorage)
                const Text('Saved in TamtootRepos on this device')
              else if (webDirectoryPickerSupported)
                const Text(
                  'Choose a parent folder on disk when you press Create.',
                )
              else
                InputDecorator(
                  decoration: const InputDecoration(labelText: 'Parent folder'),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _parent ?? 'Choose a folder on disk…',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: _busy ? null : _browse,
                        child: const Text('Browse'),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                'Creates an empty project folder. Existing folders are kept intact.',
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: const Text('Create'),
        ),
      ],
    ),
  );
}
