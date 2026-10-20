import 'dart:async';

import 'package:flutter/material.dart';

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
  final List<({String kind, String text})> blocks;
}

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

  @override
  void initState() {
    super.initState();
    if (widget.visible) _start();
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
      setState(() {
        _entries = [for (final message in raw) _toEntry(message)];
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
    final blocks = <({String kind, String text})>[];
    final parts = message['parts'];
    if (parts is List) {
      for (final part in parts) {
        if (part is! Map) continue;
        switch (part['type']) {
          case 'text':
            final text = '${part['text'] ?? ''}'.trim();
            if (text.isNotEmpty) blocks.add((kind: 'text', text: text));
          case 'reasoning':
            final text = '${part['text'] ?? ''}'.trim();
            if (text.isNotEmpty) {
              blocks.add((kind: 'reasoning', text: text));
            }
          case 'tool':
            final state = part['state'];
            final status = state is Map ? '${state['status'] ?? ''}' : '';
            blocks.add((
              kind: 'tool',
              text: '${part['tool'] ?? 'tool'}'
                  '${status.isEmpty ? '' : ' — $status'}',
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

  Future<void> _send() async {
    final api = _api;
    final id = _sessionId;
    final text = _input.text.trim();
    if (api == null || id == null || text.isEmpty) return;
    _input.clear();
    setState(() {
      _busy = true;
      _entries = [
        ..._entries,
        _ChatEntry(role: 'user', blocks: [(kind: 'text', text: text)]),
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
                'tool' => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.build_outlined,
                        size: 13,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          block.text,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                'reasoning' => Text(
                  block.text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: theme.colorScheme.outline,
                  ),
                ),
                _ => SelectableText(block.text),
              },
          ],
        ),
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
