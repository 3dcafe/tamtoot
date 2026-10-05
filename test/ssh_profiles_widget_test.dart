import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/filesystem/filesystem.dart';
import 'package:tamtoot/core/ssh/ssh_profiles.dart';
import 'package:tamtoot/features/ssh_profiles_settings.dart';
import 'package:tamtoot/platform/ssh_secrets/native_ssh_secrets.dart';
import 'ssh_profiles_test.dart' show keyFixture;
import 'support.dart';

class KeyDialogs extends FakeDialogs {
  @override
  Future<FileEntry?> open() async =>
      FileEntry(Uri.parse('memory:///key'), 'key');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeSshSecrets.channel, (_) async => false);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeSshSecrets.channel, null);
  });
  testWidgets(
    'SSH CRUD at phone width; secrets are obscured and excluded from preferences',
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
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SshProfilesSettings(session: session),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Secure storage is unavailable'),
        findsOneWidget,
      );
      await tester.tap(find.text('Add SSH profile'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Production');
      await tester.enterText(fields.at(1), 'server.example');
      await tester.enterText(fields.at(3), 'root');
      await tester.enterText(fields.at(4), 'hidden-marker');
      expect(tester.widget<TextField>(fields.at(4)).obscureText, isTrue);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Production'), findsOneWidget);
      expect(
        await session.store.read('ssh.profiles'),
        isNot(contains('hidden-marker')),
      );
      await tester.tap(find.text('Production'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).at(4)).controller!.text,
        isEmpty,
      );
      await tester.enterText(find.byType(TextField).first, 'Renamed');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Renamed'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(session.sshProfiles.profiles, hasLength(1));
      await tester.tap(find.byTooltip('Delete profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(session.sshProfiles.profiles, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'imports an Ed25519 key through platform file dialogs into session storage',
    (tester) async {
      final files = MemoryFileSystem();
      files.files[Uri.parse('memory:///key')] = keyFixture();
      final session = await testSession(files: files, dialogs: KeyDialogs());
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        final disposing = session.dispose();
        await tester.pumpAndSettle();
        await disposing;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SshProfilesSettings(session: session),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add SSH profile'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'Key server');
      await tester.enterText(find.byType(TextField).at(1), 'localhost');
      await tester.enterText(find.byType(TextField).at(3), 'user');
      await tester.tap(find.byType(DropdownButton<SshAuthentication>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenSSH private key').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Import private key'));
      await tester.tap(find.text('Import private key'));
      await tester.pumpAndSettle();
      expect(find.text('Private key imported'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final profile = session.sshProfiles.profiles.single;
      expect(profile.authentication, SshAuthentication.privateKey);
      expect(profile.secretId, isNull);
      expect(await session.sshProfiles.readSecret(profile), isNotNull);
      expect(
        await session.store.read('ssh.profiles'),
        isNot(contains('PRIVATE KEY')),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
