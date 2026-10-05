import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/ssh/ssh_profiles.dart';
import 'package:tamtoot/core/ssh/transport/ssh_codec.dart';
import 'package:tamtoot/features/ssh_connection_dialog.dart';
import 'ssh_client_support.dart';
import 'support.dart';

void main() {
  testWidgets(
    'trust, password, remote command and separate output at phone width',
    (tester) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = await testSession();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        final disposing = session.dispose();
        await tester.pumpAndSettle();
        await disposing;
      });
      final profile = SshProfile(
        id: SshProfiles.newId(),
        name: 'Test server',
        host: 'example.org',
        port: 22,
        username: 'alice',
        authentication: SshAuthentication.password,
      );
      await session.sshProfiles.save(profile);
      final wire = ProtocolTransport(trustRequired: true);
      addTearDown(wire.close);
      wire.onSend = (bytes) {
        final r = SshReader(bytes), type = r.byte();
        if (type == 5) {
          expect(r.asciiText(), 'ssh-userauth');
          wire.emit(
            (SshWriter()
                  ..byte(6)
                  ..text('ssh-userauth'))
                .take(),
          );
        } else if (type == 50) {
          r.asciiText();
          r.asciiText();
          final method = r.asciiText();
          if (method == 'none') {
            wire.emit(
              (SshWriter()
                    ..byte(51)
                    ..names(['password'])
                    ..byte(0))
                  .take(),
            );
          } else {
            expect(method, 'password');
            expect(r.boolean(), isFalse);
            expect(utf8.decode(r.string()), 'test-only-password');
            wire.emit([52]);
          }
        } else if (type == 90) {
          r.asciiText();
          final local = r.uint32();
          wire.emit(
            (SshWriter()
                  ..byte(91)
                  ..uint32(local)
                  ..uint32(7)
                  ..uint32(100000)
                  ..uint32(32768))
                .take(),
          );
        } else if (type == 98) {
          r.uint32();
          expect(r.asciiText(), 'exec');
          expect(r.boolean(), isTrue);
          expect(utf8.decode(r.string()), 'test-command');
          wire.emit(
            (SshWriter()
                  ..byte(99)
                  ..uint32(0))
                .take(),
          );
          wire.emit(
            (SshWriter()
                  ..byte(94)
                  ..uint32(0)
                  ..string(utf8.encode('результат')))
                .take(),
          );
          wire.emit(
            (SshWriter()
                  ..byte(95)
                  ..uint32(0)
                  ..uint32(1)
                  ..string(utf8.encode('test-stderr')))
                .take(),
          );
          wire.emit(
            (SshWriter()
                  ..byte(98)
                  ..uint32(0)
                  ..text('exit-status')
                  ..byte(0)
                  ..uint32(7))
                .take(),
          );
          wire.emit(
            (SshWriter()
                  ..byte(96)
                  ..uint32(0))
                .take(),
          );
          wire.emit(
            (SshWriter()
                  ..byte(97)
                  ..uint32(0))
                .take(),
          );
        }
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SshConnectionDialog(
              session: session,
              profile: profile,
              createTransport: () => wire,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Trust SSH server?'), findsOneWidget);
      expect(find.text('SSH password'), findsNothing);
      expect(wire.sent, isEmpty);
      await tester.tap(find.text('Trust once'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('SSH password'), findsOneWidget);
      final password = tester.widget<TextField>(find.byType(TextField));
      expect(password.obscureText, isTrue);
      await tester.enterText(find.byType(TextField), 'test-only-password');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Signed in as alice'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'test-command');
      await tester.tap(find.text('Run command'));
      await tester.pumpAndSettle();
      expect(find.text('результат'), findsOneWidget);
      expect(find.text('test-stderr'), findsOneWidget);
      expect(find.text('Exit code: 7'), findsOneWidget);
      expect(
        await session.store.read('ssh.profiles'),
        isNot(contains('test-only-password')),
      );
      expect(
        await session.store.read('ssh.profiles'),
        isNot(contains('test-command')),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'cancelled password prompt leaves explicit retry, no automatic auth loop',
    (tester) async {
      final session = await testSession();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        final disposing = session.dispose();
        await tester.pumpAndSettle();
        await disposing;
      });
      final wire = ProtocolTransport();
      addTearDown(wire.close);
      wire.onSend = (bytes) {
        if (bytes[0] == 5) {
          wire.emit(
            (SshWriter()
                  ..byte(6)
                  ..text('ssh-userauth'))
                .take(),
          );
        } else {
          wire.emit(
            (SshWriter()
                  ..byte(51)
                  ..names(['password'])
                  ..byte(0))
                .take(),
          );
        }
      };
      final profile = SshProfile(
        id: SshProfiles.newId(),
        name: 'Test',
        host: 'example.org',
        port: 22,
        username: 'alice',
        authentication: SshAuthentication.password,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SshConnectionDialog(
              session: session,
              profile: profile,
              createTransport: () => wire,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('SSH password'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Sign in'), findsOneWidget);
      expect(wire.sent.where((p) => p[0] == 50), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
