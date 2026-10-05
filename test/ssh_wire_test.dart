import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/ssh/ssh_error.dart';
import 'package:tamtoot/core/ssh/transport/ssh_transport.dart';
import 'package:tamtoot/platform/ssh_wire_io.dart';

void main() {
  test(
    'native TCP reads fragments and coalesced data without losing bytes',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final peerFuture = server.first;
      final wire = await openSshWire(
        '127.0.0.1',
        server.port,
        SshCancellation(),
      );
      final peer = await peerFuture;
      try {
        final reading = wire.read(8);
        for (var i = 0; i < 8; i++) {
          peer.add([i]);
          await peer.flush();
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        expect(await reading, orderedEquals(List.generate(8, (i) => i)));
        peer.add([8, 9, 10, 11]);
        await peer.flush();
        expect(await wire.read(2), orderedEquals([8, 9]));
        expect(await wire.read(2), orderedEquals([10, 11]));
        final pending = wire.read(4);
        final rejected = expectLater(pending, throwsA(isA<SshException>()));
        await wire.close();
        await rejected;
      } finally {
        await wire.close();
        peer.destroy();
        await server.close();
      }
    },
  );

  test(
    'TCP cancellation racing connection observes late socket errors',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final cancellation = SshCancellation();
      final connecting = openSshWire('127.0.0.1', server.port, cancellation);
      final rejected = expectLater(connecting, throwsA(isA<SshException>()));
      cancellation.cancel();
      try {
        await rejected;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      } finally {
        await server.close();
      }
    },
  );
  test('cancelled TCP connection cannot return a live socket', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final cancellation = SshCancellation()..cancel();
    try {
      await expectLater(
        openSshWire('127.0.0.1', server.port, cancellation),
        throwsA(isA<SshException>()),
      );
    } finally {
      await server.close();
    }
  });
}
