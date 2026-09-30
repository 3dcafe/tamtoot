import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/filesystem/filesystem.dart';
import 'package:tamtoot/features/project_search_dialog.dart';
import 'package:tamtoot/features/dialogs.dart';
import 'package:tamtoot/app/session_commands.dart';
import 'support.dart';

void main() {
  testWidgets(
    'project search uses drafts, matches case and opens selected occurrence',
    (tester) async {
      final files = MemoryFileSystem();
      final uri = Uri.parse('memory:///project/a.dart');
      files.files[uri] = 'old disk text';
      final session = await testSession(files: files);
      session.workspaceRoot = Uri.parse('memory:///project/');
      session.documents.create('a.dart', 'Needle\nneedle', uri: uri);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              registerSessionCommands(
                session,
                ShellActions(() => context, session),
              );
              return Scaffold(
                body: TextButton(
                  onPressed: () => session.run('workspace.search'),
                  child: const Text('Search'),
                ),
              );
            },
          ),
        ),
      );
      expect(session.keys.resolve('ctrl+shift+f'), 'workspace.search');
      expect(session.keys.resolve('meta+shift+f'), 'workspace.search');
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('a.dart:1'), findsOneWidget);
      expect(find.text('a.dart:2'), findsOneWidget);
      await tester.tap(find.text('Match case'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('a.dart:1'), findsNothing);
      await tester.tap(find.text('a.dart:2'));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectSearchDialog), findsNothing);
      expect(session.documents.active!.editor.selection.anchor, 7);
      expect(session.documents.active!.editor.selection.extent, 13);
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
