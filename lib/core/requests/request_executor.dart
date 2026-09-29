import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'http_request.dart';

class VariableResolver {
  static final pattern = RegExp(r'\{\{\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*\}\}');
  static final variableReference = RegExp(
    r'^\{\{\s*[A-Za-z_][A-Za-z0-9_.-]*\s*\}\}$',
  );

  static bool isVariableReference(String value) =>
      variableReference.hasMatch(value.trim());

  Map<String, String> combine({
    Map<String, String> project = const {},
    Map<String, String> secret = const {},
    Map<String, String> runtime = const {},
  }) => {...project, ...secret, ...runtime};

  String resolve(String source, Map<String, String> variables) {
    final missing = <String>{};
    final result = source.replaceAllMapped(pattern, (match) {
      final name = match[1]!;
      if (!variables.containsKey(name)) {
        missing.add(name);
        return match[0]!;
      }
      return variables[name]!;
    });
    if (missing.isNotEmpty) {
      throw FormatException('Missing variables: ${missing.join(', ')}');
    }
    return result;
  }

  dynamic resolveValue(dynamic value, Map<String, String> variables) {
    if (value is String) return resolve(value, variables);
    if (value is List) return value.map((item) => resolveValue(item, variables)).toList();
    if (value is Map) return {for (final entry in value.entries) entry.key.toString(): resolveValue(entry.value, variables)};
    return value;
  }
}

class ResolvedHttpRequest {
  const ResolvedHttpRequest({required this.id, required this.name, required this.method, required this.uri, required this.headers, required this.body});
  final String id, name, method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int> body;
}

class HttpTransportResponse {
  const HttpTransportResponse({required this.statusCode, required this.headers, required this.body});
  final int statusCode;
  final Map<String, String> headers;
  final List<int> body;
}

abstract interface class RequestHttpTransport {
  Future<HttpTransportResponse> send(ResolvedHttpRequest request);
  void close();
}

class PackageRequestHttpTransport implements RequestHttpTransport {
  PackageRequestHttpTransport({http.Client? client, this.timeout = const Duration(seconds: 60)}) : _client = client ?? http.Client();
  final http.Client _client;
  final Duration timeout;

  @override
  Future<HttpTransportResponse> send(ResolvedHttpRequest resolved) async {
    final request = http.Request(resolved.method, resolved.uri)
      ..followRedirects = false
      ..headers.addAll(resolved.headers)
      ..bodyBytes = resolved.body;
    final response = await _client.send(request).timeout(timeout);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(timeout)) {
      if (bytes.length + chunk.length > 4 * 1024 * 1024) {
        throw StateError('Response exceeds 4 MiB.');
      }
      bytes.add(chunk);
    }
    return HttpTransportResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      body: bytes.takeBytes(),
    );
  }

  @override
  void close() => _client.close();
}

class RequestExecutionContext {
  const RequestExecutionContext({this.projectVariables = const {}, this.secretVariables = const {}, this.runtimeVariables = const {}, this.projectAuth = const RequestEnvironment()});
  final Map<String, String> projectVariables, secretVariables, runtimeVariables;
  final RequestEnvironment projectAuth;
}

class RequestExecutionResult {
  const RequestExecutionResult({required this.id, required this.name, required this.method, required this.success, required this.duration, this.statusCode, this.responseBody = '', this.error = '', this.responseHeaders = const {}});
  final String id, name, method;
  final bool success;
  final int? statusCode;
  final Duration duration;
  final String responseBody, error;
  final Map<String, String> responseHeaders;
}

class BatchExecutionOptions {
  const BatchExecutionOptions({this.parallel = false, this.stopOnError = false, this.maxConcurrency = 5});
  final bool parallel, stopOnError;
  final int maxConcurrency;
}

class BatchExecutionResult {
  const BatchExecutionResult(this.results);
  final List<RequestExecutionResult> results;
  int get completed => results.where((result) => result.success).length;
  int get failed => results.where((result) => !result.success).length;
}

class RequestExecutor {
  RequestExecutor({RequestHttpTransport? transport, VariableResolver? resolver})
      : transport = transport ?? PackageRequestHttpTransport(),
        resolver = resolver ?? VariableResolver();
  final RequestHttpTransport transport;
  final VariableResolver resolver;

  ResolvedHttpRequest resolve(String id, HttpRequestFile request, RequestExecutionContext context) {
    request.validate();
    final variables = resolver.combine(project: context.projectVariables, secret: context.secretVariables, runtime: context.runtimeVariables);
    final rawUrl = resolver.resolve(request.url, variables);
    final base = Uri.tryParse(rawUrl);
    if (base == null ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        (base.scheme != 'http' && base.scheme != 'https')) {
      throw const FormatException('Request URL must be an absolute HTTP(S) URL.');
    }
    final query = <String, String>{...base.queryParameters};
    for (final item in request.query.where((item) => item.enabled)) {
      query[resolver.resolve(item.key, variables)] = resolver.resolve(item.value, variables);
    }
    final headers = <String, String>{};
    for (final item in request.headers.where((item) => item.enabled)) {
      final key = resolver.resolve(item.key, variables);
      final value = resolver.resolve(item.value, variables);
      if (key.trim().isEmpty ||
          key.contains(RegExp(r'[\r\n]')) ||
          value.contains(RegExp(r'[\r\n]'))) {
        throw const FormatException(
          'HTTP header names are required and cannot contain new lines.',
        );
      }
      headers[key] = value;
    }
    String token = '';
    if (request.auth.mode == 'bearer') {
      token = resolver.resolve(request.auth.token, variables);
    } else if (request.auth.mode == 'inherit' && context.projectAuth.authType == 'bearer') {
      token = resolver.resolve(context.projectAuth.authToken, variables);
    }
    if (request.auth.mode != 'none' && token.isNotEmpty && !headers.keys.any((key) => key.toLowerCase() == 'authorization')) {
      headers['Authorization'] = 'Bearer $token';
    }
    List<int> body = const [];
    if (request.body.type == 'json') {
      headers.putIfAbsent('Content-Type', () => 'application/json');
      body = utf8.encode(jsonEncode(resolver.resolveValue(request.body.value, variables)));
    } else if (request.body.type == 'text') {
      body = utf8.encode(resolver.resolve(request.body.value?.toString() ?? '', variables));
    } else if (request.body.type == 'form') {
      final value = resolver.resolveValue(request.body.value, variables);
      if (value is! Map) throw const FormatException('Form body must be an object.');
      headers.putIfAbsent('Content-Type', () => 'application/x-www-form-urlencoded');
      body = utf8.encode(value.entries.map((entry) => '${Uri.encodeQueryComponent(entry.key.toString())}=${Uri.encodeQueryComponent(entry.value.toString())}').join('&'));
    }
    if (body.length > 4 * 1024 * 1024) {
      throw const FormatException('Request body exceeds 4 MiB.');
    }
    return ResolvedHttpRequest(id: id, name: request.name, method: request.method, uri: base.replace(queryParameters: query.isEmpty ? null : query), headers: headers, body: body);
  }

  Future<RequestExecutionResult> execute(String id, HttpRequestFile request, RequestExecutionContext context) async {
    final stopwatch = Stopwatch()..start();
    try {
      final resolved = resolve(id, request, context);
      final response = await transport.send(resolved);
      stopwatch.stop();
      return RequestExecutionResult(
        id: id,
        name: request.name,
        method: request.method,
        success: response.statusCode >= 200 && response.statusCode < 400,
        statusCode: response.statusCode,
        duration: stopwatch.elapsed,
        responseBody: utf8.decode(response.body, allowMalformed: true),
        responseHeaders: response.headers,
      );
    } catch (error) {
      stopwatch.stop();
      return RequestExecutionResult(id: id, name: request.name, method: request.method, success: false, duration: stopwatch.elapsed, error: _safeError('$error', context));
    }
  }

  String _safeError(String error, RequestExecutionContext context) {
    var safe = error;
    for (final secret in [...context.secretVariables.values, context.projectAuth.authToken]) {
      if (secret.isNotEmpty) safe = safe.replaceAll(secret, '<redacted>');
    }
    return safe;
  }

  Future<BatchExecutionResult> executeMany(List<({String id, HttpRequestFile request})> requests, RequestExecutionContext context, [BatchExecutionOptions options = const BatchExecutionOptions()]) async {
    if (requests.isEmpty) return const BatchExecutionResult([]);
    if (!options.parallel) {
      final results = <RequestExecutionResult>[];
      for (final item in requests) {
        final result = await execute(item.id, item.request, context);
        results.add(result);
        if (!result.success && options.stopOnError) break;
      }
      return BatchExecutionResult(results);
    }
    final results = List<RequestExecutionResult?>.filled(requests.length, null);
    var next = 0;
    var stopped = false;
    Future<void> worker() async {
      while (!stopped) {
        final index = next++;
        if (index >= requests.length) return;
        final item = requests[index];
        final result = await execute(item.id, item.request, context);
        results[index] = result;
        if (!result.success && options.stopOnError) stopped = true;
      }
    }
    final count = options.maxConcurrency.clamp(1, 5).clamp(1, requests.length);
    await Future.wait(List.generate(count, (_) => worker()));
    return BatchExecutionResult(results.whereType<RequestExecutionResult>().toList());
  }

  void close() => transport.close();
}
