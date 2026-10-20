import 'dart:convert';

/// Session message and part model, ported from opencode's `MessageV2` shapes
/// (packages/core/src/session/message.ts, @opencode/schema/session-message).
///
/// The JSON form matches what the Tamtoot agent panel renders:
/// `{info: {id, role, time: {created}}, parts: [...]}`.

int _now() => DateTime.now().millisecondsSinceEpoch;

/// A tool call lifecycle state (`pending` while the provider streams the
/// call, `running` while the local tool executes, then `completed`/`error`).
class ToolState {
  ToolState({required this.status, this.input, this.output, this.error});

  /// `pending` | `running` | `completed` | `error`
  String status;
  Map<String, dynamic>? input;
  String? output;
  String? error;

  Map<String, dynamic> toJson() => {
    'status': status,
    if (input != null) 'input': input,
    if (output != null) 'output': output,
    if (error != null) 'error': error,
  };

  factory ToolState.fromJson(Map<String, dynamic> json) => ToolState(
    status: '${json['status'] ?? 'pending'}',
    input: json['input'] is Map
        ? Map<String, dynamic>.from(json['input'] as Map)
        : null,
    output: json['output'] as String?,
    error: json['error'] as String?,
  );
}

sealed class Part {
  Map<String, dynamic> toJson();

  static Part fromJson(Map<String, dynamic> json) => switch (json['type']) {
    'reasoning' => ReasoningPart('${json['text'] ?? ''}'),
    'tool' => ToolPart(
      callId: '${json['callID'] ?? ''}',
      tool: '${json['tool'] ?? ''}',
      state: ToolState.fromJson(
        json['state'] is Map
            ? Map<String, dynamic>.from(json['state'] as Map)
            : const {},
      ),
    ),
    _ => TextPart('${json['text'] ?? ''}'),
  };
}

class TextPart extends Part {
  TextPart(this.text);
  String text;
  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

class ReasoningPart extends Part {
  ReasoningPart(this.text);
  String text;
  @override
  Map<String, dynamic> toJson() => {'type': 'reasoning', 'text': text};
}

class ToolPart extends Part {
  ToolPart({required this.callId, required this.tool, required this.state});
  final String callId;
  final String tool;
  final ToolState state;
  @override
  Map<String, dynamic> toJson() => {
    'type': 'tool',
    'callID': callId,
    'tool': tool,
    'state': state.toJson(),
  };
}

/// One user or assistant message inside a session.
class ChatMessage {
  ChatMessage({required this.id, required this.role, List<Part>? parts})
    : parts = parts ?? [],
      createdMs = _now();

  final String id;
  final String role; // 'user' | 'assistant'
  final List<Part> parts;
  int createdMs;

  /// Finish reason recorded when an assistant message settles
  /// (`stop`, `length`, `tool-calls`, `error`, `aborted`).
  String? finish;

  /// Marks synthetic harness messages (continuations), mirroring opencode's
  /// `SessionEvent.Synthetic` inserts.
  bool synthetic = false;

  /// Marks harness-generated error notes (transport failures, configuration
  /// problems). Diagnostics render in the panel but are excluded from the
  /// transcript sent back to the model, so failures never amplify into
  /// subsequent requests.
  bool diagnostic = false;

  Map<String, dynamic> toJson() => {
    'info': {
      'id': id,
      'role': role,
      'time': {'created': createdMs},
      if (finish != null) 'finish': finish,
      if (synthetic) 'synthetic': true,
      if (diagnostic) 'diagnostic': true,
    },
    'parts': [for (final part in parts) part.toJson()],
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final info = json['info'] is Map
        ? Map<String, dynamic>.from(json['info'] as Map)
        : <String, dynamic>{};
    final time = info['time'];
    final message = ChatMessage(
      id: '${info['id'] ?? ''}',
      role: '${info['role'] ?? 'user'}',
      parts: [
        if (json['parts'] is List)
          for (final part in json['parts'] as List)
            if (part is Map) Part.fromJson(Map<String, dynamic>.from(part)),
      ],
    );
    if (time is Map && time['created'] is num) {
      message.createdMs = (time['created'] as num).toInt();
    }
    message.finish = info['finish'] as String?;
    message.synthetic = info['synthetic'] == true;
    message.diagnostic = info['diagnostic'] == true;
    return message;
  }

  static String encodeList(List<ChatMessage> messages) =>
      jsonEncode([for (final m in messages) m.toJson()]);

  static List<ChatMessage> decodeList(String source) => [
    for (final item in jsonDecode(source) as List)
      if (item is Map) ChatMessage.fromJson(Map<String, dynamic>.from(item)),
  ];
}
