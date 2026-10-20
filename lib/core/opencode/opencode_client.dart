import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class OpencodeException implements Exception {
  const OpencodeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Owns an `opencode serve` child process bound to one project directory.
///
/// The server is always started on a freshly allocated localhost port so it
/// never collides with a server from another project or a running TUI.
class OpencodeServerManager {
  OpencodeServerManager({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  Process? _process;
  Uri? _baseUrl;
  String? _workingDirectory;

  Uri get baseUrl {
    final url = _baseUrl;
    if (url == null) {
      throw const OpencodeException('The opencode server is not running.');
    }
    return url;
  }

  bool get isRunning => _baseUrl != null;

  Future<bool> health(Uri base) async {
    try {
      final response = await _client
          .get(base.resolve('/global/health'))
          .timeout(const Duration(seconds: 2));
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body);
      return data is Map && data['healthy'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Start (or reuse, for the same directory) a headless opencode server.
  Future<Uri> ensureRunning({required String workingDirectory}) async {
    if (_baseUrl != null && _workingDirectory == workingDirectory) {
      if (await health(_baseUrl!)) return _baseUrl!;
      stop();
    }
    stop();
    final port = await _freePort();
    final base = Uri.parse('http://127.0.0.1:$port');
    try {
      _process = await Process.start('opencode', [
        'serve',
        '--hostname',
        '127.0.0.1',
        '--port',
        '$port',
      ], workingDirectory: workingDirectory);
    } on ProcessException {
      throw const OpencodeException(
        'opencode CLI was not found. Install it first:\n'
        'curl -fsSL https://opencode.ai/v2/install | bash\n'
        'or: brew install anomalyco/tap/opencode-v2',
      );
    }
    _process!
      ..stdout.drain<void>()
      ..stderr.drain<void>();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (await health(base)) {
        _baseUrl = base;
        _workingDirectory = workingDirectory;
        return base;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    stop();
    throw const OpencodeException(
      'The opencode server did not become healthy in time.',
    );
  }

  Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  void stop() {
    _process?.kill();
    _process = null;
    _baseUrl = null;
    _workingDirectory = null;
  }
}

/// Thin typed wrapper over the opencode HTTP API (see `opencode serve --help`
/// and the OpenAPI spec at `/doc`).
class OpencodeClient {
  OpencodeClient(this.baseUrl, {http.Client? client})
    : _client = client ?? http.Client();

  final Uri baseUrl;
  final http.Client _client;

  Future<dynamic> _get(String path, [Map<String, String>? query]) async {
    final response = await _client
        .get(baseUrl.resolve(path).replace(queryParameters: query))
        .timeout(const Duration(seconds: 15));
    return _decode(response);
  }

  Future<dynamic> _post(String path, [Map<String, dynamic>? body]) async {
    final response = await _client
        .post(
          baseUrl.resolve(path),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(body ?? const {}),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 204) return null;
    return _decode(response);
  }

  Future<dynamic> _delete(String path) async {
    final response = await _client
        .delete(baseUrl.resolve(path))
        .timeout(const Duration(seconds: 15));
    return _decode(response);
  }

  dynamic _decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OpencodeException(
        'opencode returned HTTP ${response.statusCode}: '
        '${response.body.length > 300 ? response.body.substring(0, 300) : response.body}',
      );
    }
    if (response.body.trim().isEmpty) return null;
    return jsonDecode(response.body);
  }

  Future<List<Map<String, dynamic>>> sessions() async {
    final data = await _get('/session');
    return data is List ? data.cast<Map<String, dynamic>>() : const [];
  }

  Future<String> createSession({String? title}) async {
    final data = await _post('/session', {'title': ?title});
    if (data is Map && data['id'] is String) return data['id'] as String;
    throw const OpencodeException('opencode did not return a session id.');
  }

  Future<void> deleteSession(String id) => _delete('/session/$id').then((_) {});

  Future<List<Map<String, dynamic>>> messages(String sessionId) async {
    final data = await _get('/session/$sessionId/message');
    return data is List ? data.cast<Map<String, dynamic>>() : const [];
  }

  /// Fire-and-forget prompt; the reply arrives asynchronously (poll
  /// [messages] or subscribe to `/event`).
  Future<void> promptAsync(
    String sessionId,
    String text, {
    String? providerId,
    String? modelId,
    String? agent,
  }) => _post('/session/$sessionId/prompt_async', {
    if (providerId != null && modelId != null)
      'model': {'providerID': providerId, 'modelID': modelId},
    'agent': ?agent,
    'parts': [
      {'type': 'text', 'text': text},
    ],
  }).then((_) {});

  Future<void> abort(String sessionId) =>
      _post('/session/$sessionId/abort').then((_) {});

  /// Map of session id → status (`idle`, `busy`, `retry`).
  Future<Map<String, dynamic>> sessionStatus() async {
    final data = await _get('/session/status');
    return data is Map ? Map<String, dynamic>.from(data) : const {};
  }

  Future<Map<String, dynamic>> providers() async {
    final data = await _get('/config/providers');
    return data is Map ? Map<String, dynamic>.from(data) : const {};
  }

  Future<Map<String, dynamic>> mcpStatus() async {
    final data = await _get('/mcp');
    return data is Map ? Map<String, dynamic>.from(data) : const {};
  }
}
