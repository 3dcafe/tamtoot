import 'package:flutter/material.dart';
import '../app/ide_session.dart';
import '../core/filesystem/filesystem.dart';
import '../core/git/http_git_service.dart';
import '../core/projects/project_detection.dart';
import '../languages/language_registry.dart';
import '../platform/project_storage.dart';

class NewFileDialog extends StatefulWidget {
  const NewFileDialog({
    super.key,
    required this.session,
    this.folder = false,
    this.initialDirectory,
  });
  final IdeSession session;
  final bool folder;
  final Uri? initialDirectory;
  @override
  State<NewFileDialog> createState() => _NewFileDialogState();
}

class _NewFileDialogState extends State<NewFileDialog> {
  late Uri root = widget.session.workspaceRoots.first;
  final name = TextEditingController(text: 'NewFile');
  final directory = TextEditingController();
  final extension = TextEditingController();
  late String languageId = _defaultLanguage();
  String template = '';
  String? error;
  bool busy = false;
  LanguageDefinition? get language => widget.session.languages.all
      .where((lang) => lang.id == languageId)
      .firstOrNull;
  Map<String, dynamic> get templates => language?.fileTemplates ?? {};
  String _defaultLanguage() {
    final target = widget.session.launchTarget;
    if (target?.kind == ProjectKind.dotnet) return 'csharp';
    if (target?.kind == ProjectKind.flutter) return 'dart';
    final active = widget.session.documents.active;
    return active == null
        ? ''
        : widget.session.languages.forPath(active.name)?.id ?? '';
  }

  @override
  void initState() {
    super.initState();
    final target = widget.session.launchTarget;
    if (target != null) {
      root =
          widget.session.workspaceRoots
              .where((r) => target.root.toString().startsWith(r.toString()))
              .firstOrNull ??
          root;
      if (target.root.toString().startsWith(root.toString())) {
        directory.text = Uri.decodeComponent(
          target.root.path.substring(root.path.length),
        ).replaceAll(RegExp(r'/+$'), '');
      }
    }
    final destination = widget.initialDirectory;
    if (destination != null) {
      root =
          widget.session.workspaceRoots
              .where((r) => destination.toString().startsWith(r.toString()))
              .firstOrNull ??
          root;
      if (destination.path.startsWith(root.path)) {
        directory.text = Uri.decodeComponent(
          destination.path.substring(root.path.length),
        ).replaceAll(RegExp(r'/+$'), '');
      }
    }
    if (widget.folder) name.text = 'NewFolder';
    _selectLanguage(languageId);
    if (target == null && languageId.isEmpty) _inferLanguage();
  }

  int _inference = 0;
  Future<void> _inferLanguage() async {
    final revision = ++_inference;
    final targets = await detectProjects(widget.session.documents.files, root);
    if (!mounted || revision != _inference || busy) return;
    final kind = targets.firstOrNull?.kind;
    if (kind != null) {
      setState(
        () => _selectLanguage(kind == ProjectKind.dotnet ? 'csharp' : 'dart'),
      );
    }
  }

  void _selectLanguage(String id) {
    languageId = id;
    template = templates.keys.firstOrNull ?? '';
    extension.text =
        templates[template]?['extension'] as String? ??
        language?.extensions.firstOrNull ??
        '';
  }

  String _content() {
    final body = templates[template]?['body'] as String? ?? '';
    final identifier = name.text.trim().split('.').first;
    if (body.contains('{{name}}') &&
        (languageId == 'csharp' || languageId == 'dart') &&
        !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(identifier)) {
      throw ArgumentError('Use a valid class name, or choose Empty file');
    }
    return body.replaceAll('{{name}}', identifier);
  }

  Future<void> _create() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final ext = extension.text.trim();
      final filename =
          '${name.text.trim()}${widget.folder || ext.isEmpty
              ? ''
              : ext.startsWith('.')
              ? ext
              : '.$ext'}';
      final invalid = projectNameError(filename);
      if (invalid != null) throw ArgumentError(invalid);
      final parent = directory.text.trim().replaceAll('\\', '/');
      final components = parent.isEmpty ? <String>[] : parent.split('/');
      if (components.any(
        (part) =>
            projectNameError(part) != null ||
            part == '.git' ||
            part == '.tamtoot',
      )) {
        throw ArgumentError(
          'Use a relative project folder path without .. or protected directories',
        );
      }
      if (filename == '.git' || filename == '.tamtoot') {
        throw ArgumentError('This name is reserved');
      }
      final path = [...components, filename].join('/');
      final git = widget.session.git;
      if (git is! HttpGitService) {
        throw UnsupportedError(
          'This filesystem does not support project creation',
        );
      }
      final store = git.openStore(root);
      await store.validateRegularFilePath(path);
      if (await store.exists(path)) {
        throw StateError('A file or folder with this name already exists');
      }
      if (parent.isNotEmpty && !await store.exists(parent)) {
        throw StateError('Choose an existing destination folder');
      }
      if (widget.folder) {
        await store.createDirectory(path);
      } else {
        final text = _content();
        await store.writeText(path, text);
        final uri = root.resolveUri(Uri(path: path));
        await widget.session.documents.open(FileEntry(uri, filename));
      }
      await widget.session.refreshExplorer();
      widget.session.changed();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    name.dispose();
    directory.dispose();
    extension.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.folder ? 'New folder' : 'New project file'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<Uri>(
              initialValue: root,
              decoration: const InputDecoration(labelText: 'Workspace'),
              items: [
                for (final item in widget.session.workspaceRoots)
                  DropdownMenuItem(
                    value: item,
                    child: Text(
                      widget.session.workspaceRootAliases[item] ??
                          item.toString(),
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() {
                          root = value;
                          directory.clear();
                          _inferLanguage();
                        });
                      }
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: directory,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'Destination folder',
                hintText: 'Relative path; empty means workspace root',
              ),
            ),
            const SizedBox(height: 12),
            if (!widget.folder) ...[
              DropdownButtonFormField<String>(
                key: ValueKey('language-$languageId'),
                initialValue: languageId,
                decoration: const InputDecoration(labelText: 'Language'),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('Plain text / custom'),
                  ),
                  for (final lang in widget.session.languages.all)
                    DropdownMenuItem(value: lang.id, child: Text(lang.name)),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() => _selectLanguage(value ?? '')),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey(languageId),
                initialValue: template,
                decoration: const InputDecoration(labelText: 'Template'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Empty file')),
                  for (final entry in templates.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value['name'] as String),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() {
                        template = value ?? '';
                        if (template.isNotEmpty) {
                          extension.text =
                              templates[template]['extension'] as String;
                        }
                      }),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: name,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: widget.folder
                    ? 'Folder name'
                    : 'File name without extension',
              ),
            ),
            if (!widget.folder) ...[
              const SizedBox(height: 12),
              TextField(
                controller: extension,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Extension (editable)',
                  hintText: '.cs, .dart, .txt…',
                ),
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: busy ? null : _create,
        child: Text(busy ? 'Creating…' : 'Create'),
      ),
    ],
  );
}
