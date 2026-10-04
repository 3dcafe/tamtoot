import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/app/app.dart';
import 'package:tamtoot/app/providers.dart';
import 'package:tamtoot/features/dialogs.dart';
import 'support.dart';
import 'package:tamtoot/core/projects/project_detection.dart';
import 'package:tamtoot/features/flutter_settings.dart';

void main() {
  testWidgets(
    'device picker saves IDs internally and keeps disconnected selections',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final session = await testSession();
      session.settings.set('flutterSdkPath', '/sdk');
      session.flutter.devices = [
        {'id': 'phone-secret-id', 'name': 'Pixel 9', 'emulator': false},
        {'id': 'emulator-5554', 'name': 'Pixel emulator', 'emulator': true},
      ];
      session.flutter.devicesLoaded = true;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: FlutterSettings(session: session)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Device ID'), findsNothing);
        expect(find.textContaining('phone-secret-id'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('flutter-device-picker')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pixel 9').last);
        await tester.pumpAndSettle();
        expect(session.settings.get('flutterDeviceId'), 'phone-secret-id');
        expect(session.settings.get('flutterDeviceName'), 'Pixel 9');
        session.flutter.devices = [];
        session.changed(persist: false);
        await tester.pumpAndSettle();
        expect(find.text('Pixel 9 (not connected)'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('flutter-device-picker')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('This computer (Windows)').last);
        await tester.pumpAndSettle();
        expect(session.settings.get('flutterDeviceId'), '');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await tester.runAsync(session.dispose);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      'Flutter controls and SDK settings are desktop only: $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        final session = await testSession();
        try {
          final desktop = ![
            TargetPlatform.android,
            TargetPlatform.iOS,
          ].contains(platform);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [sessionProvider.overrideWithValue(session)],
              child: const TamtootApp(),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byTooltip('Run selected project'),
            desktop ? findsOneWidget : findsNothing,
          );
          expect(find.byTooltip('Debug Flutter'), findsNothing);
          expect(session.commands.isVisible('flutter.run'), desktop);
          expect(session.commands.isEnabled('flutter.run'), false);
          if (desktop) {
            session.settings.set('flutterSdkPath', '/sdk');
            session.workspaceRoot = Uri.directory('/tmp/project');
            session.explorer.children[session.workspaceRoot!] = [];
            expect(session.commands.isEnabled('flutter.run'), true);
            final target = LaunchTarget(
              ProjectKind.flutter,
              session.workspaceRoot!,
              'pubspec.yaml',
              'Flutter project',
            );
            session.launchTargets = [target];
            session.selectedLaunchTarget = target.id;
            session.changed(persist: false);
            // Unrelated project panels may keep loading this synthetic root.
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 100));
            expect(find.byTooltip('Debug Flutter'), findsOneWidget);
          }
          await tester.pumpWidget(
            MaterialApp(home: SettingsDialog(session: session)),
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('flutter-sdk-path')), findsNothing);
          if (desktop) {
            await tester.tap(find.text('SDK'));
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(const ValueKey('settings-section-flutter')),
            );
            await tester.pumpAndSettle();
          }
          expect(
            find.byKey(const ValueKey('flutter-sdk-path')),
            desktop ? findsOneWidget : findsNothing,
          );
          expect(
            find.byKey(const ValueKey('flutter-sdk-test')),
            desktop ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(session.dispose);
          await tester.binding.setSurfaceSize(null);
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}
