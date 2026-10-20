import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Canonical LLM request/response model and streaming protocols, ported from
/// opencode's `packages/ai` (llm.ts, protocols/openai-compatible-chat.ts and
/// the Ollama native `/api/chat` dialect).
///
/// Two wire dialects are supported:
/// - `ollama`: native Ollama `/api/chat` (ndjson stream, `think` parameter).
/// - `openai-compatible`: OpenAI chat-completions SSE on any base URL.

class LlmException implements Exception {
  const LlmException(
    this.message, {
    this.retryable = false,
    this.isTimeout = false,
    this.isContextOverflow = false,
    this.retryAfterMs,
  });

  final String message;

  /// Transport failures, rate limits and 5xx responses are retryable,
  /// mirroring `isRetryable` in packages/ai.
  final bool retryable;
  final bool isTimeout;

  /// Context-window overflow; opencode compacts here, this port fails the
  /// step with a clear message instead.
  final bool isContextOverflow;

  /// Provider-requested delay (Retry-After), bounded by the retry policy.
  final int? retryAfterMs;

  @override
  String toString() => message;
}

class LlmToolCall {
  LlmToolCall({required this.id, required this.name, required this.arguments});
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
}

/// Canonical conversation message sent to a provider.
class LlmMessage {
  LlmMessage({
    required this.role,
    this.text = '',
    this.toolCalls = const [],
    this.toolCallId,
    this.toolName,
  });

  /// `system` | `user` | `assistant` | `tool`
  final String role;
  final String text;
  final List<LlmToolCall> toolCalls;

  /// Set on `tool` role messages: the call this message answers.
  final String? toolCallId;
  final String? toolName;
}

class LlmToolDef {
  LlmToolDef({
    required this.name,
    required this.description,
    required this.parameters,
  });
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  Map<String, dynamic> toJson() => {
    'type': 'function',
    'function': {'name': name, 'description': description, 'parameters': parameters},
  };
}

sealed class LlmEvent {}

class LlmTextDelta extends LlmEvent {
  LlmTextDelta(this.text);
  final String text;
}

class LlmReasoningDelta extends LlmEvent {
  LlmReasoningDelta(this.text);
  final String text;
}

class LlmToolCallEvent extends LlmEvent {
  LlmToolCallEvent(this.call);
  final LlmToolCall call;
}

class LlmFinish extends LlmEvent {
  LlmFinish(this.reason, {this.inputTokens, this.outputTokens});

  /// `stop` | `length` | `tool-calls` | `unknown`
  final String reason;
  final int? inputTokens;
  final int? outputTokens;
}

/// How a provider is reached. Parsed from `.tamtoot/opencode.json`.
class ProviderConfig {
  ProviderConfig({
    required this.id,
    required this.type,
    required this.baseURL,
    this.apiKey,
    this.think,
    this.models = const [],
    this.name,
  });

  final String id;

  /// `ollama` | `openai-compatible`
  final String type;
  final String baseURL;
  final String? apiKey;

  /// Ollama `think` parameter; `false` disables reasoning output (the
  /// validated default for Qwen3 coding sessions), `true` enables it,
  /// `null` leaves the provider default.
  final bool? think;

  /// Statically configured models (openai-compatible). Ollama models are
  /// discovered live through `/api/tags`.
  final List<String> models;
  final String? name;

  String get displayName => name ?? (type == 'ollama' ? 'Ollama' : id);

  factory ProviderConfig.fromJson(String id, Map<String, dynamic> json) =>
      ProviderConfig(
        id: id,
        type: json['type'] == 'openai-compatible'
            ? 'openai-compatible'
            : 'ollama',
        baseURL: '${json['baseURL'] ?? json['baseUrl'] ?? _defaultBase(id)}',
        apiKey: json['apiKey'] as String?,
        think: json['think'] is bool ? json['think'] as bool : false,
        models: [
          if (json['models'] is List)
            for (final m in json['models'] as List) '$m',
        ],
        name: json['name'] as String?,
      );

  static String _defaultBase(String id) =>
      id == 'ollama' ? 'http://127.0.0.1:11434' : 'http://127.0.0.1:8080/v1';
}

class LlmRequest {
  LlmRequest({
    required this.provider,
    required this.model,
    required this.messages,
    this.tools = const [],
    this.toolChoice = 'auto',
  });

  final ProviderConfig provider;
  final String model;
  final List<LlmMessage> messages;
  final List<LlmToolDef> tools;

  /// `auto` | `none` (`none` is used after the max-steps boundary, ported
  /// from opencode's step-limit handling).
  final String toolChoice;
}

/// Short, sanitized error text for UI and history: never includes the
/// offending value (ArgumentError's toString dumps it — that is how a full
/// serialized request flooded the chat). Bounded to 500 characters.
String briefError(Object error) {
  final String text;
  if (error is LlmException) {
    text = error.message;
  } else if (error is ArgumentError) {
    text = '${error.name == null ? '' : '${error.name}: '}${error.message}';
  } else {
    text = '$error';
  }
  return text.length > 500 ? '${text.substring(0, 500)}…' : text;
}

/// Streaming LLM client over `dart:io` HTTP.
class LlmClient {
  LlmClient({HttpClient? httpClient})
    : _http = httpClient ?? (HttpClient()..connectionTimeout = const Duration(seconds: 30));

  final HttpClient _http;

  Stream<LlmEvent> stream(LlmRequest request) {
    final controller = StreamController<LlmEvent>();
    () async {
      try {
        if (request.provider.type == 'ollama') {
          await _streamOllama(request, controller);
        } else {
          await _streamOpenAiCompatible(request, controller);
        }
        await controller.close();
      } on LlmException catch (e) {
        controller.addError(e);
        await controller.close();
      } catch (e) {
        controller.addError(_classifyTransport(e));
        await controller.close();
      }
    }();
    return controller.stream;
  }

  LlmException _classifyTransport(Object error) {
    if (error is SocketException ||
        error is HandshakeException ||
        error is HttpException) {
      return LlmException(
        'Provider connection failed: ${briefError(error)}',
        retryable: true,
      );
    }
    if (error is TimeoutException) {
      return LlmException(
        'Provider request timed out: ${briefError(error)}',
        retryable: true,
        isTimeout: true,
      );
    }
    return LlmException(briefError(error));
  }

  Future<HttpClientResponse> _post(Uri url, Map<String, dynamic> body, {String? apiKey}) async {
    final request = await _http.postUrl(url);
    request.headers.contentType = ContentType.json;
    if (apiKey != null && apiKey.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    }
    // Send explicit UTF-8 bytes: dart:io's request.write(String) encodes
    // with Latin-1 by default and throws "Contains invalid characters" on
    // any Cyrillic or CJK text (root cause of the transport failure).
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(
      const Duration(minutes: 5),
      onTimeout: () => throw const LlmException(
        'Provider request timed out.',
        retryable: true,
        isTimeout: true,
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final bodyText = await utf8.decoder.bind(response).join();
      throw _httpError(response.statusCode, bodyText, response.headers);
    }
    return response;
  }

  LlmException _httpError(int status, String body, HttpHeaders headers) {
    final short = body.length > 400 ? body.substring(0, 400) : body;
    final lower = body.toLowerCase();
    final overflow =
        status == 413 ||
        lower.contains('context length') ||
        lower.contains('context window') ||
        lower.contains('too many tokens') ||
        lower.contains('maximum context');
    if (overflow) {
      return LlmException(
        'The request exceeded the model context window. Shorten the '
        'conversation or start a new session. (HTTP $status)',
        isContextOverflow: true,
      );
    }
    if (status == 429) {
      final retryAfter = headers.value('retry-after');
      final seconds = retryAfter == null ? null : int.tryParse(retryAfter);
      return LlmException(
        'Provider rate limit (HTTP 429): $short',
        retryable: true,
        retryAfterMs: seconds == null ? null : seconds * 1000,
      );
    }
    if (status >= 500) {
      return LlmException('Provider error (HTTP $status): $short', retryable: true);
    }
    return LlmException('Provider rejected the request (HTTP $status): $short');
  }

  // ------------------------------------------------------------------ ollama

  List<Map<String, dynamic>> _ollamaMessages(LlmRequest request) => [
    for (final message in request.messages)
      if (message.role == 'tool')
        {
          'role': 'tool',
          if (message.toolName != null) 'name': message.toolName,
          'content': message.text,
        }
      else if (message.role == 'assistant' && message.toolCalls.isNotEmpty)
        {
          'role': 'assistant',
          'content': message.text,
          'tool_calls': [
            for (final call in message.toolCalls)
              {
                'function': {'name': call.name, 'arguments': call.arguments},
              },
          ],
        }
      else
        {'role': message.role, 'content': message.text},
  ];

  Future<void> _streamOllama(
    LlmRequest request,
    StreamController<LlmEvent> sink,
  ) async {
    final base = Uri.parse(request.provider.baseURL);
    final response = await _post(base.resolve('/api/chat'), {
      'model': request.model,
      'messages': _ollamaMessages(request),
      if (request.tools.isNotEmpty && request.toolChoice != 'none')
        'tools': [for (final tool in request.tools) tool.toJson()],
      'stream': true,
      if (request.provider.think != null) 'think': request.provider.think,
    });

    var sawToolCall = false;
    var callCounter = 0;
    String? finishReason;
    int? inputTokens;
    int? outputTokens;

    await for (final line in _lines(response)) {
      if (line.trim().isEmpty) continue;
      final Map<String, dynamic> data;
      try {
        data = Map<String, dynamic>.from(jsonDecode(line) as Map);
      } catch (_) {
        continue;
      }
      final message = data['message'];
      if (message is Map) {
        final thinking = message['thinking'];
        if (thinking is String && thinking.isNotEmpty) {
          sink.add(LlmReasoningDelta(thinking));
        }
        final content = message['content'];
        if (content is String && content.isNotEmpty) {
          sink.add(LlmTextDelta(content));
        }
        final toolCalls = message['tool_calls'];
        if (toolCalls is List) {
          for (final raw in toolCalls) {
            if (raw is! Map) continue;
            final function = raw['function'];
            if (function is! Map) continue;
            sawToolCall = true;
            sink.add(
              LlmToolCallEvent(
                LlmToolCall(
                  id: 'call_${DateTime.now().microsecondsSinceEpoch}_${callCounter++}',
                  name: '${function['name'] ?? ''}',
                  arguments: function['arguments'] is Map
                      ? Map<String, dynamic>.from(function['arguments'] as Map)
                      : const {},
                ),
              ),
            );
          }
        }
      }
      if (data['done'] == true) {
        finishReason = data['done_reason'] as String?;
        inputTokens = (data['prompt_eval_count'] as num?)?.toInt();
        outputTokens = (data['eval_count'] as num?)?.toInt();
      }
      if (data['error'] is String) {
        throw LlmException('Ollama error: ${data['error']}');
      }
    }

    sink.add(
      LlmFinish(
        sawToolCall
            ? 'tool-calls'
            : (finishReason == 'length' ? 'length' : 'stop'),
        inputTokens: inputTokens,
        outputTokens: outputTokens,
      ),
    );
  }

  // ------------------------------------------------------ openai-compatible

  List<Map<String, dynamic>> _openAiMessages(LlmRequest request) => [
    for (final message in request.messages)
      if (message.role == 'tool')
        {
          'role': 'tool',
          'tool_call_id': ?message.toolCallId,
          'content': message.text,
        }
      else if (message.role == 'assistant' && message.toolCalls.isNotEmpty)
        {
          'role': 'assistant',
          'content': message.text.isEmpty ? null : message.text,
          'tool_calls': [
            for (final call in message.toolCalls)
              {
                'id': call.id,
                'type': 'function',
                'function': {
                  'name': call.name,
                  'arguments': jsonEncode(call.arguments),
                },
              },
          ],
        }
      else
        {'role': message.role, 'content': message.text},
  ];

  Future<void> _streamOpenAiCompatible(
    LlmRequest request,
    StreamController<LlmEvent> sink,
  ) async {
    final base = Uri.parse(request.provider.baseURL);
    final response = await _post(base.resolve('chat/completions'), {
      'model': request.model,
      'messages': _openAiMessages(request),
      if (request.tools.isNotEmpty && request.toolChoice != 'none')
        'tools': [for (final tool in request.tools) tool.toJson()],
      if (request.toolChoice == 'none') 'tool_choice': 'none',
      'stream': true,
      'stream_options': {'include_usage': true},
    }, apiKey: request.provider.apiKey);

    // Accumulate streamed tool-call fragments by index.
    final pending = <int, ({String id, String name, StringBuffer arguments})>{};
    var sawToolCall = false;
    String? finishReason;
    int? inputTokens;
    int? outputTokens;

    await for (final line in _lines(response)) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload == '[DONE]') break;
      final Map<String, dynamic> data;
      try {
        data = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      } catch (_) {
        continue;
      }
      final usage = data['usage'];
      if (usage is Map) {
        inputTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? inputTokens;
        outputTokens =
            (usage['completion_tokens'] as num?)?.toInt() ?? outputTokens;
      }
      final choices = data['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final choice = choices.first;
      if (choice is! Map) continue;
      if (choice['finish_reason'] is String) {
        finishReason = choice['finish_reason'] as String;
      }
      final delta = choice['delta'];
      if (delta is! Map) continue;
      final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
      if (reasoning is String && reasoning.isNotEmpty) {
        sink.add(LlmReasoningDelta(reasoning));
      }
      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        sink.add(LlmTextDelta(content));
      }
      final toolCalls = delta['tool_calls'];
      if (toolCalls is List) {
        for (final raw in toolCalls) {
          if (raw is! Map) continue;
          final index = (raw['index'] as num?)?.toInt() ?? 0;
          final entry = pending.putIfAbsent(
            index,
            () => (id: '', name: '', arguments: StringBuffer()),
          );
          final id = raw['id'];
          final function = raw['function'];
          final updated = (
            id: id is String && id.isNotEmpty ? id : entry.id,
            name: function is Map && function['name'] is String
                ? (function['name'] as String).isNotEmpty
                      ? function['name'] as String
                      : entry.name
                : entry.name,
            arguments: entry.arguments
              ..write(function is Map ? '${function['arguments'] ?? ''}' : ''),
          );
          pending[index] = updated;
        }
      }
    }

    for (final index in pending.keys.toList()..sort()) {
      final entry = pending[index]!;
      sawToolCall = true;
      Map<String, dynamic> arguments;
      try {
        final decoded = jsonDecode(entry.arguments.toString());
        arguments = decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : const {};
      } catch (_) {
        arguments = const {};
      }
      sink.add(
        LlmToolCallEvent(
          LlmToolCall(
            id: entry.id.isEmpty
                ? 'call_${DateTime.now().microsecondsSinceEpoch}_$index'
                : entry.id,
            name: entry.name,
            arguments: arguments,
          ),
        ),
      );
    }

    sink.add(
      LlmFinish(
        sawToolCall || finishReason == 'tool_calls'
            ? 'tool-calls'
            : (finishReason == 'length'
                  ? 'length'
                  : finishReason == null
                  ? 'unknown'
                  : 'stop'),
        inputTokens: inputTokens,
        outputTokens: outputTokens,
      ),
    );
  }

  Stream<String> _lines(HttpClientResponse response) =>
      utf8.decoder.bind(response).transform(const LineSplitter());
}
