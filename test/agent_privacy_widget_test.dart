import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tamtoot/features/agent_dialog.dart';

import 'support.dart';

void main() {
  testWidgets('privacy selection survives reopening the panel', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(420, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = await testSession();
    Widget panel() => MaterialApp(
      home: Scaffold(body: AgentPanel(session: session)),
    );
    await tester.pumpWidget(panel());
    await tester.pumpAndSettle();
    final chip = find.byKey(const ValueKey('agent-enhanced-privacy'));
    expect(tester.widget<FilterChip>(chip).selected, isFalse);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(session.settings.get('agentPrivacy'), isTrue);
    expect(find.textContaining('Code excerpts still go'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(panel());
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(chip).selected, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.runAsync(session.dispose);
  });
}
