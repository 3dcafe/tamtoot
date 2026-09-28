import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'model_profile.dart';

class ModelApiException implements Exception {
  const ModelApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ModelReply {
  const ModelReply(this.text, {this.note = '', this.usage = const {}});
  final String text, note;
  final Map<String, dynamic> usage;
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
    void Function(String delta)? onDelta,
  }) async {
    if (_started) {
      throw const ModelApiException(
        'Create a new request before sending again.',
      );
    }
    _started = true;
    final key = apiKey.trim();
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
      final body = requestBody(
        profile,
        prompt,
        stream: profile.apiFormat == 'ollama' && onDelta != null,
      );
      final encoded = utf8.encode(jsonEncode(body));
      if (encoded.length > 2 * 1024 * 1024) {
        throw const ModelApiException(
          'Prompt exceeds the 2 MiB request limit.',
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
  }) {
    p.validate();
    final system = prompt['systemPrompt'] as String;
    final user = prompt['userPrompt'] as String;
    if (user.trim().isEmpty) {
      throw const ModelApiException('The user prompt is empty.');
    }
    return switch (p.apiFormat) {
      'ollama' => {
        'model': p.model,
        'messages': [
          if (system.isNotEmpty) {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
        'options': p.parameters,
        'stream': stream,
      },
      'responses' => {
        'store': false,
        ...p.parameters,
        'model': p.model,
        'instructions': system,
        'input': user,
        'stream': false,
      },
      'anthropic' => {
        'max_tokens': 4096,
        ...p.parameters,
        'model': p.model,
        if (system.isNotEmpty) 'system': system,
        'messages': [
          {'role': 'user', 'content': user},
        ],
        'stream': false,
      },
      _ => {
        ...p.parameters,
        'model': p.model,
        'messages': [
          if (system.isNotEmpty) {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
        'stream': false,
      },
    };
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
    void content(dynamic value) {
      if (value is String) {
        parts.add(value);
        return;
      }
      if (value is List) {
        for (final block in value) {
          if (block is! Map) continue;
          if ({'text', 'output_text'}.contains(block['type']) &&
              block['text'] is String) {
            parts.add(block['text'] as String);
          }
          if (block['type'] == 'refusal' && block['refusal'] is String) {
            parts.add(block['refusal'] as String);
          }
        }
      }
    }

    if (format == 'ollama') {
      final message = data['message'];
      if (message is Map) content(message['content']);
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
          if (item is Map && item['type'] == 'message') {
            content(item['content']);
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
        }
        if (first['finish_reason'] == 'length') {
          note = 'Output token limit reached; answer may be incomplete.';
        }
      }
    }
    if (parts.join().trim().isEmpty) {
      throw const ModelApiException(
        'No text answer returned. Tool calls and non-text outputs are not supported.',
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
