import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/ssh/host_keys/ssh_host_keys.dart';
import 'package:tamtoot/core/ssh/transport/ssh_transport.dart';
import 'package:tamtoot/core/ssh/transport/ssh_codec.dart';
import 'package:tamtoot/platform/ssh_wire_io.dart';
import 'ssh_native_support.dart';
import 'support.dart';

void main() {
  test(
    'opt-in LAN SSH handshake and advertised authentication methods',
    () async {
      final native = await buildSshTestCrypto();
      final transport = SshTransport(
        crypto: native.crypto,
        hostKeys: SshHostKeys(MemoryStore()),
        openWire: openSshWire,
      );
      final messages = StreamIterator(transport.messages);
      try {
        await transport.connect(
          Platform.environment['TAMTOOT_SSH_DIAGNOSTIC_HOST']!,
          22,
          confirm: (_) async => SshHostKeyDecision.once,
        );
        await transport.send(
          (SshWriter()
                ..byte(5)
                ..text('ssh-userauth'))
              .take(),
        );
        expect(
          await messages.moveNext().timeout(const Duration(seconds: 10)),
          true,
        );
        expect(messages.current[0], 6);
        await transport.send(
          (SshWriter()
                ..byte(50)
                ..text(
                  Platform.environment['TAMTOOT_SSH_DIAGNOSTIC_USER'] ??
                      'diagnostic',
                )
                ..text('ssh-connection')
                ..text('none'))
              .take(),
        );
        expect(
          await messages.moveNext().timeout(const Duration(seconds: 10)),
          true,
        );
        // No password, private key, shell or remote command is sent.
        expect(messages.current[0], 51);
      } finally {
        await messages.cancel();
        await transport.close();
        await native.directory?.delete(recursive: true);
      }
    },
    skip: Platform.environment['TAMTOOT_SSH_DIAGNOSTIC_HOST'] == null,
  );
}
