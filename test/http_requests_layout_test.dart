import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/features/http_requests_dialog.dart';

import 'support.dart';

void main() {
  testWidgets('HTTP requests dialog fits a narrow mobile viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = await Directory.systemTemp.createTemp(
      'tamtoot-http-layout-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final session = await testSession();
    session.workspaceRoot = directory.uri;
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => HttpRequestsDialog(session: session),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('HTTP Requests'), findsOneWidget);
    expect(find.text('Select All'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('New Request'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('New Request (folder/name)'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).last, 'health-check');
    await tester.tap(find.text('OK'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('health-check'), findsWidgets);
    expect(find.text('Requests'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
