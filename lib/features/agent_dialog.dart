import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/ide_session.dart';
import '../core/agents/agent_engine.dart';
import '../core/agents/model_profile.dart';
import '../core/agents/mcp_client.dart';
import '../core/agents/profile_store.dart';
import '../core/git/http_git_service.dart';

class AgentDialog extends StatefulWidget {
  const AgentDialog({super.key, required this.session});
  final IdeSession session;

  @override
  State<AgentDialog> createState() => _AgentDialogState();
}

class _AgentDialogState extends State<AgentDialog> {
  final task = TextEditingController();
  final apiKey = TextEditingController();
  final events = <AgentEvent>[];
  final profiles = <String, ModelProfile>{};
  String? selected, error;
  bool loading = true, running = false, yolo = false, yoloConfirmed = false;
  int timeoutSeconds = 600, maxMistakes = 3;
  AgentTaskEngine? engine;
  McpRegistry? activeMcp;
  late final Uri? root = widget.session.workspaceRoot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    engine?.stop();
    activeMcp?.close();
    apiKey.clear();
    apiKey.dispose();
    task.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      if (root == null || widget.session.git is! HttpGitService) {
        throw StateError('Open a supported project first.');
      }
      final git = widget.session.git as HttpGitService;
      final store = ProfileStore(git.openStore(root!));
      final instructions =
          await store.read(ProfileStore.instructionsPath) ?? '';
      for (final path in await store.list()) {
        final text = await store.read(path);
        if (text != null) {
          final loaded = ModelProfile.parse(text);
          profiles[path] = ModelProfile(
            id: loaded.id,
            name: loaded.name,
            provider: loaded.provider,
            model: loaded.model,
            systemPrompt: [
              loaded.systemPrompt,
              instructions,
            ].where((value) => value.trim().isNotEmpty).join('\n\n'),
            userTemplate: loaded.userTemplate,
            parameters: loaded.parameters,
            apiFormat: loaded.apiFormat,
            endpoint: loaded.endpoint,
          );
        }
      }
      selected = profiles.keys.firstOrNull;
      if (selected == null) {
        error = 'Create a model profile in Tools → Settings first.';
      }
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<bool> _approve(String action, Map<String, dynamic> arguments) async {
    if (!mounted) return false;
    final path = arguments['path'];
    final detail = action == 'run_command'
        ? '${arguments['executable']} ${(arguments['args'] as List?)?.join(' ') ?? ''}\n\nThe command runs directly in the project folder.'
        : action == 'mcp_call'
        ? '${arguments['server']}/${arguments['tool']}\n\nArguments: ${jsonEncode(arguments['arguments'])}'
        : '$path\n\nThe agent will replace this file.';
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Allow $action?'),
            content: Text(detail),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Deny'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Allow once'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _confirmYolo() async {
    if (yoloConfirmed) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enable YOLO Mode?'),
        content: const Text(
          'The agent may replace project files without asking for each action. A clean Git working tree is required. Use Stop to interrupt it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Enable for this window'),
          ),
        ],
      ),
    );
    if (confirmed == true) yoloConfirmed = true;
    return confirmed == true;
  }

  Future<void> _start() async {
    final path = selected;
    if (running || path == null || root == null) return;
    if (widget.session.workspaceRoot != root) {
      setState(() => error = 'The active project changed. Reopen Agent.');
      return;
    }
    if (yolo && !await _confirmYolo()) return;
    final git = widget.session.git as HttpGitService;
    McpRegistry? mcp;
    try {
      final projectStore = ProfileStore(git.openStore(root!));
      final configText = await projectStore.read('.tamtoot/mcp.json');
      if (configText != null && configText.trim().isNotEmpty) {
        mcp = McpRegistry(McpConfig.parse(configText));
        await mcp.connect();
      }
    } catch (e) {
      setState(() => error = 'MCP: $e');
      mcp?.close();
      return;
    }
    final runner = AgentTaskEngine(
      profile: profiles[path]!,
      store: git.openStore(root!),
      git: git,
      root: root!,
      apiKey: apiKey.text,
      onEvent: (event) {
        if (mounted) setState(() => events.add(event));
      },
      approve: _approve,
      mcp: mcp,
    );
    setState(() {
      engine = runner;
      activeMcp = mcp;
      running = true;
      error = null;
      events.clear();
    });
    try {
      await runner.run(
        task.text,
        AgentRunOptions(
          yolo: yolo,
          timeout: Duration(seconds: timeoutSeconds),
          maxConsecutiveMistakes: maxMistakes,
        ),
      );
      await widget.session.refreshExplorer();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      apiKey.clear();
      activeMcp?.close();
      if (mounted) {
        setState(() {
          running = false;
          engine = null;
          activeMcp = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !running,
    child: AlertDialog(
      title: const Text('Agent'),
      content: SizedBox(
        width: 800,
        height: MediaQuery.sizeOf(context).height * .72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (loading) const LinearProgressIndicator(),
            DropdownButton<String>(
              isExpanded: true,
              value: selected,
              hint: const Text('Model profile'),
              items: [
                for (final entry in profiles.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text('${entry.value.name} · ${entry.value.model}'),
                  ),
              ],
              onChanged: running
                  ? null
                  : (value) => setState(() => selected = value),
            ),
            TextField(
              controller: task,
              enabled: !running,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Task'),
            ),
            TextField(
              controller: apiKey,
              enabled: !running,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'API key (memory only; empty for Ollama)',
              ),
            ),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterChip(
                  selected: yolo,
                  onSelected: running
                      ? null
                      : (value) => setState(() => yolo = value),
                  label: const Text('YOLO Mode'),
                ),
                SizedBox(
                  width: 150,
                  child: TextFormField(
                    initialValue: '$timeoutSeconds',
                    enabled: !running,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Timeout, sec',
                    ),
                    onChanged: (value) =>
                        timeoutSeconds = int.tryParse(value) ?? 600,
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: TextFormField(
                    initialValue: '$maxMistakes',
                    enabled: !running,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Max mistakes',
                    ),
                    onChanged: (value) =>
                        maxMistakes = int.tryParse(value) ?? 3,
                  ),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: events.isEmpty
                  ? const Center(
                      child: Text('Agent activity will appear here.'),
                    )
                  : ListView.builder(
                      itemCount: events.length,
                      itemBuilder: (_, index) {
                        final event = events[index];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            event.type == 'error'
                                ? Icons.error_outline
                                : event.type == 'done'
                                ? Icons.check_circle_outline
                                : Icons.smart_toy_outlined,
                          ),
                          title: SelectableText(event.text),
                          subtitle: Text(event.type),
                        );
                      },
                    ),
            ),
            if (running) const LinearProgressIndicator(),
            if (error != null)
              SelectableText(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (events.isNotEmpty)
              TextButton(
                onPressed: () => Clipboard.setData(
                  ClipboardData(
                    text: events
                        .map((event) => jsonEncode(event.toJson()))
                        .join('\n'),
                  ),
                ),
                child: const Text('Copy JSON log'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: running ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (running)
          FilledButton.tonal(
            onPressed: () => engine?.stop(),
            child: const Text('Stop'),
          ),
        FilledButton(
          onPressed: running || selected == null ? null : _start,
          child: const Text('Run agent'),
        ),
      ],
    ),
  );
}
