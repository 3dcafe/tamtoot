import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/app/app.dart';
import 'package:tamtoot/app/providers.dart';
import 'package:tamtoot/editor/widgets/code_editor.dart';
import 'support.dart';
import 'package:tamtoot/core/filesystem/filesystem.dart';

void main() {
  testWidgets(
    'Explorer expands folders in place and opens files without changing root',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      final root = Uri.parse('memory:///project/'),
          folder = Uri.parse('memory:///project/lib/');
      final files = TreeFiles(root, folder);
      final session = await testSession(files: files);
      session.workspaceRoot = root;
      await session.explorer.open(root);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(session)],
          child: const TamtootApp(),
        ),
      );
      await tester.pumpAndSettle();
      final folderFinder = find.byKey(ValueKey('explorer-$folder'));
      await tester.tap(folderFinder);
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('explorer-${folder.resolve('main.dart')}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('explorer-${root.resolve('README.md')}')),
        findsOneWidget,
      );
      expect(session.workspaceRoot, root);
      await tester.tap(
        find.byKey(ValueKey('explorer-${folder.resolve('main.dart')}')),
      );
      await tester.pumpAndSettle();
      expect(session.documents.active!.name, 'main.dart');
      expect(session.workspaceRoot, root);
      await tester.tap(folderFinder);
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('explorer-${folder.resolve('main.dart')}')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(session.dispose);
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets('shell renders; theme, editor IME, undo and resize work', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    final session = await testSession();
    seedEditorFixture(session);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: const TamtootApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Solution'), findsOneWidget);
    expect(find.byType(CodeEditor), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    await tester.tap(find.byTooltip('Switch theme'));
    await tester.pumpAndSettle();
    expect(session.theme.dark, false);
    await tester.tap(find.byType(CodeEditor));
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.testTextInput.hasAnyClients, true);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'hello world',
        selection: TextSelection.collapsed(offset: 11),
      ),
    );
    await tester.pump();
    expect(session.documents.active!.editor.text, 'hello world');
    await session.run('editor.undo');
    await tester.pump();
    expect(session.documents.active!.editor.text, contains('Welcome'));
    final oldLayout = session.layout.encode();
    await tester.drag(
      find.byKey(const ValueKey('resize-horizontal')),
      const Offset(60, 0),
    );
    await tester.pump();
    expect(session.layout.encode(), isNot(oldLayout));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(session.dispose);
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('small tablet and large desktop layouts remain renderable', (
    tester,
  ) async {
    final session = await testSession();
    seedEditorFixture(session);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: const TamtootApp(),
      ),
    );
    for (final size in [
      const Size(768, 1024),
      const Size(1920, 1080),
      const Size(600, 700),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(session.dispose);
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets(
    'hardware keybinding routes to commands; touch long-press selects',
    (tester) async {
      final session = await testSession();
      seedEditorFixture(session);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(session)],
          child: const TamtootApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CodeEditor));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        session.documents.active!.editor.selection.end,
        session.documents.active!.editor.buffer.length,
      );
      await session.run('editor.start');
      await tester.pump();
      final origin = tester.getTopLeft(find.byType(CodeEditor));
      await tester.longPressAt(origin + const Offset(105, 11));
      await tester.pump();
      expect(session.documents.active!.editor.selection.isCollapsed, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(session.dispose);
    },
  );
}

class TreeFiles extends MemoryFileSystem {
  TreeFiles(this.root, this.folder) {
    files[folder.resolve('main.dart')] = 'void main() {}';
  }
  final Uri root, folder;
  @override
  Future<List<FileEntry>> list(Uri directory) async => directory == root
      ? [
          FileEntry(folder, 'lib', directory: true),
          FileEntry(root.resolve('README.md'), 'README.md'),
        ]
      : [FileEntry(folder.resolve('main.dart'), 'main.dart')];
}
