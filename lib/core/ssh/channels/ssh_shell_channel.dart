part of '../ssh_client.dart';

/// Streaming PTY: bounded receive window, no lifetime transcript or idle deadline.
class SshShellChannel extends SshExecChannel {
  SshShellChannel._(
    SshClient client,
    int local,
    void Function(SshCommandOutput) output,
  ) : super._(
        client,
        local,
        const Duration(seconds: 30),
        output,
        interactive: true,
      );
  // Conservative terminfo contract; extra ANSI color/paste modes are opt-in.
  static const terminalType = 'vt100';
  static void validateSize(int columns, int rows) {
    if (columns < 2 || columns > 300 || rows < 2 || rows > 120) {
      throw const SshException('Terminal dimensions exceed supported limits.');
    }
  }

  Future<void> _request(String name, List<int> fields) async {
    _check();
    if (_requestWaiting != null) {
      throw const SshException('Concurrent SSH terminal requests.');
    }
    final waiting = Completer<void>();
    _requestWaiting = waiting;
    unawaited(
      waiting.future.then((_) {}, onError: (Object _, StackTrace _) {}),
    );
    await client._send(
      (SshWriter()
            ..byte(98)
            ..uint32(remote!)
            ..text(name)
            ..byte(1)
            ..raw(fields))
          .take(),
    );
    await waiting.future;
  }

  Future<void> resize(int columns, int rows) async {
    validateSize(columns, rows);
    _check();
    if (!_accepted.isCompleted) {
      throw const SshException('SSH terminal is not ready.');
    }
    await client._send(
      (SshWriter()
            ..byte(98)
            ..uint32(remote!)
            ..text('window-change')
            ..byte(0)
            ..uint32(columns)
            ..uint32(rows)
            ..uint32(0)
            ..uint32(0))
          .take(),
    );
  }
}
