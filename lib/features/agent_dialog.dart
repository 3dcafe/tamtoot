import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/ide_session.dart';
import '../core/agents/agent_engine.dart';
import '../core/agents/model_attachment.dart';
import '../core/agents/model_profile.dart';
import '../core/agents/mcp_client.dart';
import '../core/agents/profile_store.dart';
import '../core/git/http_git_service.dart';

class AgentDialog extends StatelessWidget {
  const AgentDialog({super.key, required this.session});
  final IdeSession session;

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: SizedBox(
      width: 800,
      height: MediaQuery.sizeOf(context).height * .82,
      child: AgentPanel(session: session, embedded: false),
    ),
  );
}

class AgentPanel extends StatefulWidget {
  const AgentPanel({super.key, required this.session, this.embedded = true});

  final IdeSession session;
  final bool embedded;

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  final task = TextEditingController();
  final apiKey = TextEditingController();
  final scroll = ScrollController();
  final events = <AgentEvent>[];
  final profiles = <String, ModelProfile>{};
  final attachments = <ModelAttachment>[];
  String? selected, error;
  bool loading = true, running = false, yolo = true, yoloConfirmed = false;
  final taskQueue = <String>[];
  int timeoutSeconds = 600, maxMistakes = 3;
  int _catalogRevision = -1;
  StreamSubscription<int>? _sessionSub;
  AgentTaskEngine? engine;
  McpRegistry? activeMcp;
  late final Uri? root = widget.session.workspaceRoot;

  /// Last user task that actually started a run (not the Continue wrapper).
  String? _lastTask;

  /// Why the last run stopped; non-null enables the Continue button.
  String? _lastFailure;

  @override
  void initState() {
    super.initState();
    _catalogRevision = widget.session.agentCatalogRevision;
    _sessionSub = widget.session.changes.listen((_) {
      if (!mounted || running) return;
      if (widget.session.agentCatalogRevision == _catalogRevision) return;
      _catalogRevision = widget.session.agentCatalogRevision;
      unawaited(_load(preserveSelection: true));
    });
    _load();
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    engine?.stop();
    activeMcp?.close();
    apiKey.clear();
    apiKey.dispose();
    task.dispose();
    scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _load({bool preserveSelection = false}) async {
    final previous = selected;
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
        profiles.clear();
        if (!preserveSelection) selected = null;
      });
    }
    try {
      if (root == null) {
        error = 'Open a project to use Agent.';
        return;
      }
      if (widget.session.git is! HttpGitService) {
        error = 'Agent is unavailable for this project provider.';
        return;
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
      if (preserveSelection &&
          previous != null &&
          profiles.containsKey(previous)) {
        selected = previous;
      } else {
        selected = profiles.keys.firstOrNull;
      }
      _catalogRevision = widget.session.agentCatalogRevision;
      if (selected == null) {
        error = 'Create a model profile in Settings first.';
      } else {
        _restoreApiKey();
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
        : action == 'replace_in_file'
        ? '$path\n\nThe agent will replace one exact text fragment in this file.'
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

  Future<void> _pickAttachments() async {
    if (running) return;
    final files = await openFiles(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
        ),
        const XTypeGroup(
          label: 'Documents',
          extensions: [
            'pdf',
            'txt',
            'md',
            'csv',
            'json',
            'xml',
            'html',
            'doc',
            'docx',
            'xls',
            'xlsx',
            'dart',
            'py',
            'js',
            'ts',
            'yaml',
            'yml',
          ],
        ),
      ],
    );
    if (files.isEmpty || !mounted) return;
    final next = List<ModelAttachment>.from(attachments);
    try {
      for (final file in files) {
        final bytes = await file.readAsBytes();
        next.add(
          ModelAttachment(
            name: file.name,
            mimeType: ModelAttachment.mimeForName(file.name),
            bytes: Uint8List.fromList(bytes),
          ),
        );
      }
      ModelAttachment.validateAll(next);
      setState(() {
        attachments
          ..clear()
          ..addAll(next);
        error = null;
      });
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (e) {
      if (mounted) setState(() => error = 'Could not attach file: $e');
    }
  }

  bool get _canContinue =>
      !running &&
      root != null &&
      selected != null &&
      (_lastTask?.trim().isNotEmpty ?? false) &&
      _lastFailure != null;

  Future<void> _start({bool continuePrevious = false}) async {
    final path = selected;
    final typed = task.text.trim();
    if (running || path == null || root == null) return;
    if (continuePrevious) {
      if (!_canContinue) return;
    } else if (typed.isEmpty && attachments.isEmpty) {
      return;
    }
    if (widget.session.workspaceRoot != root) {
      setState(() => error = 'The active project changed. Reopen Agent.');
      return;
    }
    final profile = profiles[path];
    if (profile == null) {
      setState(() => error = 'Select a model profile first.');
      return;
    }
    if (_profileNeedsApiKey(profile) && apiKey.text.trim().isEmpty) {
      setState(
        () => error =
            'Enter the API token below, then send again. It will be reused until the app closes.',
      );
      return;
    }
    try {
      ModelAttachment.validateAll(attachments);
    } on FormatException catch (e) {
      setState(() => error = e.message);
      return;
    }
    if (yolo && !await _confirmYolo()) return;

    final originalTask = continuePrevious
        ? _lastTask!.trim()
        : (typed.isEmpty ? 'Please inspect the attached files.' : typed);
    final failure = _lastFailure;
    final prompt = continuePrevious
        ? buildAgentContinuationPrompt(
            originalTask: originalTask,
            stopReason: failure ?? 'unknown',
          )
        : originalTask;
    final runAttachments = continuePrevious
        ? const <ModelAttachment>[]
        : List<ModelAttachment>.from(attachments);

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
      profile: profile,
      store: git.openStore(root!),
      git: git,
      root: root!,
      apiKey: apiKey.text.trim(),
      attachments: runAttachments,
      onEvent: (event) {
        if (mounted) {
          setState(() => events.add(event));
          _scrollToEnd();
        }
      },
      approve: _approve,
      mcp: mcp,
    );
    setState(() {
      engine = runner;
      activeMcp = mcp;
      running = true;
      error = null;
      _lastTask = originalTask;
      _lastFailure = null;
      events.add(
        AgentEvent(
          'user',
          continuePrevious
              ? 'Continue previous task\n\n$originalTask'
              : [
                  originalTask,
                  if (runAttachments.isNotEmpty)
                    'Attachments: ${runAttachments.map((item) => item.name).join(', ')}',
                ].join('\n'),
        ),
      );
      if (!continuePrevious) {
        task.clear();
        attachments.clear();
      }
    });
    _scrollToEnd();
    try {
      await runner.run(
        prompt,
        AgentRunOptions(
          yolo: yolo,
          timeout: Duration(seconds: timeoutSeconds),
          maxConsecutiveMistakes: maxMistakes,
        ),
      );
      await widget.session.refreshExplorer();
      if (mounted) {
        setState(() {
          _lastFailure = null;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          _lastFailure = '$e';
          // Put the original task back so it is obvious what Continue will redo.
          if (task.text.trim().isEmpty) task.text = originalTask;
        });
      }
    } finally {
      // Keep the API key in memory for the Agent panel session.
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

  bool _profileNeedsApiKey(ModelProfile profile) {
    if (profile.apiFormat == 'ollama') return false;
    final host = profile.requestUri().host.toLowerCase();
    return host != 'localhost' && host != '127.0.0.1';
  }

  bool get _selectedNeedsApiKey {
    final profile = selected == null ? null : profiles[selected];
    return profile != null && _profileNeedsApiKey(profile);
  }

  void _restoreApiKey() {
    final profile = selected == null ? null : profiles[selected];
    apiKey.text = profile == null ? '' : widget.session.modelApiKey(profile.id);
  }

  void _selectProfile(String? value) {
    setState(() {
      selected = value;
      error = null;
      _restoreApiKey();
    });
  }

  void _rememberApiKey(String value) {
    final profile = selected == null ? null : profiles[selected];
    if (profile != null) {
      widget.session.rememberModelApiKey(profile.id, value);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !running,
      child: Material(
        color: colors.surface,
        borderRadius: widget.embedded ? null : BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 6),
              child: Row(
                children: [
                  const Icon(Icons.smart_toy_outlined, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Agent',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Reload model profiles',
                    visualDensity: VisualDensity.compact,
                    onPressed: running || loading ? null : _load,
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                  IconButton(
                    tooltip: 'Model settings',
                    visualDensity: VisualDensity.compact,
                    onPressed: running
                        ? null
                        : () => widget.session.run('settings.open'),
                    icon: const Icon(Icons.settings_outlined, size: 18),
                  ),
                  if (!widget.embedded)
                    IconButton(
                      tooltip: 'Close',
                      visualDensity: VisualDensity.compact,
                      onPressed: running ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                ],
              ),
            ),
            if (loading) const LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: DropdownButtonFormField<String>(
                key: ValueKey(selected ?? 'none'),
                isExpanded: true,
                initialValue: selected,
                decoration: const InputDecoration(
                  labelText: 'Model profile',
                  isDense: true,
                ),
                items: [
                  for (final entry in profiles.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(
                        '${entry.value.name} · ${entry.value.model}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: running ? null : _selectProfile,
              ),
            ),
            Expanded(
              child: events.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          root == null
                              ? 'Open a project to chat with Agent.'
                              : 'Chat with the agent about the project.\nNo open file is required — describe the task below.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                      itemCount: events.length,
                      itemBuilder: (_, index) => _eventCard(events[index]),
                    ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      error!,
                      style: TextStyle(fontSize: 12, color: colors.error),
                    ),
                    if (_canContinue)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Press Continue to retry without restarting from scratch.',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: TextField(
                controller: apiKey,
                enabled: !running,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                onChanged: _rememberApiKey,
                decoration: InputDecoration(
                  labelText: _selectedNeedsApiKey
                      ? 'API token'
                      : 'API token (optional)',
                  helperText: _selectedNeedsApiKey
                      ? apiKey.text.isEmpty
                            ? 'Required. Enter it once; it is saved locally on this device.'
                            : 'Saved locally for this profile. It is never added to the project.'
                      : 'Local Ollama usually works without a token.',
                  suffixIcon: apiKey.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Forget token',
                          onPressed: running
                              ? null
                              : () {
                                  apiKey.clear();
                                  _rememberApiKey('');
                                },
                          icon: const Icon(Icons.close, size: 16),
                        ),
                  isDense: true,
                ),
              ),
            ),
            ExpansionTile(
              dense: true,
              tilePadding: const EdgeInsets.symmetric(horizontal: 10),
              title: const Text(
                'Agent options',
                style: TextStyle(fontSize: 12),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilterChip(
                      selected: yolo,
                      onSelected: running
                          ? null
                          : (value) => setState(() => yolo = value),
                      label: const Text('YOLO'),
                    ),
                    SizedBox(
                      width: 120,
                      child: TextFormField(
                        initialValue: '$timeoutSeconds',
                        enabled: !running,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Timeout, sec',
                          isDense: true,
                        ),
                        onChanged: (value) =>
                            timeoutSeconds = int.tryParse(value) ?? 600,
                      ),
                    ),
                    SizedBox(
                      width: 120,
                      child: TextFormField(
                        initialValue: '$maxMistakes',
                        enabled: !running,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Max mistakes',
                          isDense: true,
                        ),
                        onChanged: (value) =>
                            maxMistakes = int.tryParse(value) ?? 3,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (running) const LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: Column(
                children: [
                  if (attachments.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (var i = 0; i < attachments.length; i++)
                            InputChip(
                              avatar: Icon(
                                attachments[i].isImage
                                    ? Icons.image_outlined
                                    : Icons.attach_file,
                                size: 16,
                              ),
                              label: Text(
                                attachments[i].name,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onDeleted: running
                                  ? null
                                  : () =>
                                        setState(() => attachments.removeAt(i)),
                            ),
                        ],
                      ),
                    ),
                  if (attachments.isNotEmpty) const SizedBox(height: 6),
                  TextField(
                    controller: task,
                    enabled: !running && root != null,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) {
                      if (!running &&
                          selected != null &&
                          root != null &&
                          (task.text.trim().isNotEmpty ||
                              attachments.isNotEmpty)) {
                        unawaited(_start());
                      }
                    },
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Поручите что угодно…',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (events.isNotEmpty)
                        IconButton(
                          tooltip: 'Clear conversation',
                          visualDensity: VisualDensity.compact,
                          onPressed: running
                              ? null
                              : () => setState(() {
                                  events.clear();
                                  _lastFailure = null;
                                  _lastTask = null;
                                  error = null;
                                }),
                          icon: const Icon(
                            Icons.delete_sweep_outlined,
                            size: 18,
                          ),
                        ),
                      IconButton(
                        tooltip: 'Attach image or file',
                        visualDensity: VisualDensity.compact,
                        onPressed: running || root == null
                            ? null
                            : () => unawaited(_pickAttachments()),
                        icon: const Icon(Icons.attach_file, size: 18),
                      ),
                      IconButton(
                        tooltip: 'Copy chat log',
                        visualDensity: VisualDensity.compact,
                        onPressed: events.isEmpty ? null : _copyTranscript,
                        icon: const Icon(Icons.copy_all_outlined, size: 18),
                      ),
                      IconButton(
                        tooltip: 'JSON: client ↔ agent',
                        visualDensity: VisualDensity.compact,
                        onPressed: _modelExchanges.isEmpty
                            ? null
                            : () => _showJsonLog(_modelExchanges),
                        icon: const Icon(Icons.data_object, size: 18),
                      ),
                      const Spacer(),
                      if (running)
                        FilledButton.tonalIcon(
                          onPressed: () => engine?.stop(),
                          icon: const Icon(Icons.stop, size: 18),
                          label: const Text('Stop'),
                        )
                      else ...[
                        if (_canContinue) ...[
                          FilledButton.tonalIcon(
                            key: const ValueKey('agent-continue'),
                            onPressed: () =>
                                unawaited(_start(continuePrevious: true)),
                            icon: const Icon(Icons.replay, size: 18),
                            label: const Text('Continue'),
                          ),
                          const SizedBox(width: 8),
                        ],
                        IconButton.filled(
                          tooltip: 'Send',
                          onPressed:
                              selected == null ||
                                  root == null ||
                                  (task.text.trim().isEmpty &&
                                      attachments.isEmpty)
                              ? null
                              : () => unawaited(_start()),
                          icon: const Icon(Icons.arrow_upward, size: 18),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<AgentEvent> get _modelExchanges =>
      events.where((event) => event.type == 'model').toList(growable: false);

  String _transcriptText() {
    final buffer = StringBuffer();
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      buffer.writeln('[${event.type}] ${event.text}');
      if (event.data.isNotEmpty) {
        try {
          buffer.writeln(
            const JsonEncoder.withIndent('  ').convert(event.data),
          );
        } catch (_) {
          buffer.writeln(event.data.toString());
        }
      }
      if (i < events.length - 1) buffer.writeln();
    }
    return buffer.toString();
  }

  Future<void> _copyTranscript() async {
    final text = _transcriptText();
    if (text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Chat log copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Widget _eventCard(AgentEvent event) {
    final colors = Theme.of(context).colorScheme;
    final user = event.type == 'user';
    final errorEvent = event.type == 'error';
    final model = event.type == 'model';
    final memory = event.type == 'memory';
    final hasJson =
        event.data.containsKey('request') || event.data.containsKey('response');
    if (memory) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          event.text,
          style: TextStyle(
            fontSize: 11,
            color: colors.onSurfaceVariant,
            fontFamily: 'monospace',
          ),
        ),
      );
    }
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 620),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(
          color: user
              ? colors.primaryContainer
              : errorEvent
              ? colors.errorContainer
              : model
              ? colors.surfaceContainerHigh
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: model
              ? Border.all(color: colors.outlineVariant.withValues(alpha: 0.6))
              : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user
                        ? 'You'
                        : model
                        ? 'Model'
                        : event.type,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 3),
                  SelectableText(
                    event.text,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: model || errorEvent ? 'monospace' : null,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Copy message',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: () async {
                final payload = event.data.isEmpty
                    ? event.text
                    : const JsonEncoder.withIndent('  ').convert({
                        'type': event.type,
                        'text': event.text,
                        'data': event.data,
                      });
                await Clipboard.setData(ClipboardData(text: payload));
              },
              icon: Icon(
                Icons.copy_outlined,
                size: 16,
                color: colors.onSurfaceVariant,
              ),
            ),
            if (hasJson)
              IconButton(
                tooltip: 'Show request / response JSON',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
                onPressed: () => _showJsonLog([event]),
                icon: Icon(Icons.data_object, size: 18, color: colors.primary),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showJsonLog(List<AgentEvent> exchanges) async {
    if (!mounted || exchanges.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final colors = Theme.of(ctx).colorScheme;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (context, scrollController) => DefaultTabController(
            length: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Client ↔ Agent JSON',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy all',
                        onPressed: () {
                          final payload = exchanges
                              .map((event) => event.toJson())
                              .toList();
                          Clipboard.setData(
                            ClipboardData(
                              text: const JsonEncoder.withIndent(
                                '  ',
                              ).convert(payload),
                            ),
                          );
                          ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                            const SnackBar(
                              content: Text('JSON log copied'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy_outlined, size: 18),
                      ),
                    ],
                  ),
                ),
                const TabBar(
                  tabs: [
                    Tab(text: 'Client → model'),
                    Tab(text: 'Agent ← model'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _jsonPages(
                        scrollController,
                        colors,
                        exchanges,
                        requestSide: true,
                      ),
                      _jsonPages(
                        scrollController,
                        colors,
                        exchanges,
                        requestSide: false,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _jsonPages(
    ScrollController controller,
    ColorScheme colors,
    List<AgentEvent> exchanges, {
    required bool requestSide,
  }) {
    return ListView.separated(
      controller: controller,
      padding: const EdgeInsets.all(12),
      itemCount: exchanges.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, index) {
        final event = exchanges[index];
        final payload = requestSide
            ? {
                'endpoint': event.data['endpoint'],
                'apiFormat': event.data['apiFormat'],
                'request': event.data['request'] ?? {},
              }
            : event.data['response'] ?? {'text': event.text};
        final pretty = const JsonEncoder.withIndent('  ').convert(payload);
        return Material(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        requestSide
                            ? 'Request #${index + 1}'
                            : 'Response #${index + 1}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy',
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: pretty)),
                      icon: const Icon(Icons.copy_outlined, size: 16),
                    ),
                  ],
                ),
                SelectableText(
                  pretty,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Prompt used when the user presses Continue after timeout / stop / mistakes.
@visibleForTesting
String buildAgentContinuationPrompt({
  required String originalTask,
  required String stopReason,
}) {
  final reason = stopReason.trim().isEmpty
      ? 'unknown'
      : stopReason.trim().split('\n').first;
  return 'Continue the unfinished agent task. '
      'Previous run stopped: $reason\n'
      'Do not restart investigation from scratch. '
      'Prefer replace_in_file, write_file, or finish over more search_files.\n'
      'Reuse retained project memory and already known files.\n\n'
      'Original task:\n$originalTask';
}
