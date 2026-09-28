import 'dart:convert';

import '../git/git_store.dart';

enum KanbanStatus { todo, inProgress, review, done }

class KanbanCard {
  const KanbanCard({
    required this.id,
    required this.title,
    required this.description,
    this.status = KanbanStatus.todo,
    this.dependencies = const [],
    this.profileId = '',
    this.worktree = '',
    this.lastOutput = '',
    this.autoCommit = false,
    this.autoPr = false,
  });

  final String id, title, description, profileId, worktree, lastOutput;
  final KanbanStatus status;
  final List<String> dependencies;
  final bool autoCommit, autoPr;

  KanbanCard copyWith({
    KanbanStatus? status,
    String? worktree,
    String? lastOutput,
  }) => KanbanCard(
    id: id,
    title: title,
    description: description,
    status: status ?? this.status,
    dependencies: dependencies,
    profileId: profileId,
    worktree: worktree ?? this.worktree,
    lastOutput: lastOutput ?? this.lastOutput,
    autoCommit: autoCommit,
    autoPr: autoPr,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'status': status.name,
    'dependencies': dependencies,
    'profileId': profileId,
    'worktree': worktree,
    'lastOutput': lastOutput,
    'autoCommit': autoCommit,
    'autoPr': autoPr,
  };

  factory KanbanCard.parse(dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Kanban card must be an object.');
    }
    String text(String key) => value[key] is String ? value[key] as String : '';
    final id = text('id');
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(id)) {
      throw const FormatException('Invalid Kanban card ID.');
    }
    final title = text('title');
    if (title.trim().isEmpty) {
      throw const FormatException('Kanban title is required.');
    }
    final rawDependencies = value['dependencies'] ?? const [];
    if (rawDependencies is! List ||
        rawDependencies.any((item) => item is! String)) {
      throw const FormatException('Invalid Kanban dependencies.');
    }
    return KanbanCard(
      id: id,
      title: title,
      description: text('description'),
      status:
          KanbanStatus.values
              .where((item) => item.name == value['status'])
              .firstOrNull ??
          KanbanStatus.todo,
      dependencies: rawDependencies.cast<String>(),
      profileId: text('profileId'),
      worktree: text('worktree'),
      lastOutput: text('lastOutput'),
      autoCommit: value['autoCommit'] == true,
      autoPr: value['autoPr'] == true,
    );
  }
}

class KanbanBoard {
  const KanbanBoard(this.cards);
  final List<KanbanCard> cards;

  String encode() => const JsonEncoder.withIndent('  ').convert({
    'schemaVersion': 1,
    'cards': cards.map((card) => card.toJson()).toList(),
  });

  factory KanbanBoard.parse(String source) {
    final data = jsonDecode(source);
    if (data is! Map<String, dynamic> ||
        data['schemaVersion'] != 1 ||
        data['cards'] is! List) {
      throw const FormatException('Unsupported Kanban schema.');
    }
    final cards = (data['cards'] as List).map(KanbanCard.parse).toList();
    final ids = cards.map((card) => card.id).toSet();
    if (ids.length != cards.length) {
      throw const FormatException('Duplicate Kanban card ID.');
    }
    for (final card in cards) {
      if (card.dependencies.contains(card.id) ||
          card.dependencies.any((id) => !ids.contains(id))) {
        throw FormatException('Invalid dependency for ${card.id}.');
      }
    }
    return KanbanBoard(cards);
  }

  bool ready(KanbanCard card) {
    final done = cards
        .where((item) => item.status == KanbanStatus.done)
        .map((item) => item.id)
        .toSet();
    return card.dependencies.every(done.contains);
  }
}

class KanbanStore {
  KanbanStore(this.files);
  final GitRepositoryStore files;
  static const path = '.tamtoot/agents/kanban.json';
  String? original;

  Future<KanbanBoard> load() async {
    await files.validateRegularFilePath(path);
    original = await files.exists(path) ? await files.readText(path) : null;
    return original == null
        ? const KanbanBoard([])
        : KanbanBoard.parse(original!);
  }

  Future<void> save(KanbanBoard board) async {
    final current = await files.exists(path)
        ? await files.readText(path)
        : null;
    if (current != original) {
      throw StateError('Kanban changed outside the dialog. Reopen it.');
    }
    final text = board.encode();
    await files.writeText(path, text);
    original = text;
  }
}
