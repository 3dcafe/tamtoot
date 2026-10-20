import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../app/ide_session.dart';
import '../../core/opencode/engine.dart';

/// Full-screen dialog hosting the opencode-backed agent panel.
class AgentDialog extends StatelessWidget {
  const AgentDialog({super.key, required this.session});

  final IdeSession session;

  @override
  Widget build(BuildContext context) => Dialog(
    clipBehavior: Clip.antiAlias,
    child: SizedBox(
      width: 760,
      height: 660,
      child: AgentPanel(session: session, visible: true),
    ),
  );
}

/// Agent sidebar backed by the in-process opencode engine port.
///
/// All agent logic — model routing, the session step loop, tools — lives in
/// `lib/core/opencode`, ported from the opencode sources; no external CLI or
/// server is required.
class AgentPanel extends StatefulWidget {
  const AgentPanel({super.key, required this.session, required this.visible});

  final IdeSession session;
  final bool visible;

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _ChatEntry {
  _ChatEntry({required this.role, required this.blocks});
  final String role;
  final List<_Block> blocks;
}

/// One renderable block inside a chat entry: agent prose (`text`, rendered
/// as Markdown), a collapsible `reasoning` block, or a structured `tool`
/// block with status, an input summary and expandable output.
typedef _Block = ({
  String kind,
  String text,
  String? status,
  String? detail,
  String? output,
});

class _AgentPanelState extends State<AgentPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  OpencodeEngine? _api;
  Timer? _poller;

  var _starting = false;
  String? _error;
  String? _modelLabel;
  List<Map<String, dynamic>> _sessions = const [];
  String? _sessionId;
  List<_ChatEntry> _entries = const [];
  var _busy = false;
  var _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_trackStickToBottom);
    if (widget.visible) _start();
  }

  /// Auto-scroll only while the user is already at the bottom; scrolling up
  /// to read must not be yanked back down by the 1.5 s poll.
  void _trackStickToBottom() {
    if (!_scroll.hasClients) return;
    _stickToBottom = _scroll.position.extentAfter < 80;
  }

  @override
  void didUpdateWidget(covariant AgentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) {
      _start();
    } else if (!widget.visible && oldWidget.visible) {
      _poller?.cancel();
    }
  }

  @override
  void dispose() {
    _poller?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String? get _projectPath {
    final root = widget.session.workspaceRoot;
    if (root == null) return null;
    try {
      return root.toFilePath();
    } catch (_) {
      return null;
    }
  }

  Future<void> _start() async {
    if (_starting) return;
    final path = _projectPath;
    if (path == null) {
      setState(() => _error = 'Open a project folder to use the agent.');
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      _api = OpencodeEngine.forProject(path);
      await _loadSessions();
      _sessionId ??= await _api!.createSession(title: 'Tamtoot session');
      await _refresh();
      // Resolved once per engine start; discovery hits the provider's HTTP
      // API, so it is not part of the 1.5 s poll.
      final providers = await _api!.providers();
      final defaults = providers['default'];
      if (mounted && defaults is Map && defaults.isNotEmpty) {
        final provider = '${defaults.keys.first}';
        setState(() => _modelLabel = '$provider/${defaults.values.first}');
      }
      _poller?.cancel();
      _poller = Timer.periodic(
        const Duration(milliseconds: 1500),
        (_) => _refresh(),
      );
    } on OpencodeException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _loadSessions() async {
    final api = _api;
    if (api == null) return;
    final sessions = await api.sessions();
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      if (_sessionId == null && sessions.isNotEmpty) {
        _sessionId = sessions.first['id'] as String?;
      }
    });
  }

  Future<void> _refresh() async {
    final api = _api;
    final id = _sessionId;
    if (api == null || id == null || !mounted) return;
    try {
      final raw = await api.messages(id);
      final status = await api.sessionStatus();
      if (!mounted) return;
      // Assistant messages are created when a step starts, before the first
      // token lands; skip them while they are still empty.
      final entries = [for (final message in raw) _toEntry(message)]
        ..removeWhere(
          (entry) => entry.blocks.isEmpty && entry.role != 'user',
        );
      setState(() {
        _entries = entries;
        final state = status[id];
        _busy = state is Map && '${state['type'] ?? state}' != 'idle';
      });
      _scrollToEnd();
    } catch (_) {
      // Transient poll failures are ignored; the next tick retries.
    }
  }

  _ChatEntry _toEntry(Map<String, dynamic> message) {
    final info = message['info'];
    final role = info is Map ? '${info['role'] ?? 'assistant'}' : 'assistant';
    final blocks = <_Block>[];
    final parts = message['parts'];
    if (parts is List) {
      for (final part in parts) {
        if (part is! Map) continue;
        switch (part['type']) {
          case 'text':
            final text = '${part['text'] ?? ''}'.trim();
            if (text.isNotEmpty) {
              blocks.add((kind: 'text', text: text, status: null, detail: null, output: null));
            }
          case 'reasoning':
            final text = '${part['text'] ?? ''}'.trim();
            if (text.isNotEmpty) {
              blocks.add((kind: 'reasoning', text: text, status: null, detail: null, output: null));
            }
          case 'tool':
            final state = part['state'];
            final status = state is Map ? '${state['status'] ?? ''}' : '';
            final input = state is Map ? state['input'] : null;
            final output = state is Map ? state['output'] : null;
            final error = state is Map ? state['error'] : null;
            blocks.add((
              kind: 'tool',
              text: '${part['tool'] ?? 'tool'}',
              status: status.isEmpty ? null : status,
              detail: _summarizeInput(input),
              output: (output ?? error) as String?,
            ));
          case 'step-start' || 'step-finish' || 'snapshot':
            break;
          default:
            break;
        }
      }
    }
    return _ChatEntry(role: role, blocks: blocks);
  }

  /// One-line summary of a tool call's input: the meaningful argument
  /// (path, command, pattern) when present, otherwise compact JSON.
  String? _summarizeInput(dynamic input) {
    if (input is! Map) return null;
    for (final key in const ['path', 'command', 'pattern', 'workdir']) {
      final value = input[key];
      if (value is String && value.isNotEmpty) {
        return value.length > 120 ? '${value.substring(0, 120)}…' : value;
      }
    }
    final oldString = input['oldString'];
    if (oldString is String && oldString.isNotEmpty) {
      final firstLine = oldString.split('\n').first;
      return firstLine.length > 120
          ? '${firstLine.substring(0, 120)}…'
          : firstLine;
    }
    final json = jsonEncode(input);
    return json.length > 120 ? '${json.substring(0, 120)}…' : json;
  }

  Future<void> _send() async {
    final api = _api;
    final id = _sessionId;
    final text = _input.text.trim();
    if (api == null || id == null || text.isEmpty) return;
    _input.clear();
    setState(() {
      _busy = true;
      _stickToBottom = true;
      _entries = [
        ..._entries,
        _ChatEntry(
          role: 'user',
          blocks: [
            (kind: 'text', text: text, status: null, detail: null, output: null),
          ],
        ),
      ];
    });
    _scrollToEnd();
    try {
      await api.promptAsync(id, text);
    } on OpencodeException catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
    unawaited(_refresh());
  }

  Future<void> _abort() async {
    final api = _api;
    final id = _sessionId;
    if (api == null || id == null) return;
    await api.abort(id);
    await _refresh();
  }

  Future<void> _newSession() async {
    final api = _api;
    if (api == null) return;
    final id = await api.createSession(title: 'Tamtoot session');
    setState(() {
      _sessionId = id;
      _entries = const [];
    });
    await _loadSessions();
    await _refresh();
  }

  void _scrollToEnd() {
    if (!_stickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.smart_toy_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _modelLabel == null ? 'Agent' : 'Agent — $_modelLabel',
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_sessions.length > 1)
                DropdownButton<String>(
                  value: _sessionId,
                  hint: const Text('Session'),
                  items: [
                    for (final s in _sessions)
                      DropdownMenuItem(
                        value: s['id'] as String,
                        child: Text(
                          '${s['title'] ?? s['id']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    setState(() => _sessionId = value);
                    _refresh();
                  },
                ),
              IconButton(
                tooltip: 'New session',
                onPressed: _api == null ? null : _newSession,
                icon: const Icon(Icons.add, size: 18),
              ),
              IconButton(
                tooltip: 'Restart engine',
                onPressed: () {
                  setState(() {
                    _sessionId = null;
                    _modelLabel = null;
                  });
                  final path = _projectPath;
                  if (path != null) OpencodeEngine.restart(path);
                  _start();
                },
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _error != null
              ? _ErrorView(
                  message: _error!,
                  busy: _starting,
                  onRetry: _start,
                )
              : _entries.isEmpty
              ? Center(
                  child: Text(
                    _starting
                        ? 'Starting the agent engine…'
                        : 'Ask the agent to change something in this project.',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _entries.length,
                  itemBuilder: (_, index) =>
                      _EntryView(entry: _entries[index]),
                ),
        ),
        if (_busy)
          const LinearProgressIndicator(minHeight: 2),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 6,
                  enabled: _api != null,
                  decoration: const InputDecoration(
                    hintText: 'Message the agent…',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              _busy
                  ? IconButton(
                      tooltip: 'Abort',
                      onPressed: _abort,
                      icon: const Icon(Icons.stop_circle_outlined),
                    )
                  : IconButton(
                      tooltip: 'Send',
                      onPressed: _api == null ? null : _send,
                      icon: const Icon(Icons.send),
                    ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EntryView extends StatelessWidget {
  const _EntryView({required this.entry});
  final _ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = entry.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final block in entry.blocks)
              switch (block.kind) {
                'tool' => _ToolBlock(block: block),
                'reasoning' => _ReasoningBlock(text: block.text),
                _ => MarkdownBody(
                  data: block.text,
                  selectable: true,
                  styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                    p: theme.textTheme.bodyMedium,
                    code: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      backgroundColor: theme.colorScheme.surfaceContainer,
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              },
          ],
        ),
      ),
    );
  }
}

/// Collapsible reasoning block — long chains of thought stay out of the way.
class _ReasoningBlock extends StatelessWidget {
  const _ReasoningBlock({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        dense: true,
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          'Reasoning',
          style: theme.textTheme.bodySmall?.copyWith(
            fontStyle: FontStyle.italic,
            color: theme.colorScheme.outline,
          ),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Structured tool block: name, live status, a one-line input summary and
/// expandable output. Running tools stay expanded, completed ones collapse.
class _ToolBlock extends StatelessWidget {
  const _ToolBlock({required this.block});
  final _Block block;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = block.status == 'running' || block.status == 'pending';
    final failed = block.status == 'error';
    final icon = running
        ? SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.colorScheme.outline,
            ),
          )
        : Icon(
            failed ? Icons.error_outline : Icons.build_outlined,
            size: 13,
            color: failed ? theme.colorScheme.error : theme.colorScheme.outline,
          );
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        dense: true,
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        initiallyExpanded: running,
        title: Row(
          children: [
            icon,
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                '${block.text}${block.status == null ? '' : ' — ${block.status}'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: failed ? theme.colorScheme.error : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        subtitle: block.detail == null
            ? null
            : Text(
                block.detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
        children: [
          if (block.output != null && block.output!.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: SelectableText(
                  block.output!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    required this.busy,
    required this.onRetry,
  });
  final String message;
  final bool busy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 32),
          const SizedBox(height: 12),
          SelectableText(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: busy ? null : onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(busy ? 'Starting…' : 'Retry'),
          ),
        ],
      ),
    ),
  );
}
