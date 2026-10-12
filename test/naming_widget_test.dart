import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/app/app.dart';
import 'package:tamtoot/app/providers.dart';
import 'package:tamtoot/core/naming/naming_rules.dart';
import 'package:tamtoot/editor/rendering/code_painter.dart';
import 'package:tamtoot/features/naming_settings.dart';
import 'support.dart';
import 'language_syntax_test.dart' show loadLanguage;

void main() {
  testWidgets('project settings update and disable green diagnostics', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = await testSession();
    session.languages.register(loadLanguage('dart'));
    session.workspaceRoot = Uri.parse('memory:///project/');
    final document = session.documents.create(
      'main.dart',
      'final Bad_Name = 1;',
    );
    session.observe(document);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: const TamtootApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 250));
    CodePainter painter() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<CodePainter>()
        .single;
    expect(painter().namingDecorations.single.kind, 'naming');
    unawaited(session.run('settings.open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-naming')));
    await tester.pumpAndSettle();
    expect(find.byType(NamingSettings), findsOneWidget);
    final variables = find.byKey(const ValueKey('naming-dart-variable-camel'));
    await tester.ensureVisible(variables);
    await tester.tap(variables);
    await tester.pumpAndSettle();
    await tester.tap(find.text('No check').last);
    await tester.pumpAndSettle();
    expect(
      NamingProfile.forProject(
        session.settings,
        session.workspaceRoot,
        'dart',
      ).rules[NameKind.variable],
      NameStyle.any,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 250));
    expect(painter().namingDecorations, isEmpty);
    expect(document.editor.text, 'final Bad_Name = 1;');
    session.workspaceRoot = Uri.parse('memory:///other/');
    session.changed(persist: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(painter().namingDecorations.length, 1);
    session.settings.set('projectNaming', {
      session.workspaceRoot.toString(): {'enabled': false},
    });
    session.changed(persist: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(painter().namingDecorations, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(session.dispose);
  });
  testWidgets('naming settings fit a narrow screen without a project', (
    tester,
  ) async {
    final session = await testSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 320, child: NamingSettings(session: session)),
        ),
      ),
    );
    expect(
      find.text('Open a project to configure its naming conventions.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    session.workspaceRoot = Uri.parse('memory:///a/very/long/project/path/');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 320,
              child: NamingSettings(session: session),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('naming-dart-variable-camel')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(session.dispose);
  });
}
