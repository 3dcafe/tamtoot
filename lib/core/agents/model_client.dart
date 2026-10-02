import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'model_attachment.dart';
import 'model_profile.dart';

class ModelApiException implements Exception {
  const ModelApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ModelReply {
  const ModelReply(
    this.text, {
    this.note = '',
    this.usage = const {},
    this.request = const {},
  });
  final String text, note;
  final Map<String, dynamic> usage;

  /// Redacted JSON body that was POSTed to the model API (no secrets).
  final Map<String, dynamic> request;
}

/// One request per instance. Owns and closes its transport on completion/cancel.
class ModelClient {
  ModelClient({http.Client? client, this.timeout = const Duration(minutes: 2)})
    : _client = client ?? http.Client();
  final http.Client _client;
  final Duration timeout;
  final _cancelled = Completer<void>();
  bool _started = false;
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
    _client.close();
  }

  Future<ModelReply> send(
    ModelProfile profile,
    Map<String, dynamic> prompt, {
    String apiKey = '',
    List<ModelAttachment> attachments = const [],
    void Function(String delta)? onDelta,
  }) async {
    if (_started) {
      throw const ModelApiException(
        'Create a new request before sending again.',
      );
    }
    _started = true;
    var key = apiKey.trim();
    if (key.toLowerCase().startsWith('bearer ')) {
      key = key.substring(7).trim();
    }
    String redact(String text) =>
        key.isEmpty ? text : text.replaceAll(key, '[redacted]');
    try {
      if (_cancelled.isCompleted) {
        throw const ModelApiException('Request cancelled.');
      }
      profile.validate();
      final uri = profile.requestUri();
      if (key.contains('\n') || key.contains('\r')) {
        throw const ModelApiException('Invalid API key.');
      }
      try {
        ModelAttachment.validateAll(attachments);
      } on FormatException catch (e) {
        throw ModelApiException(e.message);
      }
      final body = requestBody(
        profile,
        prompt,
        stream: profile.apiFormat == 'ollama' && onDelta != null,
        attachments: attachments,
      );
      final encoded = utf8.encode(jsonEncode(body));
      final limit = attachments.isEmpty ? 2 * 1024 * 1024 : 16 * 1024 * 1024;
      if (encoded.length > limit) {
        throw ModelApiException(
          'Prompt exceeds the ${limit ~/ (1024 * 1024)} MiB request limit.',
        );
      }
      final request = http.Request('POST', uri)..followRedirects = false;
      request.headers['content-type'] = 'application/json';
      if (profile.apiFormat == 'anthropic') {
        request.headers['anthropic-version'] = '2023-06-01';
        if (key.isNotEmpty) request.headers['x-api-key'] = key;
      } else if (key.isNotEmpty) {
        request.headers['authorization'] = 'Bearer $key';
      }
      request.bodyBytes = encoded;
      final reply =
          await Future.any([
            _perform(request, profile.apiFormat, onDelta: onDelta),
            _cancelled.future.then<ModelReply>(
              (_) => throw const ModelApiException('Request cancelled.'),
            ),
          ]).timeout(
            timeout,
            onTimeout: () => throw const ModelApiException(
              'Request timed out. Retry manually if needed.',
            ),
          );
      return ModelReply(
        redact(reply.text),
        note: redact(reply.note),
        usage: reply.usage,
        request: redactAttachmentPayload(body),
      );
    } on ModelApiException catch (e) {
      var safe = redact(e.message);
      if (safe.startsWith('No text answer returned')) {
        final extra = <String>[
          if (profile.provider.trim().isNotEmpty)
            'provider: ${profile.provider.trim()}',
          if (profile.model.trim().isNotEmpty &&
              !safe.contains('model: ${profile.model.trim()}'))
            'model: ${profile.model.trim()}',
        ];
        if (extra.isNotEmpty) {
          final lines = safe.split('\n');
          final insertAt = lines.length > 1 ? 1 : lines.length;
          lines.insertAll(insertAt, extra);
          safe = lines.join('\n');
        }
      }
      throw ModelApiException(
        safe.length > 2000 ? '${safe.substring(0, 2000)}…' : safe,
      );
    } on FormatException {
      throw const ModelApiException(
        'Invalid endpoint, parameters or API response. Check the selected API format.',
      );
    } catch (_) {
      if (_cancelled.isCompleted) {
        throw const ModelApiException('Request cancelled.');
      }
      throw const ModelApiException(
        'Connection failed. Check the endpoint, network and browser CORS permissions.',
      );
    } finally {
      _client.close();
    }
  }

  static Map<String, dynamic> requestBody(
    ModelProfile p,
    Map<String, dynamic> prompt, {
    bool stream = false,
    List<ModelAttachment> attachments = const [],
  }) {
    p.validate();
    ModelAttachment.validateAll(attachments);
    final system = prompt['systemPrompt'] as String;
    final user = prompt['userPrompt'] as String;
    if (user.trim().isEmpty && attachments.isEmpty) {
      throw const ModelApiException('The user prompt is empty.');
    }
    final userText = user.trim().isEmpty && attachments.isNotEmpty
        ? 'Please inspect the attached files.'
        : user;
    return switch (p.apiFormat) {
      'ollama' => {
        'model': p.model,
        'messages': [
          if (system.isNotEmpty) {'role': 'system', 'content': system},
          {
            'role': 'user',
            'content': _ollamaUserContent(userText, attachments),
            if (attachments.any((item) => item.isImage))
              'images': [
                for (final item in attachments)
                  if (item.isImage) base64Encode(item.bytes),
              ],
          },
        ],
        'options': p.parameters,
        'stream': stream,
      },
      'responses' => {
        'store': false,
        ...p.parameters,
        'model': p.model,
        'instructions': system,
        'input': attachments.isEmpty
            ? userText
            : [
                {
                  'role': 'user',
                  'content': _responsesContent(userText, attachments),
                },
              ],
        // Tamtoot agents speak JSON actions in text; native tools are unsupported.
        'tool_choice': 'none',
        'stream': false,
      },
      'anthropic' => {
        'max_tokens': 2048,
        ...p.parameters,
        'model': p.model,
        if (system.isNotEmpty) 'system': system,
        'messages': [
          {'role': 'user', 'content': _anthropicContent(userText, attachments)},
        ],
        'tool_choice': {'type': 'none'},
        'stream': false,
      },
      _ => {
        ...p.parameters,
        'model': p.model,
        'messages': [
          if (system.isNotEmpty) {'role': 'system', 'content': system},
          {
            'role': 'user',
            'content': attachments.isEmpty
                ? userText
                : _chatCompletionsContent(userText, attachments),
          },
        ],
        // Prevent providers from answering with tool_calls instead of text JSON.
        'tool_choice': 'none',
        'stream': false,
      },
    };
  }

  /// OpenAI / STAR / ai.starimg.ru chat.completions multimodal parts.
  static List<Map<String, dynamic>> _chatCompletionsContent(
    String user,
    List<ModelAttachment> attachments,
  ) {
    final parts = <Map<String, dynamic>>[
      {'type': 'text', 'text': user},
    ];
    for (final item in attachments) {
      if (item.isImage) {
        parts.add({
          'type': 'image_url',
          'image_url': {'url': item.dataUri},
        });
        continue;
      }
      final text = item.asUtf8Text;
      if (text != null) {
        parts.add({
          'type': 'text',
          'text': 'Attached file `${item.name}`:\n```\n$text\n```',
        });
        continue;
      }
      // STAR / Bedrock-style document part (PDF, Office, …).
      parts.add({
        'type': 'file',
        'file': {
          'filename': item.name,
          'file_data': item.dataUri,
          'file_type': item.mimeType,
        },
      });
    }
    return parts;
  }

  static List<Map<String, dynamic>> _responsesContent(
    String user,
    List<ModelAttachment> attachments,
  ) {
    final parts = <Map<String, dynamic>>[
      {'type': 'input_text', 'text': user},
    ];
    for (final item in attachments) {
      if (item.isImage) {
        parts.add({'type': 'input_image', 'image_url': item.dataUri});
        continue;
      }
      final text = item.asUtf8Text;
      if (text != null) {
        parts.add({
          'type': 'input_text',
          'text': 'Attached file `${item.name}`:\n```\n$text\n```',
        });
        continue;
      }
      parts.add({
        'type': 'input_file',
        'filename': item.name,
        'file_data': item.dataUri,
      });
    }
    return parts;
  }

  static Object _anthropicContent(
    String user,
    List<ModelAttachment> attachments,
  ) {
    if (attachments.isEmpty) return user;
    final parts = <Map<String, dynamic>>[
      {'type': 'text', 'text': user},
    ];
    for (final item in attachments) {
      if (item.isImage) {
        final media = item.mimeType;
        parts.add({
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': media,
            'data': base64Encode(item.bytes),
          },
        });
        continue;
      }
      final text = item.asUtf8Text;
      if (text != null) {
        parts.add({
          'type': 'text',
          'text': 'Attached file `${item.name}`:\n```\n$text\n```',
        });
        continue;
      }
      parts.add({
        'type': 'text',
        'text':
            'Attached binary file `${item.name}` (${item.mimeType}, ${item.bytes.length} bytes). This API format cannot embed it; paste text or use an OpenAI-compatible profile.',
      });
    }
    return parts;
  }

  static String _ollamaUserContent(
    String user,
    List<ModelAttachment> attachments,
  ) {
    final buffer = StringBuffer(user);
    for (final item in attachments) {
      if (item.isImage) continue;
      final text = item.asUtf8Text;
      if (text != null) {
        buffer.write('\n\nAttached file `${item.name}`:\n```\n$text\n```');
      } else {
        buffer.write(
          '\n\nAttached binary file `${item.name}` (${item.mimeType}).',
        );
      }
    }
    return buffer.toString();
  }

  /// Drop huge base64 payloads from request snapshots shown in Agent JSON log.
  static Map<String, dynamic> redactAttachmentPayload(
    Map<String, dynamic> body,
  ) {
    dynamic scrub(dynamic value) {
      if (value is String) {
        if (value.startsWith('data:') && value.length > 120) {
          final comma = value.indexOf(',');
          final head = comma > 0 ? value.substring(0, comma + 1) : 'data:';
          return '$head[redacted ${value.length - head.length} chars]';
        }
        if (value.length > 4000 &&
            RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(value)) {
          return '[redacted base64 ${value.length} chars]';
        }
        return value;
      }
      if (value is List) return [for (final item in value) scrub(item)];
      if (value is Map) {
        return <String, dynamic>{
          for (final entry in value.entries) '${entry.key}': scrub(entry.value),
        };
      }
      return value;
    }

    return Map<String, dynamic>.from(scrub(body) as Map);
  }

  Future<ModelReply> _perform(
    http.Request request,
    String format, {
    void Function(String delta)? onDelta,
  }) async {
    final response = await _client.send(request);
    if (format == 'ollama' && onDelta != null && response.statusCode == 200) {
      return _ollamaStream(response, onDelta);
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > 4 * 1024 * 1024) {
        throw const ModelApiException('API response exceeds 4 MiB.');
      }
      bytes.addAll(chunk);
    }
    dynamic data;
    try {
      data = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      data = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final apiError = data is Map ? data['error'] : null;
      final message = apiError is Map && apiError['message'] is String
          ? apiError['message'] as String
          : '';
      final hint = switch (response.statusCode) {
        401 || 403 => 'Check the API key and model access.',
        429 => 'Rate limit or quota reached. Retry later.',
        >= 300 && < 400 =>
          'Redirects are not followed. Enter the final API endpoint.',
        _ => 'Check the model, API format and parameters.',
      };
      throw ModelApiException(
        'HTTP ${response.statusCode}: $hint${message.isEmpty ? '' : '\n$message'}',
      );
    }
    if (data is! Map<String, dynamic>) {
      throw const ModelApiException('API returned an invalid JSON object.');
    }
    if (data['error'] != null) {
      throw const ModelApiException(
        'API returned an error instead of a model answer.',
      );
    }
    try {
      return parseReply(format, data);
    } on ModelApiException catch (e) {
      if (!e.message.startsWith('No text answer returned')) rethrow;
      final choice = () {
        final choices = data['choices'];
        if (choices is List && choices.isNotEmpty) return choices.first;
        if (format == 'anthropic') return data['content'];
        if (format == 'responses') return data['output'];
        if (format == 'ollama') return data['message'];
        return data;
      }();
      throw ModelApiException(
        '${e.message}\nraw: ${_previewDiagnostic(choice, max: 900)}',
      );
    }
  }

  Future<ModelReply> _ollamaStream(
    http.StreamedResponse response,
    void Function(String delta) onDelta,
  ) async {
    final parts = <String>[];
    final usage = <String, dynamic>{};
    var size = 0;
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      size += utf8.encode(line).length;
      if (size > 4 * 1024 * 1024) {
        throw const ModelApiException('API response exceeds 4 MiB.');
      }
      if (line.trim().isEmpty) continue;
      final event = jsonDecode(line);
      if (event is! Map) continue;
      if (event['error'] is String) {
        throw ModelApiException(event['error'] as String);
      }
      final message = event['message'];
      if (message is Map && message['content'] is String) {
        final delta = message['content'] as String;
        parts.add(delta);
        onDelta(delta);
      }
      if (event['prompt_eval_count'] is num) {
        usage['input_tokens'] = event['prompt_eval_count'];
      }
      if (event['eval_count'] is num) {
        usage['output_tokens'] = event['eval_count'];
      }
    }
    if (parts.join().trim().isEmpty) {
      throw const ModelApiException('Ollama returned no text answer.');
    }
    return ModelReply(parts.join(), usage: usage);
  }

  static const _agentActions = {
    'say',
    'list_files',
    'search_files',
    'read_file',
    'read_files',
    'replace_in_file',
    'write_file',
    'mcp_call',
    'finish',
  };

  static ModelReply parseReply(String format, Map<String, dynamic> data) {
    final parts = <String>[];
    String note = '';
    final hints = <String>[];
    String? finishReason;
    dynamic rawContent;
    dynamic rawToolCalls;
    String? responseModel;

    void content(dynamic value) {
      rawContent ??= value;
      if (value is String) {
        if (value.trim().isNotEmpty) parts.add(value);
        return;
      }
      if (value is List) {
        for (final block in value) {
          if (block is! Map) continue;
          final type = block['type'];
          if ({'text', 'output_text'}.contains(type) &&
              block['text'] is String &&
              (block['text'] as String).trim().isNotEmpty) {
            parts.add(block['text'] as String);
          }
          if (type == 'refusal' &&
              block['refusal'] is String &&
              (block['refusal'] as String).trim().isNotEmpty) {
            parts.add(block['refusal'] as String);
          }
          if (type == 'tool_use' || type == 'function_call') {
            final name = '${block['name'] ?? block['call_id'] ?? type}';
            hints.add('native tool: $name');
            rawToolCalls ??= [];
            if (rawToolCalls is List) {
              (rawToolCalls as List).add(block);
            }
          }
        }
      }
    }

    String? reasoningText;

    void noteToolCalls(dynamic raw) {
      if (raw == null) return;
      rawToolCalls ??= raw;
      if (raw is! List || raw.isEmpty) return;
      final names = <String>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final fn = item['function'];
        final name = fn is Map
            ? fn['name']
            : item['name'] ?? item['type'] ?? 'tool';
        names.add('$name');
      }
      if (names.isNotEmpty) {
        hints.add('tool_calls: ${names.join(', ')}');
      }
    }

    if (data['model'] is String) {
      responseModel = data['model'] as String;
    }

    if (format == 'ollama') {
      final message = data['message'];
      if (message is Map) {
        content(message['content']);
        noteToolCalls(message['tool_calls']);
      }
      if (data['prompt_eval_count'] is num) {
        data['usage'] = {
          'input_tokens': data['prompt_eval_count'],
          'output_tokens': data['eval_count'],
        };
      }
    } else if (format == 'responses') {
      final output = data['output'];
      if (output is List) {
        for (final item in output) {
          if (item is! Map) continue;
          if (item['type'] == 'message') {
            content(item['content']);
          }
          if (item['type'] == 'function_call' || item['type'] == 'tool_call') {
            hints.add('native tool: ${item['name'] ?? item['type']}');
            rawToolCalls ??= [];
            if (rawToolCalls is List) {
              (rawToolCalls as List).add(item);
            }
          }
        }
      }
      if (data['status'] == 'incomplete') {
        note = 'Incomplete response; check the output token limit.';
      }
      if (data['status'] == 'failed' || data['status'] == 'cancelled') {
        throw const ModelApiException('Model response did not complete.');
      }
    } else if (format == 'anthropic') {
      content(data['content']);
      if (data['stop_reason'] == 'max_tokens') {
        note = 'Output token limit reached; answer may be incomplete.';
      }
      if (data['stop_reason'] == 'tool_use') {
        finishReason = 'tool_use';
        hints.add('stop_reason: tool_use');
      }
    } else {
      final choices = data['choices'];
      if (choices is List && choices.isNotEmpty && choices.first is Map) {
        final first = choices.first as Map;
        final message = first['message'];
        if (message is Map) {
          content(message['content']);
          if (message['refusal'] is String &&
              (message['refusal'] as String).trim().isNotEmpty) {
            parts.add(message['refusal'] as String);
          }
          final reasoning = message['reasoning_content'] ?? message['reasoning'];
          if (reasoning is String && reasoning.trim().isNotEmpty) {
            reasoningText = reasoning;
            hints.add('reasoning_content: ${reasoning.length} chars');
          }
          // Anthropic-style content blocks may also carry thinking.
          final blocks = message['content'];
          if (blocks is List) {
            for (final block in blocks) {
              if (block is! Map) continue;
              if ({'reasoning', 'thinking', 'reasoning_text'}.contains(
                    block['type'],
                  ) &&
                  block['text'] is String &&
                  (block['text'] as String).trim().isNotEmpty) {
                reasoningText ??= block['text'] as String;
              }
            }
          }
          noteToolCalls(message['tool_calls']);
        }
        final finish = first['finish_reason'];
        if (finish is String) finishReason = finish;
        if (finish == 'length') {
          note = 'Output token limit reached; answer may be incomplete.';
        } else if (finish != null && finish != 'stop') {
          hints.add('finish_reason: $finish');
        }
      }
    }

    // Providers sometimes ignore tool_choice:none and return native tool_calls.
    // Convert a known Tamtoot action into the text JSON the agent engine expects.
    if (parts.join().trim().isEmpty) {
      final converted = _actionFromNativeTools(rawToolCalls);
      if (converted != null) {
        parts.add(converted);
        note = note.isEmpty
            ? 'Converted native tool_calls into a JSON action.'
            : '$note Converted native tool_calls into a JSON action.';
      }
    }

    // Thinking models may put a JSON action only inside reasoning_content, or
    // burn the whole budget on reasoning and leave content empty.
    if (parts.join().trim().isEmpty && reasoningText != null) {
      final embedded = _embeddedJsonAction(reasoningText);
      if (embedded != null) {
        parts.add(embedded);
        note = note.isEmpty
            ? 'Extracted JSON action from reasoning_content.'
            : '$note Extracted JSON action from reasoning_content.';
      }
    }

    if (parts.join().trim().isEmpty) {
      throw ModelApiException(
        _emptyAnswerMessage(
          finishReason: finishReason,
          content: rawContent,
          toolCalls: rawToolCalls,
          model: responseModel,
          hints: hints,
          reasoning: reasoningText,
        ),
      );
    }
    // If content is prose/reasoning but embeds a JSON action, prefer the action.
    if (!_looksLikeJsonAction(parts.join('\n'))) {
      final fromParts = _embeddedJsonAction(parts.join('\n'));
      final fromReasoning =
          reasoningText == null ? null : _embeddedJsonAction(reasoningText);
      final embedded = fromParts ?? fromReasoning;
      if (embedded != null) {
        return ModelReply(
          embedded,
          note: note.isEmpty
              ? 'Extracted embedded JSON action.'
              : '$note Extracted embedded JSON action.',
          usage: _usageFrom(data),
        );
      }
    }
    return ModelReply(parts.join('\n'), note: note, usage: _usageFrom(data));
  }

  static Map<String, dynamic> _usageFrom(Map<String, dynamic> data) {
    final rawUsage = data['usage'];
    final usage = <String, dynamic>{};
    if (rawUsage is Map) {
      for (final key in [
        'input_tokens',
        'output_tokens',
        'prompt_tokens',
        'completion_tokens',
        'total_tokens',
      ]) {
        if (rawUsage[key] is num) usage[key] = rawUsage[key];
      }
    }
    return usage;
  }

  static bool _looksLikeJsonAction(String text) {
    final trimmed = text.trim();
    return trimmed.startsWith('{') && trimmed.contains('"action"');
  }

  /// Pulls the first complete {"action":...} object out of free-form model text.
  static String? _embeddedJsonAction(String text) {
    final marker = text.indexOf('"action"');
    if (marker < 0) return null;
    final start = text.lastIndexOf('{', marker);
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
        continue;
      }
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) {
          final candidate = text.substring(start, i + 1);
          try {
            final decoded = jsonDecode(candidate);
            if (decoded is Map &&
                decoded['action'] is String &&
                _agentActions.contains(decoded['action'])) {
              return candidate;
            }
          } catch (_) {
            return null;
          }
          return null;
        }
      }
    }
    return null;
  }

  /// Maps OpenAI/Anthropic-style tool calls onto Tamtoot's one-JSON-action protocol.
  static String? _actionFromNativeTools(dynamic raw) {
    if (raw is! List || raw.isEmpty) return null;
    for (final item in raw) {
      if (item is! Map) continue;
      String? name;
      dynamic arguments;
      final fn = item['function'];
      if (fn is Map) {
        name = fn['name'] is String ? fn['name'] as String : null;
        arguments = fn['arguments'] ?? fn['parameters'];
      } else {
        name = item['name'] is String ? item['name'] as String : null;
        arguments = item['input'] ?? item['arguments'] ?? item['parameters'];
      }
      if (name == null || !_agentActions.contains(name)) continue;
      Map<String, dynamic> args;
      if (arguments is Map) {
        args = Map<String, dynamic>.from(arguments);
      } else if (arguments is String && arguments.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(arguments);
          if (decoded is! Map) continue;
          args = Map<String, dynamic>.from(decoded);
        } catch (_) {
          continue;
        }
      } else {
        args = {};
      }
      args.remove('action');
      return jsonEncode({'action': name, ...args});
    }
    return null;
  }

  static String _emptyAnswerMessage({
    required String? finishReason,
    required dynamic content,
    required dynamic toolCalls,
    required String? model,
    required List<String> hints,
    String? reasoning,
  }) {
    final lines = <String>[
      'No text answer returned.',
      if (finishReason != null) 'finish_reason: $finishReason',
      'content: ${_previewDiagnostic(content)}',
      if (toolCalls != null) 'tool_calls: ${_previewDiagnostic(toolCalls)}',
      if (reasoning != null)
        'reasoning_content: ${_previewDiagnostic(reasoning, max: 400)}',
      if (model != null && model.isNotEmpty) 'model: $model',
      if (hints.isNotEmpty) 'hints: ${hints.join('; ')}',
    ];
    if (reasoning != null && reasoning.trim().isNotEmpty) {
      lines.add(
        'The model spent its output budget on reasoning_content and returned '
        'no JSON action in message.content. Reply with ONLY one short JSON '
        'object (for example {"action":"replace_in_file",...}). '
        'No chain-of-thought outside JSON.',
      );
    } else if (finishReason == 'length') {
      lines.add(
        'The model hit the output token limit and returned no usable text. '
        'Reply again with one short JSON action only '
        '(for example {"action":"read_file","path":"..."}).',
      );
    } else if (toolCalls != null) {
      lines.add(
        'Tamtoot needs a plain-text JSON action, not native tool calls. '
        'Retry with a single JSON object in message content.',
      );
    } else {
      lines.add(
        'Empty model content. Retry with one short JSON action, '
        'or inspect the raw response in Agent logs.',
      );
    }
    return lines.join('\n');
  }

  static String _previewDiagnostic(dynamic value, {int max = 600}) {
    if (value == null) return 'null';
    late final String text;
    try {
      text = value is String ? value : jsonEncode(value);
    } catch (_) {
      text = '$value';
    }
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return '""';
    if (compact.length <= max) return compact;
    return '${compact.substring(0, max)}…';
  }
}
