import 'dart:async';
import 'dart:typed_data';
import 'package:tamtoot/core/ssh/crypto/ssh_crypto.dart';
import 'package:tamtoot/core/ssh/host_keys/ssh_host_keys.dart';
import 'package:tamtoot/core/ssh/ssh_error.dart';
import 'package:tamtoot/core/ssh/transport/ssh_codec.dart';
import 'package:tamtoot/core/ssh/transport/ssh_transport.dart';

class ProtocolDisplayCrypto implements SshCrypto {
  int _nonce = 0;
  @override
  Uint8List randomBytes(int length) =>
      Uint8List.fromList(List.generate(length, (i) => (i + ++_nonce) & 255));
  @override
  Uint8List sha256(List<int> bytes) => Uint8List(32);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class ProtocolTransport implements SshTransport {
  ProtocolTransport({this.trustRequired = false}) {
    state = trustRequired ? SshTransportState.idle : SshTransportState.ready;
    verified = !trustRequired;
  }
  final bool trustRequired;
  bool verified = false, authenticated = false, closed = false;
  @override
  SshTransportState state = SshTransportState.ready;
  @override
  String? error;
  @override
  final crypto = ProtocolDisplayCrypto();
  @override
  final cancellation = SshCancellation();
  final incomingMessages = StreamController<Uint8List>(sync: true);
  final stateMessages = StreamController<SshTransportState>.broadcast(
    sync: true,
  );
  final sent = <Uint8List>[];
  void Function(Uint8List)? onSend;
  final key = SshHostKey(
    (SshWriter()
          ..text('ssh-ed25519')
          ..string(Uint8List(32)))
        .take(),
    ProtocolDisplayCrypto(),
  );
  @override
  SshHostKey? get serverKey => verified ? key : null;
  @override
  Stream<Uint8List> get messages => incomingMessages.stream;
  @override
  Stream<SshTransportState> get states => stateMessages.stream;
  @override
  Uint8List get sessionIdentifier =>
      Uint8List.fromList(List.generate(32, (i) => i));
  void emit(List<int> packet) {
    scheduleMicrotask(() {
      if (!closed) incomingMessages.add(Uint8List.fromList(packet));
    });
  }

  @override
  Future<void> send(List<int> packet) async {
    if (closed || !verified) {
      throw const SshException('Test transport not verified.');
    }
    final copy = Uint8List.fromList(packet);
    sent.add(copy);
    onSend?.call(copy);
  }

  @override
  Future<void> connect(
    String host,
    int port, {
    required SshTrustConfirmation confirm,
  }) async {
    if (trustRequired) {
      state = SshTransportState.awaitingTrust;
      stateMessages.add(state);
      final decision = await confirm(SshHostKeyChallenge(host, port, key, []));
      if (decision == SshHostKeyDecision.reject || cancellation.cancelled) {
        await close();
        throw const SshException('Server trust rejected.');
      }
    }
    verified = true;
    state = SshTransportState.ready;
    stateMessages.add(state);
  }

  @override
  void authenticationSucceeded() {
    authenticated = true;
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    cancellation.cancel();
    state = SshTransportState.closed;
    stateMessages.add(state);
    unawaited(incomingMessages.close());
    unawaited(stateMessages.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Test protocol only; no private scalar. Native signatures have separate vectors.
class ProtocolSigner implements SshSigner {
  bool disposed = false;
  final algorithms = <String>[];
  Uint8List? message;
  @override
  Future<Uint8List> sign(List<int> data, String algorithm) async {
    algorithms.add(algorithm);
    message = Uint8List.fromList(data);
    return Uint8List(64);
  }

  @override
  void dispose() {
    disposed = true;
  }
}
