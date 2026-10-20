import 'dart:convert';
import 'dart:io';

import 'message.dart';

/// Durable session state, ported from opencode's session schema
/// (packages/core/src/session/schema.ts + store.ts). Persisted as one JSON
/// file per session under `.tamtoot/opencode/sessions/`.

class AgentSession {
  AgentSession({required this.id, required this.title, List<ChatMessage>? messages})
    : messages = messages ?? [],
      createdMs = DateTime.now().millisecondsSinceEpoch;

  final String id;
  String title;
  final List<ChatMessage> messages;
  int createdMs;

  Map<String, dynamic> summaryJson() => {
    'id': id,
    'title': title,
    'time': {'created': createdMs},
  };

  Map<String, dynamic> toJson() => {
    ...summaryJson(),
    'messages': [for (final message in messages) message.toJson()],
  };

  factory AgentSession.fromJson(Map<String, dynamic> json) {
    final session = AgentSession(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? 'Session'}',
      messages: [
        if (json['messages'] is List)
          for (final item in json['messages'] as List)
            if (item is Map)
              ChatMessage.fromJson(Map<String, dynamic>.from(item)),
      ],
    );
    final time = json['time'];
    if (time is Map && time['created'] is num) {
      session.createdMs = (time['created'] as num).toInt();
    }
    return session;
  }
}

class SessionStore {
  SessionStore(this.root);

  final String root;
  final Map<String, AgentSession> _sessions = {};
  var _loaded = false;

  Directory get _dir {
    final sep = Platform.pathSeparator;
    return Directory(
      [root, '.tamtoot', 'opencode', 'sessions'].join(sep),
    );
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final dir = _dir;
    if (!dir.existsSync()) return;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final data = jsonDecode(await entity.readAsString());
        if (data is! Map) continue;
        final session = AgentSession.fromJson(
          Map<String, dynamic>.from(data),
        );
        if (session.id.isNotEmpty) _sessions[session.id] = session;
      } catch (_) {
        // A corrupt session file is skipped, never fatal.
      }
    }
  }

  Future<List<AgentSession>> list() async {
    await _ensureLoaded();
    final sessions = _sessions.values.toList()
      ..sort((a, b) => b.createdMs.compareTo(a.createdMs));
    return sessions;
  }

  Future<AgentSession> create({String? title}) async {
    await _ensureLoaded();
    final id = 'ses_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final session = AgentSession(id: id, title: title ?? 'Session');
    _sessions[id] = session;
    await persist(session);
    return session;
  }

  Future<AgentSession?> get(String id) async {
    await _ensureLoaded();
    return _sessions[id];
  }

  Future<void> delete(String id) async {
    await _ensureLoaded();
    _sessions.remove(id);
    final sep = Platform.pathSeparator;
    final file = File('${_dir.path}$sep$id.json');
    if (file.existsSync()) await file.delete();
  }

  Future<void> persist(AgentSession session) async {
    final dir = _dir;
    await dir.create(recursive: true);
    final sep = Platform.pathSeparator;
    await File('${dir.path}$sep${session.id}.json').writeAsString(
      jsonEncode(session.toJson()),
    );
  }
}
