import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app/ide_session.dart';
import '../app/session_commands.dart';

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
