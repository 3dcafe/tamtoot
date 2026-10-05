import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import '../crypto/ssh_crypto.dart';
import '../host_keys/ssh_host_keys.dart';
import '../ssh_error.dart';
import 'ssh_codec.dart';
import 'ssh_packet.dart';
import 'ssh_wire.dart';

enum SshTransportState {
  idle,
  connecting,
  exchangingKeys,
  awaitingTrust,
  ready,
  rekeying,
  closed,
}

class SshCancellation {
  final _done = Completer<void>();
  bool get cancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}

typedef SshWireOpener =
    Future<SshWire> Function(
      String host,
      int port,
      SshCancellation cancellation,
    );
typedef SshTrustConfirmation =
    Future<SshHostKeyDecision> Function(SshHostKeyChallenge challenge);

class SshTransport {
  SshTransport({
    required this.crypto,
    required this.hostKeys,
    required this.openWire,
  }) : incoming = SshPacketCodec(crypto),
       outgoing = SshPacketCodec(crypto) {
    unawaited(cancellation.whenCancelled.then((_) => close()));
  }
  final SshCrypto crypto;
  final SshHostKeys hostKeys;
  final SshWireOpener openWire;
  final SshPacketCodec incoming, outgoing;
  final cancellation = SshCancellation();
  final _states = StreamController<SshTransportState>.broadcast(sync: true);
  late final _messages = StreamController<Uint8List>(
    sync: true,
    onPause: () => _deliveryPaused = true,
    onResume: () {
      _deliveryPaused = false;
      _drainMessages();
    },
  );
  bool _deliveryPaused = false;
  Stream<SshTransportState> get states => _states.stream;
  Stream<Uint8List> get messages => _messages.stream;
  SshTransportState state = SshTransportState.idle;
  String? error;
  String serverVersion = '';
  SshHostKey? serverKey;

  /// Public session identifier used by the upper authentication protocol.
  Uint8List get sessionIdentifier {
    _checkOpen();
    if (_sessionId == null) {
      throw const SshException('SSH session is not established.');
    }
    return Uint8List.fromList(_sessionId!);
  }

  Uint8List? _sessionId;
  bool _authenticated = false;
  Uint8List? _clientKex;
  Completer<void>? _rekeyDone;
  Timer? _rekeyDeadline, _rekeyTimer;
  final List<Uint8List> _deferred = [];
  int _deferredBytes = 0, _pendingWrites = 0;
  Future<void> _writeTail = Future.value();
  SshWire? _wire;
  String _host = '';
  int _port = 22;
  SshTrustConfirmation? _confirm;
  static const clientVersion = 'SSH-2.0-TamToot_0.1';
  void _setState(SshTransportState value) {
    if (state == SshTransportState.closed) return;
    state = value;
    _states.add(value);
  }

  void _checkOpen() {
    if (cancellation.cancelled || state == SshTransportState.closed) {
      throw const SshException('SSH connection was cancelled or closed.');
    }
  }

  Future<void> connect(
    String host,
    int port, {
    required SshTrustConfirmation confirm,
  }) async {
    if (state != SshTransportState.idle || port < 1 || port > 65535) {
      throw const SshException('Invalid SSH connection state or port.');
    }
    _host = normalizeSshHost(host);
    _port = port;
    _confirm = confirm;
    _setState(SshTransportState.connecting);
    try {
      await hostKeys.restore();
      _checkOpen();
      final wire = await openWire(_host, port, cancellation);
      if (cancellation.cancelled) {
        await wire.close();
        _checkOpen();
      }
      _wire = wire;
      await wire
          .write(ascii.encode('$clientVersion\r\n'))
          .timeout(const Duration(seconds: 10));
      serverVersion = await _readVersion().timeout(const Duration(seconds: 10));
      _checkOpen();
      _setState(SshTransportState.exchangingKeys);
      final local = _makeKex();
      await _sendTransport(local);
      final remote = await _expected(20);
      if (incoming.sequence != 1 || outgoing.sequence != 1) {
        throw const SshException(
          'Strict SSH key exchange must start with KEXINIT.',
        );
      }
      await _exchange(remote, local, initial: true);
      _checkOpen();
      _setState(SshTransportState.ready);
      _scheduleRekey();
      unawaited(_pump());
    } catch (e) {
      final failure = _failure(e);
      error = failure.message;
      await close();
      throw failure;
    }
  }

  SshException _failure(Object e) => e is SshException
      ? e
      : e is TimeoutException
      ? const SshException('SSH operation timed out.')
      : const SshException('SSH transport operation failed.');
  Future<String> _readVersion() async {
    var total = 0;
    for (var line = 0; line < 32; line++) {
      final bytes = <int>[];
      while (true) {
        final b = (await _wire!.read(1))[0];
        total++;
        if (total > 8192 || (b != 10 && bytes.length >= 254)) {
          throw const SshException(
            'SSH server identification exceeds its limit.',
          );
        }
        if (b == 10) break;
        bytes.add(b);
      }
      if (bytes.isNotEmpty && bytes.last == 13) bytes.removeLast();
      if (bytes.length >= 4 &&
          ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'SSH-') {
        if (bytes.any((b) => b < 32 || b > 126)) {
          throw const SshException('Invalid SSH server identification.');
        }
        final version = ascii.decode(bytes);
        if (!RegExp(r'^SSH-2\.0-[!-~]+(?: .*)?$').hasMatch(version)) {
          throw const SshException(
            'SSH server does not support the required protocol version.',
          );
        }
        return version;
      }
    }
    throw const SshException('SSH server identification was not received.');
  }

  Uint8List _makeKex() =>
      (SshWriter()
            ..byte(20)
            ..raw(crypto.randomBytes(16))
            ..names([
              'curve25519-sha256',
              if (_sessionId == null) 'kex-strict-c-v00@openssh.com',
            ])
            ..names(['ssh-ed25519'])
            ..names(['aes256-ctr'])
            ..names(['aes256-ctr'])
            ..names(['hmac-sha2-256-etm@openssh.com'])
            ..names(['hmac-sha2-256-etm@openssh.com'])
            ..names(['none'])
            ..names(['none'])
            ..names([])
            ..names([])
            ..byte(0)
            ..uint32(0))
          .take();
  Future<Uint8List> _readPacket({bool allowIdle = false}) async {
    _checkOpen();
    final pending = incoming.read(_wire!, allowIdle: allowIdle);
    final packet = allowIdle
        ? await pending
        : await pending.timeout(const Duration(seconds: 30));
    _checkOpen();
    if (packet[0] == 1) {
      final reader = SshReader(packet)..byte();
      final reason = reader.uint32();
      reader.string();
      reader.string();
      reader.end();
      throw SshException('SSH server disconnected (reason $reason).');
    }
    return packet;
  }

  Future<Uint8List> _expected(
    int type, {
    bool allowDataBeforeKex = false,
  }) async {
    while (true) {
      final packet = await _readPacket();
      if (packet[0] == type) return packet;
      if (allowDataBeforeKex && packet[0] >= 50) {
        _deferredBytes += packet.length;
        if (_deferredBytes > 1024 * 1024) {
          throw const SshException('SSH rekey data buffer limit exceeded.');
        }
        _deferred.add(packet);
        continue;
      }
      throw const SshException(
        'Unexpected message during strict SSH key exchange.',
      );
    }
  }

  Future<void> _exchange(
    Uint8List remote,
    Uint8List local, {
    required bool initial,
  }) async {
    _checkOpen();
    final reader = SshReader(remote);
    if (reader.byte() != 20) throw const SshException('Expected SSH KEXINIT.');
    reader.raw(16);
    final kex = reader.names(), hosts = reader.names();
    final encryptOut = reader.names(), encryptIn = reader.names();
    final macOut = reader.names(), macIn = reader.names();
    final compressionOut = reader.names(), compressionIn = reader.names();
    reader.names();
    reader.names();
    final follows = reader.boolean();
    final reserved = reader.uint32();
    reader.end();
    if (!kex.contains('curve25519-sha256') ||
        (initial && !kex.contains('kex-strict-s-v00@openssh.com')) ||
        !hosts.contains('ssh-ed25519') ||
        !encryptOut.contains('aes256-ctr') ||
        !encryptIn.contains('aes256-ctr') ||
        !macOut.contains('hmac-sha2-256-etm@openssh.com') ||
        !macIn.contains('hmac-sha2-256-etm@openssh.com') ||
        !compressionOut.contains('none') ||
        !compressionIn.contains('none') ||
        reserved != 0) {
      throw const SshException(
        'SSH server has no compatible algorithms or strict key exchange support.',
      );
    }
    final exchange = crypto.createExchange();
    Uint8List? shared, encodedSecret;
    final material = <Uint8List>[];
    SshCipher? newOut, newIn;
    try {
      final clientPublic = exchange.publicKey;
      await _sendTransport(
        (SshWriter()
              ..byte(30)
              ..string(clientPublic))
            .take(),
      );
      final realKex = kex
          .where(
            (name) =>
                !name.startsWith('kex-strict-') &&
                !name.startsWith('ext-info-'),
          )
          .first;
      if (follows &&
          (realKex != 'curve25519-sha256' || hosts.first != 'ssh-ed25519')) {
        await _readPacket();
      }
      final response = SshReader(await _expected(31));
      response.byte();
      final blob = response.string(limit: 1024),
          serverPublic = response.string(limit: 32),
          signatureBlob = response.string(limit: 1024);
      response.end();
      if (serverPublic.length != 32) {
        throw const SshException('Malformed SSH exchange key.');
      }
      final key = SshHostKey(blob, crypto);
      final signature = SshReader(signatureBlob);
      if (signature.asciiText(limit: 128) != 'ssh-ed25519') {
        throw const SshException('Unsupported SSH server signature.');
      }
      final signatureBytes = signature.string(limit: 64);
      signature.end();
      shared = exchange.sharedSecret(serverPublic);
      // RFC 8731: reinterpret X25519 output bytes in network order for SSH mpint.
      encodedSecret = (SshWriter()..mpint(shared)).take();
      final transcript =
          (SshWriter()
                ..text(clientVersion)
                ..text(serverVersion)
                ..string(local)
                ..string(remote)
                ..string(blob)
                ..string(clientPublic)
                ..string(serverPublic)
                ..raw(encodedSecret))
              .take();
      final hash = crypto.sha256(transcript);
      transcript.fillRange(0, transcript.length, 0);
      if (!sshVerifyEd25519(crypto, key.publicKey, hash, signatureBytes)) {
        throw const SshException('SSH server signature verification failed.');
      }
      if (serverKey == null || !sshBytesEqual(serverKey!.blob, blob)) {
        if (initial) _setState(SshTransportState.awaitingTrust);
        await hostKeys.verify(_host, _port, key, crypto, (challenge) async {
          final decision = await Future.any([
            _confirm!(challenge),
            cancellation.whenCancelled.then<SshHostKeyDecision>(
              (_) => throw const SshException('SSH connection cancelled.'),
            ),
          ]).timeout(const Duration(minutes: 5));
          _checkOpen();
          return decision;
        });
        _checkOpen();
      }
      serverKey = key;
      _sessionId ??= Uint8List.fromList(hash);
      Uint8List derive(int label, int length) {
        final input =
            (SshWriter()
                  ..raw(encodedSecret!)
                  ..raw(hash)
                  ..byte(label)
                  ..raw(_sessionId!))
                .take();
        try {
          final result = Uint8List.fromList(
            crypto.sha256(input).sublist(0, length),
          );
          material.add(result);
          return result;
        } finally {
          input.fillRange(0, input.length, 0);
        }
      }

      final ivOut = derive(65, 16), ivIn = derive(66, 16);
      final keyOut = derive(67, 32), keyIn = derive(68, 32);
      final authOut = derive(69, 32), authIn = derive(70, 32);
      newOut = crypto.createCipher(keyOut, ivOut);
      newIn = crypto.createCipher(keyIn, ivIn);
      await _sendTransport([21]);
      outgoing.activate(newOut, authOut);
      newOut = null;
      final newKeys = SshReader(await _expected(21));
      newKeys.byte();
      newKeys.end();
      incoming.activate(newIn, authIn);
      newIn = null;
    } finally {
      exchange.dispose();
      newOut?.dispose();
      newIn?.dispose();
      shared?.fillRange(0, shared.length, 0);
      encodedSecret?.fillRange(0, encodedSecret.length, 0);
      for (final key in material) {
        key.fillRange(0, key.length, 0);
      }
    }
  }

  Future<void> _sendTransport(List<int> payload) {
    _checkOpen();
    final copy = Uint8List.fromList(payload);
    _pendingWrites += copy.length;
    if (_pendingWrites > 1024 * 1024) {
      _pendingWrites -= copy.length;
      throw const SshException('SSH outgoing queue limit exceeded.');
    }
    final task = _writeTail.then((_) async {
      _checkOpen();
      await _wire!
          .write(outgoing.encode(copy))
          .timeout(const Duration(seconds: 30));
    });
    _writeTail = task.then((_) {}, onError: (Object _, StackTrace _) {});
    return task.whenComplete(() {
      _pendingWrites -= copy.length;
      copy.fillRange(0, copy.length, 0);
    });
  }

  /// The upper protocol may send only after signature and host trust verification.
  Future<void> send(List<int> payload) async {
    _checkOpen();
    if (state != SshTransportState.ready &&
        state != SshTransportState.rekeying) {
      throw const SshException('SSH server is not yet verified.');
    }
    if (payload.isEmpty ||
        payload[0] < 5 ||
        payload[0] == 20 ||
        payload[0] == 21 ||
        payload[0] == 30 ||
        payload[0] == 31) {
      throw const SshException('Invalid SSH application message.');
    }
    if (_authenticated && (outgoing.needsRekey || incoming.needsRekey)) {
      await rekey();
    }
    if (state == SshTransportState.rekeying) await _rekeyDone!.future;
    _checkOpen();
    try {
      await _sendTransport(payload);
    } catch (e) {
      error = _failure(e).message;
      await close();
      rethrow;
    }
  }

  Future<void> rekey() async {
    _checkOpen();
    if (state == SshTransportState.rekeying) return _rekeyDone!.future;
    if (state != SshTransportState.ready) {
      throw const SshException('SSH transport is not ready to rekey.');
    }
    _beginRekey();
    _clientKex = _makeKex();
    final completion = _rekeyDone!.future;
    try {
      await _sendTransport(_clientKex!);
      await completion;
    } catch (e) {
      error = _failure(e).message;
      await close();
      rethrow;
    }
  }

  /// Call only after the upper protocol receives SSH_MSG_USERAUTH_SUCCESS.
  /// OpenSSH rejects client-initiated rekey during authentication.
  void authenticationSucceeded() {
    _checkOpen();
    if (state != SshTransportState.ready &&
        state != SshTransportState.rekeying) {
      throw const SshException(
        'SSH transport is not ready for authentication.',
      );
    }
    _authenticated = true;
    _scheduleRekey();
  }

  void _beginRekey() {
    _rekeyDone = Completer<void>();
    // Attach an observer even for a server-initiated exchange with no caller.
    unawaited(
      _rekeyDone!.future.then((_) {}, onError: (Object _, StackTrace _) {}),
    );
    _setState(SshTransportState.rekeying);
    _rekeyDeadline?.cancel();
    _rekeyDeadline = Timer(const Duration(seconds: 30), () {
      error = 'SSH rekey timed out.';
      unawaited(close());
    });
  }

  void _scheduleRekey() {
    _rekeyTimer?.cancel();
    if (!_authenticated) {
      return;
    }
    _rekeyTimer = Timer(const Duration(hours: 1), () {
      if (state == SshTransportState.ready) {
        unawaited(rekey().then((_) {}, onError: (Object _, StackTrace _) {}));
      }
    });
  }

  Future<void> _pump() async {
    try {
      while (state != SshTransportState.closed) {
        final packet = await _readPacket(allowIdle: true);
        if (packet[0] == 20) {
          if (state != SshTransportState.rekeying) _beginRekey();
          final local = _clientKex ?? _makeKex();
          if (_clientKex == null) await _sendTransport(local);
          await _exchange(packet, local, initial: false);
          _clientKex = null;
          _checkOpen();
          _rekeyDeadline?.cancel();
          final completedRekey = _rekeyDone!;
          _rekeyDone = null;
          _setState(SshTransportState.ready);
          completedRekey.complete();
          _scheduleRekey();
          _drainMessages();
        } else if (packet[0] == 2 || packet[0] == 4) {
          final reader = SshReader(packet);
          final kind = reader.byte();
          if (kind == 4) reader.boolean();
          reader.string();
          if (kind == 4) reader.string();
          reader.end();
        } else if (state == SshTransportState.rekeying) {
          if (packet[0] < 5 ||
              packet[0] == 21 ||
              packet[0] == 30 ||
              packet[0] == 31) {
            throw SshException(
              'Unexpected message ${packet[0]} while waiting for SSH rekey.',
            );
          }
          _deferredBytes += packet.length;
          if (_deferredBytes > 1024 * 1024) {
            throw const SshException('SSH rekey data buffer limit exceeded.');
          }
          _deferred.add(packet);
        } else if (packet[0] == 3) {
          throw const SshException('SSH server rejected a transport message.');
        } else if (packet[0] == 21 ||
            packet[0] == 30 ||
            packet[0] == 31 ||
            packet[0] < 5) {
          throw const SshException('Unexpected SSH transport message.');
        } else {
          _deliver(packet);
        }
        if (_authenticated &&
            state == SshTransportState.ready &&
            (incoming.needsRekey || outgoing.needsRekey)) {
          unawaited(rekey().then((_) {}, onError: (Object _, StackTrace _) {}));
        }
      }
    } catch (e) {
      if (state != SshTransportState.closed) error = _failure(e).message;
      await close();
    }
  }

  void _deliver(Uint8List packet) {
    if (!_messages.hasListener) {
      throw const SshException('Unexpected SSH application message.');
    }
    if (_deliveryPaused || state == SshTransportState.rekeying) {
      _deferredBytes += packet.length;
      if (_deferredBytes > 1024 * 1024) {
        throw const SshException('SSH application buffer limit exceeded.');
      }
      _deferred.add(packet);
    } else {
      _messages.add(packet);
    }
  }

  void _drainMessages() {
    while (!_deliveryPaused &&
        state == SshTransportState.ready &&
        _deferred.isNotEmpty) {
      final packet = _deferred.removeAt(0);
      _deferredBytes -= packet.length;
      _deliver(packet);
    }
  }

  Future<void> close() async {
    if (state == SshTransportState.closed) return;
    cancellation.cancel();
    _rekeyDeadline?.cancel();
    _rekeyTimer?.cancel();
    _setState(SshTransportState.closed);
    final pending = _rekeyDone;
    _rekeyDone = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(SshException(error ?? 'SSH connection closed.'));
    }
    final wire = _wire;
    _wire = null;
    if (wire != null) await wire.close();
    incoming.dispose();
    outgoing.dispose();
    _sessionId?.fillRange(0, _sessionId!.length, 0);
    _deferred.clear();
    _deferredBytes = 0;
    unawaited(_states.close());
    unawaited(_messages.close());
  }
}
