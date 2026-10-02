import 'package:flutter/material.dart';

import '../app/ide_session.dart';
import '../core/agents/kanban.dart';
import '../core/agents/worktree_service.dart';
import '../core/git/http_git_service.dart';

class KanbanDialog extends StatefulWidget {
  const KanbanDialog({super.key, required this.session});
  final IdeSession session;

  @override
  State<KanbanDialog> createState() => _KanbanDialogState();
}

class _KanbanDialogState extends State<KanbanDialog> {
  final title = TextEditingController(), description = TextEditingController();
  final horizontalScroll = ScrollController();
  final columnScroll = <KanbanStatus, ScrollController>{
    for (final status in KanbanStatus.values) status: ScrollController(),
  };
  KanbanStore? store;
  KanbanBoard board = const KanbanBoard([]);
  String? error;
  bool busy = true;
  late final root = widget.session.workspaceRoot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    horizontalScroll.dispose();
    for (final controller in columnScroll.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      if (root == null || widget.session.git is! HttpGitService) {
        throw StateError('Open a supported Git project first.');
      }
      final git = widget.session.git as HttpGitService;
      store = KanbanStore(git.openStore(root!));
      board = await store!.load();
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _save(List<KanbanCard> cards) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (widget.session.workspaceRoot != root) {
        throw StateError('The project changed. Reopen Kanban.');
      }
      final updated = KanbanBoard(cards);
      await store!.save(updated);
      board = updated;
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _create() async {
    final name = title.text.trim();
    if (name.isEmpty) return;
    var id = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (id.isEmpty) id = 'task';
    var suffix = 2;
    final ids = board.cards.map((card) => card.id).toSet();
    final base = id;
    while (ids.contains(id)) {
      id = '$base-${suffix++}';
    }
    await _save([
      ...board.cards,
      KanbanCard(id: id, title: name, description: description.text.trim()),
    ]);
    title.clear();
    description.clear();
  }

  Future<void> _move(KanbanCard card, KanbanStatus status) => _save([
    for (final item in board.cards)
      if (item.id == card.id) item.copyWith(status: status) else item,
  ]);

  String _statusTitle(KanbanStatus status) => switch (status) {
    KanbanStatus.todo => 'Todo',
    KanbanStatus.inProgress => 'In Progress',
    KanbanStatus.review => 'Review',
    KanbanStatus.done => 'Done',
  };

  Widget _card(BuildContext context, KanbanCard card, {bool feedback = false}) {
    final content = Card(
      elevation: feedback ? 8 : null,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(card.title),
            if (card.description.isNotEmpty) Text(card.description),
            if (!feedback && card.worktree.isNotEmpty)
              SelectableText(
                card.worktree,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (!feedback)
              DropdownButton<KanbanStatus>(
                value: card.status,
                isExpanded: true,
                items: [
                  for (final value in KanbanStatus.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(_statusTitle(value)),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) {
                        if (value != null && value != card.status) {
                          _move(card, value);
                        }
                      },
              ),
            if (!feedback && card.worktree.isEmpty)
              TextButton.icon(
                onPressed: busy ? null : () => _worktree(card),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Create worktree'),
              ),
          ],
        ),
      ),
    );
    if (feedback) {
      return Material(
        color: Colors.transparent,
        child: SizedBox(width: 244, child: content),
      );
    }
    if (busy) return content;
    return LongPressDraggable<KanbanCard>(
      data: card,
      feedback: _card(context, card, feedback: true),
      childWhenDragging: Opacity(opacity: .35, child: content),
      child: Tooltip(message: 'Hold and drag to move', child: content),
    );
  }

  Widget _column(BuildContext context, KanbanStatus status, double height) {
    final cards = board.cards
        .where((card) => card.status == status)
        .toList(growable: false);
    return SizedBox(
      width: 260,
      height: height,
      child: DragTarget<KanbanCard>(
        onWillAcceptWithDetails: (details) =>
            !busy && details.data.status != status,
        onAcceptWithDetails: (details) => _move(details.data, status),
        builder: (context, candidates, rejected) {
          final highlighted = candidates.isNotEmpty;
          return Card(
            color: highlighted
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _statusTitle(status),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      Text('${cards.length}'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Scrollbar(
                      controller: columnScroll[status],
                      thumbVisibility: cards.length > 2,
                      child: ListView.builder(
                        controller: columnScroll[status],
                        padding: const EdgeInsets.only(right: 4, bottom: 8),
                        itemCount: cards.length + (highlighted ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == cards.length) {
                            return Container(
                              height: 54,
                              margin: const EdgeInsets.only(bottom: 8),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Text('Move here'),
                            );
                          }
                          return _card(context, cards[index]);
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _worktree(KanbanCard card) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!board.ready(card)) {
        throw StateError(
          'Complete all dependencies before starting this card.',
        );
      }
      final uri = await AgentWorktreeService().create(root!, card.id);
      await _save([
        for (final item in board.cards)
          if (item.id == card.id)
            item.copyWith(
              status: KanbanStatus.inProgress,
              worktree: uri.toFilePath(),
            )
          else
            item,
      ]);
    } catch (e) {
      error = '$e';
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Agent Kanban'),
    content: SizedBox(
      width: 1100,
      height: MediaQuery.sizeOf(context).height * .72,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: title,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: 'New task'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: description,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
              ),
              IconButton(
                onPressed: busy ? null : _create,
                icon: const Icon(Icons.add),
                tooltip: 'Add card',
              ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            SelectableText(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Scrollbar(
                controller: horizontalScroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: horizontalScroll,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final status in KanbanStatus.values) ...[
                        _column(context, status, constraints.maxHeight - 12),
                        if (status != KanbanStatus.values.last)
                          const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
