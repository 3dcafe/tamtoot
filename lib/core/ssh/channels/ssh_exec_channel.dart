part of '../ssh_client.dart';

class SshCommandOutput {
  SshCommandOutput(List<int> data, this.stderr)
    : data = Uint8List.fromList(data);
  final Uint8List data;
  final bool stderr;
}

class SshCommandResult {
  const SshCommandResult(
    this.stdout,
    this.stderr,
    this.exitStatus,
    this.exitSignal,
  );
  final Uint8List stdout, stderr;
  final int? exitStatus;
  final String? exitSignal;
  bool get succeeded => exitStatus == 0 && exitSignal == null;
}

class SshExecChannel {
  SshExecChannel._(this.client, this.local, Duration timeout, this.onOutput) {
    for (final future in [_opened.future, _accepted.future, _result.future]) {
      unawaited(future.then((_) {}, onError: (Object _, StackTrace _) {}));
    }
    _timer = Timer(timeout, () => _fail('SSH command timed out.'));
  }
  static const windowSize = 256 * 1024,
      packetSize = 32768,
      outputLimit = 2 * 1024 * 1024;
  final SshClient client;
  final int local;
  final void Function(SshCommandOutput)? onOutput;
  int? remote;
  int _remoteWindow = 0,
      _remotePacket = 0,
      _localWindow = windowSize,
      _outputBytes = 0,
      _pendingInput = 0;
  bool _execSent = false,
      _inputEof = false,
      _outputEof = false,
      _closing = false,
      _closed = false;
  int? _exitStatus;
  String? _exitSignal;
  Timer? _timer, _closeTimer;
  final _opened = Completer<void>(), _accepted = Completer<void>();
  final _result = Completer<SshCommandResult>();
  final _stdout = BytesBuilder(copy: false),
      _stderr = BytesBuilder(copy: false);
  Future<SshCommandResult> get result => _result.future;
  Future<void> _writeTail = Future.value();
  Completer<void>? _windowWaiting;
  void _check() {
    if (_closing || _closed) {
      throw const SshException('SSH command channel is closed.');
    }
    client._verified();
  }

  Future<void> writeStdin(List<int> data) {
    _check();
    if (_inputEof ||
        !_accepted.isCompleted ||
        data.length > 1024 * 1024 ||
        _pendingInput + data.length > 1024 * 1024) {
      throw const SshException(
        'SSH stdin is closed or its buffer limit was exceeded.',
      );
    }
    final copy = Uint8List.fromList(data);
    _pendingInput += copy.length;
    final task = _writeTail.then((_) async {
      var offset = 0;
      while (offset < copy.length) {
        _check();
        if (_remoteWindow == 0) {
          _windowWaiting ??= Completer<void>();
          await _windowWaiting!.future;
          continue;
        }
        final size = min(
          min(_remoteWindow, _remotePacket),
          min(packetSize, copy.length - offset),
        );
        _remoteWindow -= size;
        await client._send(
          (SshWriter()
                ..byte(94)
                ..uint32(remote!)
                ..string(Uint8List.sublistView(copy, offset, offset + size)))
              .take(),
        );
        offset += size;
      }
    });
    _writeTail = task.then((_) {}, onError: (Object _, StackTrace _) {});
    return task.whenComplete(() {
      _pendingInput -= copy.length;
      copy.fillRange(0, copy.length, 0);
    });
  }

  Future<void> finishStdin() {
    // A fast command may already have closed before openExec returns.
    if (_closed || _closing) return Future.value();
    _check();
    if (_inputEof) return _writeTail;
    _inputEof = true;
    final task = _writeTail.then((_) async {
      _check();
      await client._send(
        (SshWriter()
              ..byte(96)
              ..uint32(remote!))
            .take(),
      );
    });
    _writeTail = task.then((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<void> cancel() async {
    _fail('SSH command cancelled.');
  }

  void _wake() {
    final waiting = _windowWaiting;
    _windowWaiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  void _receive(int type, SshReader reader) {
    if (type == 91) {
      if (remote != null) {
        throw const SshException('Duplicate SSH channel confirmation.');
      }
      remote = reader.uint32();
      _remoteWindow = reader.uint32();
      _remotePacket = reader.uint32();
      reader.end();
      if (_remotePacket == 0 ||
          client._channels.values.any((c) => c != this && c.remote == remote)) {
        throw const SshException('Invalid SSH channel confirmation.');
      }
      if (!_opened.isCompleted) _opened.complete();
      if (_closing) _sendClose();
      return;
    }
    if (type == 92) {
      if (remote != null) {
        throw const SshException('Unexpected SSH channel open failure.');
      }
      reader.uint32();
      reader.string(limit: 4096);
      reader.string(limit: 128);
      reader.end();
      _fail('SSH server refused the session channel.', sendClose: false);
      _remove();
      return;
    }
    if (remote == null) {
      throw const SshException('SSH channel data preceded its confirmation.');
    }
    if (type == 93) {
      final amount = reader.uint32();
      reader.end();
      if (_remoteWindow + amount > 0xffffffff) {
        throw const SshException('Invalid SSH channel window adjustment.');
      }
      _remoteWindow += amount;
      _wake();
      return;
    }
    if (type == 94 || type == 95) {
      final extended = type == 95 ? reader.uint32() : 0;
      final data = reader.string(limit: packetSize);
      reader.end();
      if (data.length > _localWindow || _outputEof) {
        throw const SshException(
          'SSH channel exceeded its receive window or sent data after EOF.',
        );
      }
      _localWindow -= data.length;
      if (_closing) return;
      if (!_execSent || !_accepted.isCompleted) {
        throw const SshException(
          'SSH command data preceded execution acceptance.',
        );
      }
      if (type == 94 || extended == 1) {
        _outputBytes += data.length;
        if (_outputBytes > outputLimit) {
          _fail('SSH command output exceeded 2 MiB.');
          return;
        }
        final copy = Uint8List.fromList(data);
        (type == 94 ? _stdout : _stderr).add(copy);
        onOutput?.call(SshCommandOutput(copy, type == 95));
      }
      if (!_closing && _localWindow <= windowSize ~/ 2) {
        final amount = windowSize - _localWindow;
        _localWindow += amount;
        client._sendBackground(
          (SshWriter()
                ..byte(93)
                ..uint32(remote!)
                ..uint32(amount))
              .take(),
        );
      }
      return;
    }
    if (type == 96) {
      reader.end();
      if (_outputEof) throw const SshException('Duplicate SSH channel EOF.');
      _outputEof = true;
      return;
    }
    if (type == 97) {
      reader.end();
      if (!_closing) {
        client._sendBackground(
          (SshWriter()
                ..byte(97)
                ..uint32(remote!))
              .take(),
        );
      }
      if (!_accepted.isCompleted) {
        _fail(
          'SSH channel closed before execution acceptance.',
          sendClose: false,
        );
      }
      if (!_result.isCompleted) {
        if (_exitStatus == null && _exitSignal == null) {
          _fail('SSH channel closed without an exit status.', sendClose: false);
        } else {
          _result.complete(
            SshCommandResult(
              _stdout.takeBytes(),
              _stderr.takeBytes(),
              _exitStatus,
              _exitSignal,
            ),
          );
        }
      }
      _remove();
      return;
    }
    if (type == 99 || type == 100) {
      reader.end();
      if (_closing) return;
      if (!_execSent || _accepted.isCompleted) {
        throw const SshException('Unexpected SSH channel request response.');
      }
      if (type == 99) {
        _accepted.complete();
      } else {
        _fail('SSH server refused command execution.');
      }
      return;
    }
    if (type == 98) {
      final request = reader.asciiText(limit: 128), reply = reader.boolean();
      if (request == 'exit-status') {
        if (_exitStatus != null || _exitSignal != null) {
          throw const SshException('Duplicate SSH command exit result.');
        }
        _exitStatus = reader.uint32();
        reader.end();
      } else if (request == 'exit-signal') {
        if (_exitStatus != null || _exitSignal != null) {
          throw const SshException('Duplicate SSH command exit result.');
        }
        _exitSignal = reader.asciiText(limit: 128);
        reader.boolean();
        reader.string(limit: 4096);
        reader.string(limit: 128);
        reader.end();
      } else {
        if (reply) {
          client._sendBackground(
            (SshWriter()
                  ..byte(100)
                  ..uint32(remote!))
                .take(),
          );
        }
        return;
      }
      if (reply) {
        client._sendBackground(
          (SshWriter()
                ..byte(99)
                ..uint32(remote!))
              .take(),
        );
      }
      return;
    }
    throw const SshException('Unsupported SSH channel message.');
  }

  void _sendClose() {
    if (remote != null) {
      client._sendBackground(
        (SshWriter()
              ..byte(97)
              ..uint32(remote!))
            .take(),
      );
    }
  }

  void _fail(String message, {bool sendClose = true}) {
    if (_closing || _closed) return;
    _closing = true;
    _timer?.cancel();
    _wake();
    final exception = SshException(message);
    if (!_opened.isCompleted) _opened.completeError(exception);
    if (!_accepted.isCompleted) _accepted.completeError(exception);
    if (!_result.isCompleted) _result.completeError(exception);
    _stdout.clear();
    _stderr.clear();
    if (sendClose && client.state != SshClientState.closed) {
      _sendClose();
      _closeTimer = Timer(
        const Duration(seconds: 5),
        () => client._fatal('SSH server did not close the cancelled channel.'),
      );
    }
  }

  void _remove() {
    _closed = true;
    _timer?.cancel();
    _closeTimer?.cancel();
    _wake();
    client._channels.remove(local);
  }
}
