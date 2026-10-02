import 'dart:async';
import 'dart:convert';
import '../../platform/flutter_process.dart';

/// Byte-oriented DAP framing; Content-Length counts UTF-8 bytes, not characters.
class DapDecoder {
  final List<int> _buffer = [];
  List<Map<String, dynamic>> add(List<int> bytes) {
    _buffer.addAll(bytes);
    final messages = <Map<String, dynamic>>[];
    while (true) {
      var boundary = -1;
      for (var i = 0; i + 3 < _buffer.length; i++) {
        if (_buffer[i] == 13 &&
            _buffer[i + 1] == 10 &&
            _buffer[i + 2] == 13 &&
            _buffer[i + 3] == 10) {
          boundary = i;
          break;
        }
      }
      if (boundary == -1) {
        if (_buffer.length > 8192) {
          throw const FormatException('Invalid DAP header');
        }
        break;
      }
      final header = ascii.decode(_buffer.sublist(0, boundary));
      final length = int.tryParse(
        RegExp(
              r'Content-Length:\s*(\d+)',
              caseSensitive: false,
            ).firstMatch(header)?.group(1) ??
            '',
      );
      if (length == null || length > 16 * 1024 * 1024) {
        throw const FormatException('Invalid DAP Content-Length');
      }
      if (_buffer.length < boundary + 4 + length) break;
      messages.add(
        jsonDecode(
              utf8.decode(_buffer.sublist(boundary + 4, boundary + 4 + length)),
            )
            as Map<String, dynamic>,
      );
      _buffer.removeRange(0, boundary + 4 + length);
    }
    return messages;
  }
}

List<int> encodeDap(Map<String, dynamic> message) {
  final body = utf8.encode(jsonEncode(message));
  return [...ascii.encode('Content-Length: ${body.length}\r\n\r\n'), ...body];
}

class DapClient {
  DapClient(this.process, this.onEvent, this.onLog) {
    _stdout = process.stdout.listen((bytes) {
      try {
        for (final message in _decoder.add(bytes)) {
          _receive(message);
        }
      } catch (e) {
        close(StateError('Debug adapter protocol: $e'));
        process.kill();
      }
    }, onError: (Object e) => close(e));
    _stderr = process.stderr.transform(utf8.decoder).listen(onLog);
    unawaited(
      process.exitCode.then((code) {
        close(StateError('Debug adapter exited ($code)'));
      }),
    );
  }
  final FlutterToolProcess process;
  final void Function(String, Map<String, dynamic>) onEvent;
  final void Function(String) onLog;
  final _decoder = DapDecoder();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  late final StreamSubscription<List<int>> _stdout;
  late final StreamSubscription<String> _stderr;
  int _seq = 0;
  bool _closed = false;

  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, dynamic> arguments = const {},
    Duration timeout = const Duration(seconds: 30),
  ]) async {
    if (_closed) throw StateError('Debug adapter is disconnected');
    final seq = ++_seq;
    final completer = Completer<Map<String, dynamic>>();
    _pending[seq] = completer;
    try {
      process.write(
        encodeDap({
          'seq': seq,
          'type': 'request',
          'command': command,
          'arguments': arguments,
        }),
      );
      return await completer.future.timeout(timeout);
    } finally {
      _pending.remove(seq);
    }
  }

  void _receive(Map<String, dynamic> message) {
    if (message['type'] == 'response') {
      final pending = _pending.remove(message['request_seq']);
      if (pending == null) return;
      if (message['success'] == true) {
        pending.complete(
          Map<String, dynamic>.from(message['body'] as Map? ?? {}),
        );
      } else {
        pending.completeError(
          StateError(message['message'] as String? ?? 'Debug request failed'),
        );
      }
    } else if (message['type'] == 'event') {
      onEvent(
        message['event'] as String,
        Map<String, dynamic>.from(message['body'] as Map? ?? {}),
      );
    } else if (message['type'] == 'request') {
      // Launch stays in the adapter's own process; no integrated terminal provider required.
      process.write(
        encodeDap({
          'seq': ++_seq,
          'type': 'response',
          'request_seq': message['seq'],
          'command': message['command'],
          'success': false,
          'message': 'Client reverse request unsupported',
        }),
      );
    }
  }

  void close(Object error) {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    unawaited(_stdout.cancel());
    unawaited(_stderr.cancel());
  }
}
