import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/app/app.dart';
import 'package:tamtoot/app/providers.dart';
import 'package:tamtoot/features/dialogs.dart';
import 'support.dart';

void main() {
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
            find.byTooltip('Run Flutter'),
            desktop ? findsOneWidget : findsNothing,
          );
          expect(
            find.byTooltip('Debug Flutter'),
            desktop ? findsOneWidget : findsNothing,
          );
          expect(session.commands.isVisible('flutter.run'), desktop);
          expect(session.commands.isEnabled('flutter.run'), false);
          if (desktop) {
            session.settings.set('flutterSdkPath', '/sdk');
            session.workspaceRoot = Uri.directory('/tmp/project');
            expect(session.commands.isEnabled('flutter.run'), true);
          }
          await tester.pumpWidget(
            MaterialApp(home: SettingsDialog(session: session)),
          );
          await tester.pumpAndSettle();
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
