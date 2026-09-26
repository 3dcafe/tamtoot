import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app/ide_session.dart';
import '../app/session_commands.dart';
import '../core/git/git_service.dart';
import '../platform/clone_paths.dart';

class ShellActions implements PresentationActions {
  ShellActions(this.context, this.session);
  final BuildContext Function() context;
  final IdeSession session;
  @override
  Future<String?> readClipboard() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  @override
  Future<void> writeClipboard(String value) =>
      Clipboard.setData(ClipboardData(text: value));
  @override
  Future<bool> confirmDiscard(String name) async =>
      await showDialog<bool>(
        context: context(),
        builder: (ctx) => AlertDialog(
          title: const Text('Unsaved changes'),
          content: Text('Close $name and discard its changes?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      ) ??
      false;
  @override
  Future<void> showCommands() async {
    final result = await showDialog<String>(
      context: context(),
      builder: (ctx) => CommandPalette(session: session),
    );
    if (result != null) await session.run(result);
  }

  @override
  Future<void> showSettings() => showDialog<void>(
    context: context(),
    builder: (ctx) => SettingsDialog(session: session),
  );
  @override
  Future<void> showExtensions() => showDialog<void>(
    context: context(),
    builder: (ctx) => LanguageDialog(session: session),
  );

  @override
  Future<void> showCloneRepository() => showDialog<void>(
    context: context(),
    barrierDismissible: false,
    builder: (ctx) => CloneRepositoryDialog(session: session),
  );
}

class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key, required this.session});
  final IdeSession session;
  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final commands = widget.session.commands.commands
        .where(
          (c) =>
              !{
                'editor.insert',
                'editor.select',
                'settings.set',
                'layout.resize',
                'layout.activate',
                'document.activate',
                'file.openEntry',
                'keybindings.set',
                'extensions.install',
                'workspace.browse',
                'editor.findNext',
                'editor.replaceAll',
              }.contains(c.id) &&
              '${c.title} ${c.id}'.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    return AlertDialog(
      title: const Text('Commands'),
      content: SizedBox(
        width: 560,
        height: 410,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Type a command…',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => query = value),
              onSubmitted: (_) {
                if (commands.isNotEmpty) {
                  Navigator.pop(context, commands.first.id);
                }
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: commands.length,
                itemBuilder: (ctx, index) {
                  final c = commands[index];
                  return ListTile(
                    dense: true,
                    enabled: widget.session.commands.isEnabled(c.id),
                    title: Text(c.title),
                    subtitle: Text(c.id),
                    onTap: () => Navigator.pop(context, c.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.session});
  final IdeSession session;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final TextEditingController keys = TextEditingController(
    text: const JsonEncoder.withIndent(
      '  ',
    ).convert(widget.session.keys.toJson()),
  );
  late final TextEditingController font = TextEditingController(
    text: widget.session.settings.get('fontFamily') as String,
  );
  @override
  void dispose() {
    keys.dispose();
    font.dispose();
    super.dispose();
  }

  Future<void> set(String key, Object value) async {
    await widget.session.run('settings.set', MapEntry(key, value));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.session.settings;
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text('Font size'),
                  Expanded(
                    child: Slider(
                      value: settings.fontSize,
                      min: 8,
                      max: 32,
                      divisions: 24,
                      label: '${settings.fontSize.round()}',
                      onChanged: (v) => set('fontSize', v),
                    ),
                  ),
                  Text('${settings.fontSize.round()}'),
                ],
              ),
              TextField(
                controller: font,
                decoration: const InputDecoration(labelText: 'Font family'),
                onSubmitted: (v) {
                  if (v.trim().isNotEmpty) set('fontFamily', v.trim());
                },
              ),
              SwitchListTile(
                title: const Text('Insert spaces'),
                value: settings.get('insertSpaces') as bool,
                onChanged: (v) => set('insertSpaces', v),
              ),
              SwitchListTile(
                title: const Text('Read-only editor'),
                value: settings.get('readOnly') as bool,
                onChanged: (v) => set('readOnly', v),
              ),
              Row(
                children: [
                  const Text('Tab size'),
                  const SizedBox(width: 16),
                  DropdownButton<int>(
                    value: settings.get('tabSize') as int,
                    items: [
                      for (final n in [1, 2, 3, 4, 5, 6, 7, 8])
                        DropdownMenuItem(value: n, child: Text('$n')),
                    ],
                    onChanged: (v) {
                      if (v != null) set('tabSize', v);
                    },
                  ),
                ],
              ),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Keybindings · schema v1'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: keys,
                maxLines: 8,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 8),
              const Text(
                'Modifiers: ctrl, meta, alt, shift (in that order). Omitted bindings use defaults.',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () async {
            await set(
              'fontFamily',
              font.text.trim().isEmpty ? 'monospace' : font.text.trim(),
            );
            await widget.session.run('keybindings.set', keys.text);
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class LanguageDialog extends StatefulWidget {
  const LanguageDialog({super.key, required this.session});
  final IdeSession session;
  @override
  State<LanguageDialog> createState() => _LanguageDialogState();
}

class _LanguageDialogState extends State<LanguageDialog> {
  final manifest = TextEditingController(),
      syntax = TextEditingController(),
      snippets = TextEditingController();
  String? error;
  @override
  void dispose() {
    manifest.dispose();
    syntax.dispose();
    snippets.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Language packages'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final language in widget.session.languages.languages)
              ListTile(
                leading: const Icon(Icons.code),
                title: Text(language.name),
                subtitle: Text(
                  '${language.extensions.join(', ')} · ${language.version} · declarative',
                ),
              ),
            const Text(
              'Install a declarative package without rebuilding. Paste its versioned JSON files below.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: manifest,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'language.json'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: syntax,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'syntax.json'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: snippets,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'snippets.json (optional)',
              ),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 12),
            const Text(
              'Executable plugins and LSP providers are reserved for a later milestone.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      FilledButton(
        onPressed: () async {
          try {
            await widget.session.commands.execute('extensions.install', [
              manifest.text,
              syntax.text,
              snippets.text,
            ]);
            if (mounted) setState(() => error = null);
          } catch (e) {
            widget.session.log('Package: $e', error: true);
            setState(() => error = '$e');
          }
        },
        child: const Text('Install package'),
      ),
    ],
  );
}

class CloneRepositoryDialog extends StatefulWidget {
  const CloneRepositoryDialog({super.key, required this.session});
  final IdeSession session;
  @override
  State<CloneRepositoryDialog> createState() => _CloneRepositoryDialogState();
}

class _CloneRepositoryDialogState extends State<CloneRepositoryDialog> {
  final url = TextEditingController();
  final folder = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  final token = TextEditingController();
  final branch = TextEditingController();
  bool busy = false;
  String? error;
  String? destinationPath;
  Uri? selectedWebRoot;
  bool get canBrowse =>
      widget.session.documents.dialogs.supportsDirectories ||
      webDirectoryPickerSupported;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      url.text = 'https://gitverse.ru/latin/tamtoot.git';
      folder.text = 'tamtoot';
    }
    url.addListener(_suggestFolder);
    unawaited(_prepareDefaultDestination());
  }

  Future<void> _prepareDefaultDestination() async {
    final path = await defaultCloneParentPath();
    if (!mounted) return;
    setState(() => destinationPath = path);
  }

  void _suggestFolder() {
    if (folder.text.trim().isNotEmpty) return;
    final name = _repoNameFromUrl(url.text);
    if (name != null) setState(() => folder.text = name);
  }

  String? _repoNameFromUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final uri = Uri.parse(trimmed);
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) return null;
      var name = segments.last;
      if (name.endsWith('.git')) name = name.substring(0, name.length - 4);
      return name.isEmpty ? null : name;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    url.dispose();
    folder.dispose();
    username.dispose();
    password.dispose();
    token.dispose();
    branch.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    if (widget.session.documents.dialogs.supportsDirectories) {
      final picked = await widget.session.documents.dialogs.openWorkspace();
      if (picked == null || !mounted) return;
      setState(() {
        destinationPath = picked.toFilePath();
        selectedWebRoot = null;
      });
      return;
    }
    final name = folder.text.trim().isEmpty
        ? _repoNameFromUrl(url.text)
        : folder.text.trim();
    final picked = await pickCloneDestination(folderName: name);
    if (picked == null || !mounted) return;
    setState(() {
      selectedWebRoot = picked;
      destinationPath = picked.toString();
      if (name != null && name.isNotEmpty) folder.text = name;
    });
  }

  Future<void> _clone() async {
    final remoteText = url.text.trim();
    if (remoteText.isEmpty) {
      setState(() => error = 'Enter a repository URL');
      return;
    }
    Uri remote;
    try {
      remote = Uri.parse(remoteText);
      if (remote.scheme != 'https' && remote.scheme != 'http') {
        setState(() => error = 'Only http(s) URLs are supported');
        return;
      }
    } catch (_) {
      setState(() => error = 'Invalid URL');
      return;
    }

    final name = folder.text.trim().isEmpty
        ? _repoNameFromUrl(remoteText)
        : folder.text.trim();
    if (name == null || name.isEmpty) {
      setState(() => error = 'Enter a folder name');
      return;
    }

    GitCredentials? credentials;
    final tokenValue = token.text.trim();
    final userValue = username.text.trim();
    final passValue = password.text;
    if (tokenValue.isNotEmpty) {
      credentials = GitCredentials(
        username: userValue.isEmpty ? 'git' : userValue,
        token: tokenValue,
      );
    } else if (userValue.isNotEmpty || passValue.isNotEmpty) {
      credentials = GitCredentials(username: userValue, password: passValue);
    }

    setState(() {
      busy = true;
      error = null;
    });
    widget.session.log('Cloning $remoteText…');
    try {
      Uri targetUri;
      if (webDirectoryPickerSupported) {
        var webRoot = selectedWebRoot;
        webRoot ??= await pickCloneDestination(folderName: name);
        if (webRoot == null) {
          setState(() {
            busy = false;
            error = 'Choose a local folder on your computer to save the clone';
          });
          return;
        }
        selectedWebRoot = webRoot;
        targetUri = webRoot;
      } else {
        final parent = destinationPath;
        if (parent == null || parent.isEmpty) {
          setState(() {
            busy = false;
            error = 'Choose a destination folder';
          });
          return;
        }
        final targetPath = joinClonePath(parent, name);
        if (await cloneTargetBusy(targetPath)) {
          setState(() {
            busy = false;
            error = 'Folder already exists and is not empty';
          });
          return;
        }
        await ensureCloneDirectory(targetPath);
        targetUri = cloneDirectoryUri(targetPath);
      }

      final result = await widget.session.git.clone(
        remote,
        targetUri,
        credentials: credentials,
        branch: branch.text.trim().isEmpty ? null : branch.text.trim(),
      );
      if (!result.ok) {
        setState(() {
          busy = false;
          error = result.message;
        });
        widget.session.log('Clone failed: ${result.message}', error: true);
        return;
      }
      await widget.session.openWorkspaceFolder(targetUri);
      widget.session.log('Cloned and opened $targetUri');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        busy = false;
        error = '$e';
      });
      widget.session.log('Clone failed: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Clone repository'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: url,
                enabled: !busy,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Repository URL',
                  hintText: 'https://gitverse.ru/user/repo.git',
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: folder,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Folder name',
                  hintText: 'Derived from URL if empty',
                ),
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Parent folder',
                  border: OutlineInputBorder(),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        selectedWebRoot?.pathSegments
                                .where((s) => s.isNotEmpty)
                                .lastOrNull ??
                            destinationPath ??
                            (webDirectoryPickerSupported
                                ? 'Press Browse to choose a folder on disk…'
                                : 'Resolving app documents…'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (canBrowse)
                      TextButton(
                        onPressed: busy ? null : _browse,
                        child: const Text('Browse'),
                      ),
                  ],
                ),
              ),
              if (!canBrowse)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    webDirectoryPickerSupported
                        ? 'Press Browse and pick a real folder on your computer. Files are saved there (not in memory).'
                        : 'On this device clones go into the app documents folder.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (webDirectoryPickerSupported)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Note: some git hosts block browser requests (CORS). If clone fails, try the desktop/Android app.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                'Authentication (optional)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: token,
                enabled: !busy,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Access token',
                  hintText: 'Preferred for HTTPS remotes',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: username,
                enabled: !busy,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: password,
                enabled: !busy,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  hintText: 'Used if token is empty',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: branch,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Branch (optional)',
                  hintText: 'Default remote branch if empty',
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(
                  'Downloading over HTTPS…',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
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
          onPressed: busy ? null : _clone,
          child: const Text('Clone'),
        ),
      ],
    );
  }
}
