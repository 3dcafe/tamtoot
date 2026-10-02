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
      final safe = redact(e.message);
      throw ModelApiException(
        safe.length > 1000 ? '${safe.substring(0, 1000)}…' : safe,
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
        'max_tokens': 1200,
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
    return parseReply(format, data);
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

  static ModelReply parseReply(String format, Map<String, dynamic> data) {
    final parts = <String>[];
    String note = '';
    final hints = <String>[];
    void content(dynamic value) {
      if (value is String) {
        parts.add(value);
        return;
      }
      if (value is List) {
        for (final block in value) {
          if (block is! Map) continue;
          final type = block['type'];
          if ({'text', 'output_text'}.contains(type) &&
              block['text'] is String) {
            parts.add(block['text'] as String);
          }
          if (type == 'refusal' && block['refusal'] is String) {
            parts.add(block['refusal'] as String);
          }
          // Some providers put the answer in reasoning / thinking fields.
          if (block['text'] is String &&
              {'reasoning', 'thinking', 'reasoning_text'}.contains(type)) {
            // Keep as fallback only; prefer primary text parts.
            if (parts.isEmpty) parts.add(block['text'] as String);
          }
          if (type == 'tool_use' || type == 'function_call') {
            final name = block['name'] ?? block['call_id'] ?? type;
            hints.add('native tool: $name');
          }
        }
      }
    }

    void noteToolCalls(dynamic raw) {
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
        hints.add('stop_reason: tool_use');
      }
    } else {
      final choices = data['choices'];
      if (choices is List && choices.isNotEmpty && choices.first is Map) {
        final first = choices.first as Map;
        final message = first['message'];
        if (message is Map) {
          content(message['content']);
          if (message['refusal'] is String) {
            parts.add(message['refusal'] as String);
          }
          // Some OpenAI-compatible hosts put text here when content is null.
          if (parts.isEmpty && message['reasoning_content'] is String) {
            parts.add(message['reasoning_content'] as String);
          }
          noteToolCalls(message['tool_calls']);
        }
        final finish = first['finish_reason'];
        if (finish == 'length') {
          note = 'Output token limit reached; answer may be incomplete.';
        } else if (finish != null && finish != 'stop') {
          hints.add('finish_reason: $finish');
        }
      }
    }
    if (parts.join().trim().isEmpty) {
      final detail = hints.isEmpty ? '' : ' (${hints.join('; ')})';
      throw ModelApiException(
        'No text answer returned$detail. '
        'Tamtoot needs a plain-text JSON action, not native tool calls. '
        'Retry, or check the model response in Agent logs.',
      );
    }
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
    return ModelReply(parts.join('\n'), note: note, usage: usage);
  }
}
