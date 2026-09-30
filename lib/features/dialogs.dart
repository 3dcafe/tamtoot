import 'model_profiles_dialog.dart';
import 'project_search_dialog.dart';
import 'agent_dialog.dart';
import 'mcp_dialog.dart';
import 'kanban_dialog.dart';
import 'dart:async';
import 'git_changes_dialog.dart';
import 'http_requests_dialog.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../app/ide_session.dart';
import '../app/session_commands.dart';
import '../core/git/git_service.dart';
import '../platform/clone_paths.dart';

class ShellActions implements PresentationActions {
  ShellActions(this.context, this.session);
  final BuildContext Function() context;
  final IdeSession session;

  Future<bool> _ensureProject({bool requireGit = false}) async {
    if (session.workspaceRoot != null &&
        (!requireGit || session.workspaceHasGit)) {
      return true;
    }
    final open = await showDialog<bool>(
      context: context(),
      builder: (ctx) => AlertDialog(
        title: Text(requireGit ? 'Open a Git project' : 'Open a project'),
        content: Text(
          requireGit
              ? 'This tool stores its data with the project and requires a Git repository.'
              : 'This tool stores its data in the project folder. Open or clone a project first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.folder_open),
            label: const Text('Open project'),
          ),
        ],
      ),
    );
    if (open != true) return false;
    await showOpenProject();
    return session.workspaceRoot != null &&
        (!requireGit || session.workspaceHasGit);
  }
  @override
  Future<void> showProjectSearch() => showDialog<void>(
    context: context(),
    builder: (_) => ProjectSearchDialog(session: session),
  );
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
  Future<void> showPrivacyPolicy() => showDialog<void>(
    context: context(),
    builder: (ctx) {
      const url = 'https://3dcafe.github.io/tamtoot/privacy/';
      final android =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
      return AlertDialog(
        title: const Text('Privacy Policy'),
        content: const SelectableText(
          'Tamtoot does not use advertising, analytics, telemetry, or developer-operated servers to collect user data.\n\n$url',
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(const ClipboardData(text: url)),
            child: const Text('Copy link'),
          ),
          if (android)
            FilledButton(
              onPressed: () async {
                await const MethodChannel(
                  'dev.tamtoot/documents',
                ).invokeMethod<bool>('openUrl', {'url': url});
              },
              child: const Text('Open in browser'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
  @override
  Future<void> showAgent() async {
    if (!await _ensureProject()) return;
    await showDialog<void>(
      context: context(),
      barrierDismissible: false,
      builder: (_) => AgentDialog(session: session),
    );
  }
  @override
  Future<void> showKanban() async {
    if (!await _ensureProject(requireGit: true)) return;
    await showDialog<void>(
      context: context(),
      barrierDismissible: false,
      builder: (_) => KanbanDialog(session: session),
    );
  }
  @override
  Future<void> showLanguagePackageInstaller() => showDialog<void>(
    context: context(),
    builder: (ctx) => LanguagePackageInstallerDialog(session: session),
  );

  @override
  Future<void> showGitChanges() => showDialog<void>(
    context: context(),
    barrierDismissible: false,
    builder: (_) => GitChangesDialog(session: session),
  );

  @override
  Future<void> showHttpRequests() async {
    if (!await _ensureProject()) return;
    await showDialog<void>(
      context: context(),
      barrierDismissible: false,
      builder: (_) => HttpRequestsDialog(session: session),
    );
  }

  @override
  Future<void> showCloneRepository() => showDialog<void>(
    context: context(),
    barrierDismissible: false,
    builder: (ctx) => CloneRepositoryDialog(session: session),
  );

  @override
  Future<void> showOpenProject() => showDialog<void>(
    context: context(),
    builder: (ctx) => OpenProjectDialog(session: session),
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
                'workspace.toggleFolder',
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
                  const Text('IDE theme'),
                  const SizedBox(width: 16),
                  DropdownButton<String>(
                    value: widget.session.theme.id,
                    items: [
                      for (final theme in widget.session.themes.values)
                        DropdownMenuItem(
                          value: theme.id,
                          child: Text(theme.name),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) set('theme', value);
                    },
                  ),
                ],
              ),
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
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.smart_toy_outlined),
                title: const Text('Model profiles and prompts'),
                subtitle: const Text(
                  'Per-model prompts and project instructions',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => ModelProfilesDialog(session: widget.session),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.extension_outlined),
                title: const Text('MCP servers'),
                subtitle: const Text('External tools for project agents'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => McpDialog(session: widget.session),
                ),
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

class LanguagePackageInstallerDialog extends StatefulWidget {
  const LanguagePackageInstallerDialog({super.key, required this.session});
  final IdeSession session;
  @override
  State<LanguagePackageInstallerDialog> createState() =>
      _LanguagePackageInstallerDialogState();
}

class _LanguagePackageInstallerDialogState
    extends State<LanguagePackageInstallerDialog> {
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
    title: const Text('Install language package'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
  bool folderEdited = false;
  String? error;
  String? destinationPath;
  Uri? selectedWebRoot;
  Uri? existingWorkspace;
  bool get canBrowse =>
      widget.session.documents.dialogs.supportsDirectories ||
      webDirectoryPickerSupported;

  /// iPhone/Android: clones go into app documents — no raw path UI.
  bool get managedDestination => !canBrowse;

  @override
  void initState() {
    super.initState();
    url.addListener(_suggestFolder);
    unawaited(_prepareDefaultDestination());
  }

  Future<void> _prepareDefaultDestination() async {
    final path = await defaultCloneParentPath();
    if (!mounted) return;
    setState(() => destinationPath = path);
    await _ensureUniqueFolderName();
  }

  Future<void> _ensureUniqueFolderName() async {
    final parent = destinationPath;
    if (parent == null || parent.isEmpty || webDirectoryPickerSupported) return;
    final preferred = folder.text.trim().isEmpty
        ? (_repoNameFromUrl(url.text) ?? 'repo')
        : folder.text.trim();
    final unique = await uniqueCloneFolderName(parent, preferred);
    if (!mounted) return;
    if (unique != preferred) {
      setState(() {
        folder.text = unique;
        folderEdited = true;
      });
    }
  }

  void _suggestFolder() {
    if (folderEdited) return;
    final name = _repoNameFromUrl(url.text);
    if (name != null && folder.text != name) {
      setState(() => folder.text = name);
      unawaited(_ensureUniqueFolderName());
    }
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

  Future<void> _openExisting() async {
    final uri = existingWorkspace;
    if (uri == null) return;
    await widget.session.openWorkspaceFolder(uri);
    widget.session.log('Opened existing project $uri');
    if (mounted) Navigator.pop(context);
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
      setState(() => error = 'Enter a project name');
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
      existingWorkspace = null;
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
            error = 'App documents folder is unavailable';
          });
          return;
        }
        final targetPath = joinClonePath(parent, name);
        if (await cloneTargetBusy(targetPath)) {
          if (await looksLikeManagedWorkspace(targetPath)) {
            setState(() {
              busy = false;
              existingWorkspace = cloneDirectoryUri(targetPath);
              error =
                  '“$name” is already cloned on this device. Open it, or change the project name.';
            });
            return;
          }
          final unique = await uniqueCloneFolderName(parent, name);
          setState(() {
            busy = false;
            folder.text = unique;
            folderEdited = true;
            error =
                '“$name” already exists. Suggested name: $unique — press Clone again.';
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
      widget.session.log('Cloned and opened ${folder.text.trim()}');
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
                onChanged: (_) {
                  folderEdited = true;
                  if (existingWorkspace != null) {
                    setState(() {
                      existingWorkspace = null;
                      error = null;
                    });
                  }
                },
                decoration: InputDecoration(
                  labelText: managedDestination
                      ? 'Project name'
                      : 'Folder name',
                  hintText: 'Derived from URL if empty',
                  helperText: managedDestination
                      ? 'Saved in TamtootRepos on this device'
                      : null,
                ),
              ),
              if (!managedDestination) ...[
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
              ],
              if (webDirectoryPickerSupported)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Press Browse and pick a real folder on your computer. '
                    'Some git hosts block browser requests (CORS).',
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
        if (existingWorkspace != null)
          TextButton(
            onPressed: busy ? null : _openExisting,
            child: const Text('Open existing'),
          ),
        FilledButton(
          onPressed: busy ? null : _clone,
          child: const Text('Clone'),
        ),
      ],
    );
  }
}

class OpenProjectDialog extends StatefulWidget {
  const OpenProjectDialog({super.key, required this.session});
  final IdeSession session;
  @override
  State<OpenProjectDialog> createState() => _OpenProjectDialogState();
}

class _OpenProjectDialogState extends State<OpenProjectDialog> {
  late Future<List<ClonedProjectRef>> _projects;

  @override
  void initState() {
    super.initState();
    _projects = _load();
  }

  Future<List<ClonedProjectRef>> _load() async {
    final byKey = <String, ClonedProjectRef>{};

    String keyFor(Uri uri) {
      final path = uri.hasScheme && uri.scheme == 'file'
          ? uri.toFilePath()
          : uri.toString();
      return path.endsWith('/') || path.endsWith('\\')
          ? path.substring(0, path.length - 1)
          : path;
    }

    for (final raw in widget.session.recentWorkspaces) {
      try {
        final uri = Uri.parse(raw);
        final name =
            uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ??
            uri.toString();
        byKey[keyFor(uri)] = ClonedProjectRef(name: name, uri: uri);
      } catch (_) {}
    }

    for (final project in await listClonedProjects()) {
      byKey[keyFor(project.uri)] = project;
    }

    final list = byKey.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  Future<void> _open(ClonedProjectRef project) async {
    await widget.session.openWorkspaceFolder(project.uri);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Open project'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: FutureBuilder<List<ClonedProjectRef>>(
          future: _projects,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final items = snapshot.data ?? const [];
            if (items.isEmpty) {
              return const Center(
                child: Text(
                  'No projects yet.\n\nFile → Clone repository… to download one.',
                  textAlign: TextAlign.center,
                ),
              );
            }
            return ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final project = items[index];
                return ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(project.name),
                  subtitle: Text(
                    project.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _open(project),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
