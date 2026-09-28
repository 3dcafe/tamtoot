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
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final status in KanbanStatus.values)
                    SizedBox(
                      width: 260,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                switch (status) {
                                  KanbanStatus.todo => 'Todo',
                                  KanbanStatus.inProgress => 'In Progress',
                                  KanbanStatus.review => 'Review',
                                  KanbanStatus.done => 'Done',
                                },
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              for (final card in board.cards.where(
                                (card) => card.status == status,
                              ))
                                Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Text(card.title),
                                        if (card.description.isNotEmpty)
                                          Text(card.description),
                                        if (card.worktree.isNotEmpty)
                                          SelectableText(
                                            card.worktree,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                        DropdownButton<KanbanStatus>(
                                          value: card.status,
                                          isExpanded: true,
                                          items: [
                                            for (final value
                                                in KanbanStatus.values)
                                              DropdownMenuItem(
                                                value: value,
                                                child: Text(value.name),
                                              ),
                                          ],
                                          onChanged: busy
                                              ? null
                                              : (value) {
                                                  if (value != null) {
                                                    _move(card, value);
                                                  }
                                                },
                                        ),
                                        if (card.worktree.isEmpty)
                                          TextButton.icon(
                                            onPressed: busy
                                                ? null
                                                : () => _worktree(card),
                                            icon: const Icon(Icons.play_arrow),
                                            label: const Text(
                                              'Create worktree',
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
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
