import 'dart:async';
import 'dart:convert';
import 'dart:io';

class McpStdioTransport {
  McpStdioTransport(this.command, this.arguments, this.timeoutSeconds);
  final String command;
  final List<String> arguments;
  final int timeoutSeconds;
  Process? _process;
  StreamSubscription<String>? _lines;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _id = 0;

  Future<void> _start() async {
    if (_process != null) return;
    if (command.isEmpty || command.contains('\u0000')) {
      throw const FormatException('Invalid MCP command.');
    }
    final process = await Process.start(command, arguments, runInShell: false);
    _process = process;
    _lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _receive,
          onError: _failAll,
          onDone: () {
            if (_pending.isNotEmpty) {
              _failAll(StateError('MCP process closed unexpectedly.'));
            }
          },
        );
    process.stderr.transform(utf8.decoder).listen((_) {});
  }

  void _receive(String line) {
    if (line.trim().isEmpty || line.length > 4 * 1024 * 1024) return;
    try {
      final data = jsonDecode(line);
      if (data is! Map<String, dynamic> || data['id'] is! num) return;
      final id = (data['id'] as num).toInt();
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (data['error'] is Map) {
        final error = data['error'] as Map;
        completer.completeError(
          StateError(error['message']?.toString() ?? 'MCP request failed.'),
        );
      } else if (data['result'] is Map<String, dynamic>) {
        completer.complete(data['result'] as Map<String, dynamic>);
      } else {
        completer.complete(const {});
      }
    } catch (_) {}
  }

  void _failAll(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    bool notification = false,
  }) async {
    await _start();
    final id = ++_id;
    final completer = Completer<Map<String, dynamic>>();
    if (!notification) _pending[id] = completer;
    _process!.stdin.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        if (!notification) 'id': id,
        'method': method,
        'params': params,
      }),
    );
    await _process!.stdin.flush();
    if (notification) return const {};
    return completer.future.timeout(
      Duration(seconds: timeoutSeconds),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('MCP STDIO request timed out.');
      },
    );
  }

  void close() {
    _lines?.cancel();
    _process?.kill();
    _process = null;
    _failAll(StateError('MCP client closed.'));
  }
}
