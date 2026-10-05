import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/ssh/crypto/ssh_crypto.dart';
import 'package:tamtoot/core/ssh/host_keys/ssh_host_keys.dart';
import 'package:tamtoot/core/ssh/transport/ssh_codec.dart';
import 'package:tamtoot/features/ssh_connection_dialog.dart';

// UI fixture only; cryptographic correctness is tested with native vectors.
class DisplayCrypto implements SshCrypto {
  @override
  Uint8List sha256(List<int> bytes) => Uint8List(32);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  for (final changed in [false, true]) {
    testWidgets('host key dialog requires explicit trust, changed=$changed', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = SshHostKey(
        (SshWriter()
              ..text('ssh-ed25519')
              ..string(Uint8List(32)))
            .take(),
        DisplayCrypto(),
      );
      final challenge = SshHostKeyChallenge(
        'example.org',
        22,
        key,
        changed ? ['SHA256:previous-test-key'] : [],
      );
      SshHostKeyDecision? decision;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  decision = await showSshHostKeyTrust(context, challenge);
                },
                child: const Text('Connect'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('example.org:22'), findsOneWidget);
      expect(find.text(key.fingerprint), findsOneWidget);
      expect(decision, isNull);
      expect(tester.takeException(), isNull);
      if (changed) {
        expect(find.text('SHA256:previous-test-key'), findsOneWidget);
        expect(find.text('Replace saved keys'), findsOneWidget);
      }
      await tester.tap(find.text('Trust once'));
      await tester.pumpAndSettle();
      expect(decision, SshHostKeyDecision.once);
      expect(tester.takeException(), isNull);
    });
  }
}
