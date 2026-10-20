import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tamtoot/features/agent_dialog.dart';
import 'support.dart';

void main() {
  for (final desktop in [false, true]) {
    testWidgets(
      'test workflow checkbox desktop=$desktop is explicit and persists',
      (tester) async {
        debugDefaultTargetPlatformOverride = desktop
            ? TargetPlatform.windows
            : TargetPlatform.android;
        try {
          SharedPreferences.setMockInitialValues({});
          await tester.binding.setSurfaceSize(const Size(420, 1100));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final session = await testSession();
          Widget panel() => MaterialApp(
            home: Scaffold(body: AgentPanel(session: session)),
          );
          await tester.pumpWidget(panel());
          await tester.pumpAndSettle();
          await tester.tap(find.text('Agent options'));
          await tester.pumpAndSettle();
          final checkbox = find.byKey(const ValueKey('agent-write-run-tests'));
          if (!desktop) {
            expect(checkbox, findsNothing);
          } else {
            expect(tester.widget<CheckboxListTile>(checkbox).value, false);
            await tester.tap(checkbox);
            await tester.pumpAndSettle();
            expect(session.settings.get('agentWriteAndRunTests'), true);
            await tester.pumpWidget(const SizedBox());
            await tester.pumpWidget(panel());
            await tester.pumpAndSettle();
            await tester.tap(find.text('Agent options'));
            await tester.pumpAndSettle();
            expect(tester.widget<CheckboxListTile>(checkbox).value, true);
            await tester.tap(
              find.byKey(const ValueKey('agent-enhanced-privacy')),
            );
            await tester.pumpAndSettle();
            expect(tester.widget<CheckboxListTile>(checkbox).onChanged, isNull);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(session.dispose);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}
