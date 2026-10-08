import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'auth/ssh_private_key.dart';
import 'crypto/ssh_crypto.dart';
import 'ssh_error.dart';
import 'transport/ssh_codec.dart';
import 'transport/ssh_transport.dart';
part 'auth/ssh_authentication.dart';
part 'channels/ssh_exec_channel.dart';
part 'channels/ssh_shell_channel.dart';

enum SshClientState { idle, authenticating, ready, closed }

/// One message router owns the transport subscription for auth and all channels.
class SshClient {
  SshClient(this.transport) {
    _subscription = transport.messages.listen(
      _receive,
      onDone: () => _terminate('SSH connection closed.'),
      onError: (Object _) => _terminate('SSH connection failed.'),
    );
  }
  final SshTransport transport;
  late final StreamSubscription<Uint8List> _subscription;
  final _states = StreamController<SshClientState>.broadcast(sync: true);
  Stream<SshClientState> get states => _states.stream;
  SshClientState state = SshClientState.idle;
  final _authPackets = ListQueue<Uint8List>();
  int _authBytes = 0, _attempts = 0, _nextChannel = 0, _bannerBytes = 0;
  Completer<Uint8List>? _authWaiting;
  bool _serviceStarted = false, _partial = false;
  String? _username;
  List<String>? _methods;
  void Function(String)? _banner;
  final _extensions = <String, String>{};
  final _channels = <int, SshExecChannel>{};
  void _state(SshClientState value) {
    if (state == SshClientState.closed) return;
    state = value;
    _states.add(value);
  }

  void _verified() {
    if (state == SshClientState.closed ||
        transport.cancellation.cancelled ||
        (transport.state != SshTransportState.ready &&
            transport.state != SshTransportState.rekeying) ||
        transport.serverKey == null) {
      throw const SshException(
        'SSH server is not verified or the connection is closed.',
      );
    }
  }

  Future<void> _send(List<int> packet) async {
    _verified();
    await transport.send(packet);
  }

  void _sendBackground(List<int> packet) {
    unawaited(
      _send(packet).catchError((Object _) {
        _fatal('Unable to send SSH channel data.');
      }),
    );
  }

  void _receive(Uint8List packet) {
    if (state == SshClientState.closed) return;
    try {
      final type = packet[0];
      if (type == 7) {
        final reader = SshReader(packet)..byte();
        final count = reader.uint32();
        if (count > 32 || _extensions.length + count > 32) {
          throw const SshException('SSH extension count exceeds its limit.');
        }
        for (var i = 0; i < count; i++) {
          final name = reader.asciiText(limit: 128),
              value = reader.asciiText(limit: 16384);
          if (_extensions.containsKey(name)) {
            throw const SshException('Duplicate SSH extension.');
          }
          _extensions[name] = value;
        }
        reader.end();
        return;
      }
      if (type == 53) {
        final r = SshReader(packet)..byte();
        final text = utf8.decode(r.string(limit: 16384), allowMalformed: true);
        r.string(limit: 128);
        r.end();
        _bannerBytes += text.length;
        if (_bannerBytes > 65536) {
          throw const SshException('SSH authentication banner limit exceeded.');
        }
        _banner?.call(text);
        return;
      }
      if (type == 6 || (type >= 50 && type <= 79)) {
        if (state != SshClientState.authenticating) {
          throw const SshException('Unexpected SSH authentication response.');
        }
        final waiting = _authWaiting;
        if (waiting != null) {
          _authWaiting = null;
          waiting.complete(packet);
        } else {
          _authBytes += packet.length;
          if (_authBytes > 256 * 1024 || _authPackets.length >= 32) {
            throw const SshException(
              'SSH authentication buffer limit exceeded.',
            );
          }
          _authPackets.add(packet);
        }
        return;
      }
      if (state != SshClientState.ready) {
        throw const SshException(
          'SSH channel data arrived before authentication.',
        );
      }
      if (type == 80) {
        final r = SshReader(packet)..byte();
        r.asciiText(limit: 128);
        final reply = r.boolean();
        if (reply) _sendBackground([82]);
        return;
      }
      if (type == 81 || type == 82) {
        throw const SshException('Unexpected SSH global response.');
      }
      if (type == 90) {
        final r = SshReader(packet)..byte();
        r.asciiText(limit: 128);
        final channel = r.uint32();
        r.uint32();
        r.uint32();
        _sendBackground(
          (SshWriter()
                ..byte(92)
                ..uint32(channel)
                ..uint32(3)
                ..text('Unsupported server channel')
                ..text(''))
              .take(),
        );
        return;
      }
      if (type < 91 || type > 100) {
        throw const SshException('Unsupported SSH connection message.');
      }
      final reader = SshReader(packet)..byte();
      final local = reader.uint32();
      final channel = _channels[local];
      if (channel == null) {
        throw const SshException('SSH message refers to an unknown channel.');
      }
      channel._receive(type, reader);
    } on SshException catch (e) {
      _fatal(e.message);
    } catch (_) {
      _fatal('Malformed SSH application message.');
    }
  }

  Future<Uint8List> _nextAuth() async {
    _verified();
    if (_authPackets.isNotEmpty) {
      final p = _authPackets.removeFirst();
      _authBytes -= p.length;
      return p;
    }
    if (_authWaiting != null) {
      throw const SshException('Concurrent SSH authentication reads.');
    }
    final pending = Completer<Uint8List>();
    _authWaiting = pending;
    try {
      return await pending.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _fatal('SSH authentication response timed out.');
      throw const SshException('SSH authentication response timed out.');
    } finally {
      if (identical(_authWaiting, pending)) _authWaiting = null;
    }
  }

  void _fatal(String message) {
    _terminate(message);
    unawaited(transport.close());
  }

  void _terminate(String message) {
    if (state == SshClientState.closed) return;
    _state(SshClientState.closed);
    final waiting = _authWaiting;
    _authWaiting = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(SshException(message));
    }
    _authPackets.clear();
    _authBytes = 0;
    for (final channel in _channels.values.toList()) {
      channel._fail(message, sendClose: false);
      channel._closeTimer?.cancel();
    }
    _channels.clear();
    unawaited(_states.close());
  }

  Future<void> close() async {
    _terminate('SSH connection closed.');
    await transport.close();
    await _subscription.cancel();
  }

  Future<SshExecChannel> openExec(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    void Function(SshCommandOutput)? onOutput,
    SshCancellation? cancellation,
  }) async {
    _verified();
    if (state != SshClientState.ready ||
        command.isEmpty ||
        utf8.encode(command).length > 16384 ||
        command.contains('\x00') ||
        timeout <= Duration.zero ||
        timeout > const Duration(hours: 1)) {
      throw const SshException('Invalid SSH command or connection state.');
    }
    if (_channels.length >= 4 || _nextChannel > 0xffffffff) {
      throw const SshException('SSH channel limit exceeded.');
    }
    final channel = SshExecChannel._(this, _nextChannel++, timeout, onOutput);
    _channels[channel.local] = channel;
    if (cancellation != null) {
      unawaited(cancellation.whenCancelled.then((_) => channel.cancel()));
      if (cancellation.cancelled) {
        channel._fail('SSH command cancelled.', sendClose: false);
        channel._remove();
        throw const SshException('SSH command cancelled.');
      }
    }
    try {
      await _send(
        (SshWriter()
              ..byte(90)
              ..text('session')
              ..uint32(channel.local)
              ..uint32(SshExecChannel.windowSize)
              ..uint32(SshExecChannel.packetSize))
            .take(),
      );
      await channel._opened.future;
      channel._execSent = true;
      await _send(
        (SshWriter()
              ..byte(98)
              ..uint32(channel.remote!)
              ..text('exec')
              ..byte(1)
              ..text(command))
            .take(),
      );
      await channel._accepted.future;
      return channel;
    } catch (e) {
      channel._fail(
        e is SshException ? e.message : 'SSH command could not start.',
      );
      rethrow;
    }
  }

  Future<SshShellChannel> openShell({
    required int columns,
    required int rows,
    required void Function(SshCommandOutput) onOutput,
    SshCancellation? cancellation,
  }) async {
    _verified();
    SshShellChannel.validateSize(columns, rows);
    if (state != SshClientState.ready ||
        _channels.length >= 4 ||
        _nextChannel > 0xffffffff) {
      throw const SshException(
        'SSH channel limit or connection state is invalid.',
      );
    }
    final channel = SshShellChannel._(this, _nextChannel++, onOutput);
    _channels[channel.local] = channel;
    if (cancellation != null) {
      unawaited(cancellation.whenCancelled.then((_) => channel.cancel()));
      if (cancellation.cancelled) {
        channel._fail('SSH terminal cancelled.', sendClose: false);
        channel._remove();
        throw const SshException('SSH terminal cancelled.');
      }
    }
    try {
      await _send(
        (SshWriter()
              ..byte(90)
              ..text('session')
              ..uint32(channel.local)
              ..uint32(SshExecChannel.windowSize)
              ..uint32(SshExecChannel.packetSize))
            .take(),
      );
      await channel._opened.future;
      await channel._request(
        'pty-req',
        (SshWriter()
              ..text(SshShellChannel.terminalType)
              ..uint32(columns)
              ..uint32(rows)
              ..uint32(0)
              ..uint32(0)
              ..string([0]))
            .take(),
      );
      channel._execSent = true;
      await _send(
        (SshWriter()
              ..byte(98)
              ..uint32(channel.remote!)
              ..text('shell')
              ..byte(1))
            .take(),
      );
      await channel._accepted.future;
      channel._timer?.cancel();
      return channel;
    } catch (e) {
      channel._fail(
        e is SshException ? e.message : 'SSH terminal could not start.',
      );
      rethrow;
    }
  }

  /// Binary subsystem stream; uses the same bounded channel flow control as PTY.
  Future<SshExecChannel> openSubsystem(
    String name, {
    required void Function(SshCommandOutput) onOutput,
    SshCancellation? cancellation,
  }) async {
    _verified();
    if (state != SshClientState.ready ||
        name != 'sftp' ||
        _channels.length >= 4 ||
        _nextChannel > 0xffffffff) {
      throw const SshException('Invalid SSH subsystem or channel limit.');
    }
    final channel = SshExecChannel._(
      this,
      _nextChannel++,
      const Duration(seconds: 30),
      onOutput,
      interactive: true,
    );
    _channels[channel.local] = channel;
    if (cancellation != null) {
      unawaited(cancellation.whenCancelled.then((_) => channel.cancel()));
      if (cancellation.cancelled) {
        channel._fail('SSH subsystem cancelled.', sendClose: false);
        channel._remove();
        throw const SshException('SSH subsystem cancelled.');
      }
    }
    try {
      await _send(
        (SshWriter()
              ..byte(90)
              ..text('session')
              ..uint32(channel.local)
              ..uint32(SshExecChannel.windowSize)
              ..uint32(SshExecChannel.packetSize))
            .take(),
      );
      await channel._opened.future;
      channel._execSent = true;
      await _send(
        (SshWriter()
              ..byte(98)
              ..uint32(channel.remote!)
              ..text('subsystem')
              ..byte(1)
              ..text(name))
            .take(),
      );
      await channel._accepted.future;
      channel._timer?.cancel();
      return channel;
    } catch (e) {
      channel._fail(
        e is SshException ? e.message : 'SSH subsystem could not start.',
      );
      rethrow;
    }
  }
}
