import 'dart:convert';

import '../git/git_store.dart';
import 'agent_engine.dart';

/// Project-local conversation history for the embedded agent.
///
/// Request payloads in [AgentEvent.data] are deliberately not persisted: they
/// can contain large source snapshots and API metadata. The visible transcript
/// is enough to resume the conversation without growing `.tamtoot` unchecked.
final class AgentHistoryStore {
  AgentHistoryStore(this.files);

  final GitRepositoryStore files;

  static const path = '.tamtoot/agents/chat_history.json';
  static const maxEvents = 250;
  static const maxEventCharacters = 12000;

  Future<List<AgentEvent>> load() async {
    if (!await files.exists(path)) return [];
    try {
      final decoded = jsonDecode(await files.readText(path));
      if (decoded is! Map || decoded['events'] is! List) return [];
      final result = <AgentEvent>[];
      for (final value in (decoded['events'] as List).take(maxEvents)) {
        if (value is! Map) continue;
        final type = value['type'];
        final text = value['text'];
        final timestamp = value['ts'];
        if (type is! String || text is! String || timestamp is! int) continue;
        result.add(
          AgentEvent(
            type,
            text,
            at: DateTime.fromMillisecondsSinceEpoch(timestamp),
          ),
        );
      }
      return result;
    } on Object {
      // A damaged local history must never prevent the project from opening.
      return [];
    }
  }

  Future<void> save(List<AgentEvent> events) async {
    if (events.isEmpty) {
      await clear();
      return;
    }
    final recent = events.length <= maxEvents
        ? events
        : events.sublist(events.length - maxEvents);
    await files.writeText(
      path,
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'events': [
          for (final event in recent)
            {
              'type': event.type,
              'text': event.text.length <= maxEventCharacters
                  ? event.text
                  : '${event.text.substring(0, maxEventCharacters)}\n…',
              'ts': event.at.millisecondsSinceEpoch,
            },
        ],
      }),
    );
  }

  Future<void> clear() async {
    if (await files.exists(path)) await files.delete(path);
  }
}
