import 'dart:convert';
import 'model_client.dart';

/// Transport state for the existing executor. It never executes model output.
class NativeToolInvocation {
  NativeToolInvocation(this.id, this.call);
  final String id;
  final ModelToolCall call;
}

class NativeToolSession {
  NativeToolSession(this.system, String context, this.retainedContext)
    : _messages = [
        {'role': 'user', 'content': context},
      ];
  final String system, retainedContext;
  final List<Map<String, dynamic>> _messages;
  final List<NativeToolInvocation> pending = [];
  final Set<String> _ids = {};
  final List<String> _summary = [];
  int _sequence = 0;

  List<Map<String, dynamic>> messages(String format) {
    _compact();
    return [
      {
        'role': 'system',
        'content':
            '$system${_summary.isEmpty ? '' : '\nEarlier host outcomes:\n${_summary.join('\n')}'}',
      },
      for (final entry in _messages)
        if (format != 'ollama')
          {
            for (final e in entry.entries)
              if (!(entry['role'] == 'tool' && e.key == 'name')) e.key: e.value,
          }
        else if (entry['role'] == 'tool')
          {
            'role': 'tool',
            'tool_name': entry['name'],
            'content': entry['content'],
          }
        else if (entry['tool_calls'] is List)
          {
            'role': 'assistant',
            'content': entry['content'],
            'tool_calls': [
              for (final call in entry['tool_calls'] as List)
                {
                  'id': call['id'],
                  'type': 'function',
                  'function': {
                    'name': call['function']['name'],
                    'arguments': _arguments(call['function']['arguments']),
                  },
                },
            ],
          }
        else
          Map<String, dynamic>.from(entry),
    ];
  }

  static Object? _arguments(Object? value) {
    if (value is String) {
      try {
        return jsonDecode(value);
      } catch (_) {}
    }
    return value;
  }

  void accept(ModelReply reply) {
    final calls = <Map<String, dynamic>>[];
    for (final call in reply.toolCalls) {
      final id = call.id ?? 'tamtoot_${++_sequence}';
      if (!_ids.add(id)) {
        throw const ModelApiException(
          'Native protocol stopped: duplicate tool-call ID.',
        );
      }
      pending.add(NativeToolInvocation(id, call));
      calls.add({
        'id': id,
        'type': 'function',
        'function': {
          'name': call.name,
          'arguments': call.arguments is String
              ? call.arguments
              : jsonEncode(call.arguments),
        },
      });
    }
    _messages[0] = {'role': 'user', 'content': retainedContext};
    _messages.add({
      'role': 'assistant',
      'content': reply.text,
      if (calls.isNotEmpty) 'tool_calls': calls,
    });
  }

  void hostNote(String note) =>
      _messages.add({'role': 'user', 'content': note});

  void requestExplicitTool([String outstanding = '']) => _messages.add({
    'role': 'user',
    'content':
        'No tool executed. ${outstanding.isEmpty ? '' : '$outstanding '}'
        'Continue the task now using the available tools; do not ask the user '
        'for permission or confirmation. Call finish only with the actual '
        'outcome and unresolved requirements. Do not invent tool results.',
  });

  void result(NativeToolInvocation invocation, String result) {
    _messages.add({
      'role': 'tool',
      'tool_call_id': invocation.id,
      'name': invocation.call.name,
      'content': result,
    });
  }

  void _compact() {
    // Drop only complete assistant/tool groups; never orphan a call/result ID.
    while (jsonEncode(_messages).length > 28000 && _messages.length > 3) {
      var end = 2;
      while (end < _messages.length && _messages[end]['role'] == 'tool') {
        end++;
      }
      if (end >= _messages.length || pending.isNotEmpty) break;
      for (final entry in _messages.sublist(1, end)) {
        if (entry['role'] == 'tool') {
          final data = jsonDecode(entry['content'] as String);
          final detail = (data['error'] ?? data['result'] ?? '')
              .toString()
              .split('\n')
              .take(3)
              .join(' ');
          final bounded = detail.length > 240
              ? detail.substring(0, 240)
              : detail;
          _summary.add(
            '${entry['name']} ${data['paths'] ?? ''}: ${data['ok'] == true ? 'completed' : 'failed/blocked'}; $bounded',
          );
        }
      }
      if (_summary.length > 12) _summary.removeRange(0, _summary.length - 12);
      _messages.removeRange(1, end);
    }
  }
}
