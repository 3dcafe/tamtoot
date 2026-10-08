import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/ssh/ssh_client.dart';
import 'package:tamtoot/core/ssh/ssh_error.dart';
import 'package:tamtoot/core/ssh/transport/ssh_codec.dart';
import 'package:tamtoot/core/ssh/transport/ssh_transport.dart';
import 'ssh_client_support.dart';
import 'ssh_client_protocol_test.dart' show ready;

void shellScript(ProtocolTransport wire, {bool pty = true, bool shell = true}) {
  wire.onSend = (bytes) {
    final r = SshReader(bytes), type = r.byte();
    if (type == 90) {
      expect(r.asciiText(), 'session');
      final id = r.uint32();
      r.uint32();
      r.uint32();
      r.end();
      wire.emit(
        (SshWriter()
              ..byte(91)
              ..uint32(id)
              ..uint32(7)
              ..uint32(262144)
              ..uint32(32768))
            .take(),
      );
    } else if (type == 98) {
      expect(r.uint32(), 7);
      final name = r.asciiText(), reply = r.boolean();
      if (name == 'pty-req') {
        expect(reply, true);
        expect(r.asciiText(), SshShellChannel.terminalType);
        expect(r.uint32(), 80);
        expect(r.uint32(), 24);
        expect(r.uint32(), 0);
        expect(r.uint32(), 0);
        expect(r.string(), [0]);
        r.end();
        wire.emit(
          (SshWriter()
                ..byte(pty ? 99 : 100)
                ..uint32(0))
              .take(),
        );
      } else if (name == 'shell') {
        expect(reply, true);
        r.end();
        wire.emit(
          (SshWriter()
                ..byte(shell ? 99 : 100)
                ..uint32(0))
              .take(),
        );
      } else if (name == 'window-change') {
        expect(reply, false);
        expect(r.uint32(), 83);
        expect(r.uint32(), 25);
        r.uint32();
        r.uint32();
        r.end();
      }
    } else if (type == 94) {
      r.uint32();
      r.string();
      r.end();
    } else if (type == 97) {
      wire.emit(
        (SshWriter()
              ..byte(97)
              ..uint32(0))
            .take(),
      );
    }
  };
}

void main() {
  test(
    'PTY then shell; streaming beyond exec limit, resize and graceful exit',
    () async {
      final wire = ProtocolTransport(), client = await ready(wire);
      addTearDown(client.close);
      shellScript(wire);
      var received = 0;
      final channel = await client.openShell(
        columns: 80,
        rows: 24,
        onOutput: (o) => received += o.data.length,
      );
      await channel.resize(83, 25);
      await channel.writeStdin([3, 65, 13]);
      for (var i = 0; i < 70; i++) {
        wire.emit(
          (SshWriter()
                ..byte(94)
                ..uint32(0)
                ..string(Uint8List(32768)))
              .take(),
        );
        await Future<void>.delayed(Duration.zero);
      }
      expect(received, 70 * 32768);
      expect(client.state, SshClientState.ready);
      wire.emit(
        (SshWriter()
              ..byte(97)
              ..uint32(0))
            .take(),
      );
      final result = await channel.result;
      expect(result.stdout, isEmpty);
      expect(result.exitStatus, null);
    },
  );
  for (final refusePty in [true, false]) {
    test(
      'refused ${refusePty ? 'PTY' : 'shell'} does not leave an input channel',
      () async {
        final wire = ProtocolTransport(), client = await ready(wire);
        addTearDown(client.close);
        shellScript(wire, pty: !refusePty, shell: false);
        await expectLater(
          client.openShell(columns: 80, rows: 24, onOutput: (_) {}),
          throwsA(isA<SshException>()),
        );
        if (refusePty) expect(wire.sent.where((p) => p[0] == 98).length, 1);
        expect(client.state, SshClientState.ready);
      },
    );
  }
  test('invalid dimensions, pre-cancellation and transport loss', () async {
    final wire = ProtocolTransport(), client = await ready(wire);
    addTearDown(client.close);
    shellScript(wire);
    await expectLater(
      client.openShell(columns: 1000, rows: 24, onOutput: (_) {}),
      throwsA(isA<SshException>()),
    );
    final cancel = SshCancellation()..cancel();
    await expectLater(
      client.openShell(
        columns: 80,
        rows: 24,
        onOutput: (_) {},
        cancellation: cancel,
      ),
      throwsA(isA<SshException>()),
    );
    // The cancelled allocation consumed id 0; use a fresh connection for the mock.
    await client.close();
    final other = ProtocolTransport(), protocol = await ready(other);
    addTearDown(protocol.close);
    shellScript(other);
    final channel = await protocol.openShell(
      columns: 80,
      rows: 24,
      onOutput: (_) {},
    );
    final result = expectLater(channel.result, throwsA(isA<SshException>()));
    await protocol.close();
    await result;
  });
}
