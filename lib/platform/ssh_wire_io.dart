import '../core/ssh/transport/ssh_transport.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import '../core/ssh/ssh_error.dart';
import '../core/ssh/transport/ssh_wire.dart';

Future<SshWire> openSshWire(
  String host,
  int port,
  SshCancellation cancellation,
) async {
  try {
    final pending = Socket.startConnect(host, port);
    ConnectionTask<Socket>? task;
    try {
      task = await Future.any([
        pending,
        cancellation.whenCancelled.then<ConnectionTask<Socket>>(
          (_) => throw const SshException('SSH connection cancelled.'),
        ),
      ]).timeout(const Duration(seconds: 10));
      unawaited(cancellation.whenCancelled.then((_) => task?.cancel()));
      final socket = await task.socket.timeout(const Duration(seconds: 10));
      if (cancellation.cancelled) {
        socket.destroy();
        throw const SshException('SSH connection cancelled.');
      }
      socket.setOption(SocketOption.tcpNoDelay, true);
      return SocketSshWire(socket);
    } catch (_) {
      task?.cancel();
      unawaited(
        pending.then(
          (lateTask) => lateTask.cancel(),
          onError: (Object _, StackTrace _) {},
        ),
      );
      rethrow;
    }
  } on SocketException {
    throw const SshException(
      'Unable to reach the SSH server. Check the address, port and network.',
    );
  } on TimeoutException {
    throw const SshException('SSH TCP connection timed out.');
  }
}

class SocketSshWire implements SshWire {
  SocketSshWire(this.socket) {
    subscription = socket.listen(
      (bytes) {
        if (closed) return;
        buffered += bytes.length;
        if (buffered > 1024 * 1024) {
          error = const SshException('SSH receive buffer limit exceeded.');
          socket.destroy();
          closed = true;
        } else {
          chunks.add(bytes);
          if (buffered >= 512 * 1024) subscription.pause();
        }
        wake();
      },
      onError: (Object _) {
        error = const SshException('SSH network connection failed.');
        closed = true;
        wake();
      },
      onDone: () {
        closed = true;
        wake();
      },
    );
  }
  final Socket socket;
  late final StreamSubscription<Uint8List> subscription;
  final chunks = ListQueue<Uint8List>();
  int buffered = 0, offset = 0;
  bool closed = false, reading = false;
  SshException? error;
  Completer<void>? waiting;
  void wake() {
    final w = waiting;
    waiting = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  @override
  Future<Uint8List> read(int length) async {
    if (length < 0 || length > 256 * 1024 || reading) {
      throw const SshException('Invalid concurrent SSH read.');
    }
    reading = true;
    try {
      final result = Uint8List(length);
      var written = 0;
      while (written < length) {
        if (error != null) throw error!;
        if (chunks.isEmpty) {
          if (closed) {
            throw const SshException('SSH server closed the connection.');
          }
          waiting ??= Completer<void>();
          await waiting!.future;
          continue;
        }
        final chunk = chunks.first;
        final count = (length - written) < chunk.length - offset
            ? length - written
            : chunk.length - offset;
        result.setRange(written, written + count, chunk, offset);
        written += count;
        offset += count;
        buffered -= count;
        if (offset == chunk.length) {
          chunks.removeFirst();
          offset = 0;
        }
        if (subscription.isPaused && buffered < 256 * 1024) {
          subscription.resume();
        }
      }
      return result;
    } finally {
      reading = false;
    }
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (closed) throw error ?? const SshException('SSH connection is closed.');
    try {
      socket.add(bytes);
      await socket.flush();
    } on SocketException {
      throw const SshException('Unable to send SSH data.');
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    socket.destroy();
    wake();
    await subscription.cancel();
    chunks.clear();
    buffered = 0;
  }
}
