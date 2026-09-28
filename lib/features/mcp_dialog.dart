import 'package:flutter/material.dart';

import '../app/ide_session.dart';
import '../core/agents/mcp_client.dart';
import '../core/agents/profile_store.dart';
import '../core/git/http_git_service.dart';

class McpDialog extends StatefulWidget {
  const McpDialog({super.key, required this.session});
  final IdeSession session;

  @override
  State<McpDialog> createState() => _McpDialogState();
}

class _McpDialogState extends State<McpDialog> {
  static const path = '.tamtoot/mcp.json';
  static const example = '''{
  "mcpServers": {
    "local": {
      "type": "streamableHttp",
      "url": "http://localhost:3000/mcp",
      "disabled": true,
      "timeoutSeconds": 30
    }
  }
}''';
  final source = TextEditingController(text: example);
  ProfileStore? store;
  String? original, status, error;
  bool busy = true, dirty = false;
  late final root = widget.session.workspaceRoot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    source.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      if (root == null || widget.session.git is! HttpGitService) {
        throw StateError('Open a supported project first.');
      }
      final git = widget.session.git as HttpGitService;
      store = ProfileStore(git.openStore(root!));
      original = await store!.read(path);
      if (original != null) source.text = original!;
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      busy = true;
      error = null;
      status = null;
    });
    try {
      if (widget.session.workspaceRoot != root) {
        throw StateError('The active project changed. Reopen MCP settings.');
      }
      McpConfig.parse(source.text);
      await store!.save(path, source.text, original);
      original = source.text;
      dirty = false;
      status = 'Saved $path';
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _test() async {
    setState(() {
      busy = true;
      error = null;
      status = null;
    });
    McpRegistry? registry;
    try {
      final config = McpConfig.parse(source.text);
      registry = McpRegistry(config);
      await registry.connect();
      final description = registry.describe();
      status = description.isEmpty
          ? 'No enabled Streamable HTTP servers.'
          : 'Connected tools:\n$description';
    } catch (e) {
      error = '$e';
    } finally {
      registry?.close();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy && !dirty,
    child: AlertDialog(
      title: const Text('MCP servers'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Project configuration in .tamtoot/mcp.json. Streamable HTTP servers are available to Agent after initialization.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: source,
                enabled: !busy,
                minLines: 14,
                maxLines: 28,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                onChanged: (_) => setState(() => dirty = true),
                decoration: const InputDecoration(
                  labelText: 'MCP JSON',
                  border: OutlineInputBorder(),
                ),
              ),
              if (busy) const LinearProgressIndicator(),
              if (status != null) SelectableText(status!),
              if (error != null)
                SelectableText(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const Text(
                'Header values are stored in this project file. Prefer a local proxy or short-lived token; do not commit secrets.',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : _test,
          child: const Text('Test connections'),
        ),
        TextButton(
          onPressed: busy || dirty ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: busy ? null : _save,
          child: Text(dirty ? 'Save *' : 'Save'),
        ),
      ],
    ),
  );
}
