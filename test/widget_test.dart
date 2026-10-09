import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/app/app.dart';
import 'package:tamtoot/app/providers.dart';
import 'package:tamtoot/editor/widgets/code_editor.dart';
import 'package:tamtoot/core/completion/project_completion.dart';
import 'package:tamtoot/core/git/git_service.dart';
import 'package:tamtoot/languages/language_registry.dart';
import 'explorer_test.dart' show IndicatorGit, RepositoryMemory;
import 'support.dart';
import 'package:tamtoot/core/filesystem/filesystem.dart';

void main() {
  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets('shell menu uses shared commands on $platform', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = await testSession();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(session)],
          child: const TamtootApp(),
        ),
      );
      await tester.pumpAndSettle();
      if (platform == TargetPlatform.macOS) {
        expect(find.text('File'), findsNothing);
        final bar = tester.widget<PlatformMenuBar>(
          find.byType(PlatformMenuBar),
        );
        final file = bar.menus.whereType<PlatformMenu>().firstWhere(
          (menu) => menu.label == 'File',
        );
        final items = file.menus.expand((item) => item.members);
        final newFile = items.firstWhere(
          (item) => item.label == 'New document',
        );
        newFile.onSelected!();
        await tester.pumpAndSettle();
        expect(session.documents.active, isNotNull);
      } else {
        expect(find.byType(PlatformMenuBar), findsNothing);
        await tester.tap(find.text('File'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New document'));
        await tester.pumpAndSettle();
        expect(session.documents.active, isNotNull);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(session.dispose);
      debugDefaultTargetPlatformOverride = null;
    });
  }

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
      expect(find.text('OPEN DOCUMENTS'), findsNothing);
      expect(find.text('RECENT FOLDERS'), findsNothing);
      expect(find.byTooltip('Repository: project\n$root'), findsOneWidget);
      expect(find.text('project'), findsNothing);
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
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('https://3dcafe.github.io/tamtoot/privacy/'),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(session.dispose);
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('text input reconnects after switching editor tabs', (
    tester,
  ) async {
    final session = await testSession();
    session.observe(session.documents.create('first.dart', 'first'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: const TamtootApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CodeEditor));
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.testTextInput.hasAnyClients, isTrue);
    final second = session.documents.create('second.dart', '');
    session.observe(second);
    session.changed(persist: false);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Car car = Car();',
        selection: TextSelection.collapsed(offset: 16),
      ),
    );
    await tester.pump();
    expect(second.editor.text, 'Car car = Car();');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(session.dispose);
  });
  testWidgets(
    'Windows physical characters type after a tab switch with completion open',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final session = await testSession();
      session.languages.register(
        const LanguageDefinition(
          id: 'dart',
          name: 'Dart',
          version: 'test',
          extensions: ['.dart'],
          rules: [],
        ),
      );
      session.completionIndex = ProjectCompletionIndex(RepositoryMemory());
      await session.completionIndex!.initialize();
      session.observe(session.documents.create('first.dart', 'first'));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(session)],
          child: const TamtootApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CodeEditor));
      await tester.pump(const Duration(milliseconds: 350));

      const initial = 'Car car;\n';
      final second = session.documents.create('second.dart', initial);
      second.editor.select(initial.length, initial.length);
      session.observe(second);
      session.changed(persist: false);
      await tester.pumpAndSettle();

      expect(
        await tester.sendKeyEvent(
          LogicalKeyboardKey.keyC,
          platform: 'windows',
          character: 'c',
        ),
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('car: Car'), findsOneWidget);
      expect(
        await tester.sendKeyEvent(LogicalKeyboardKey.tab, platform: 'windows'),
        isTrue,
      );
      await tester.pump();
      expect(second.editor.text, '${initial}car');
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(session.dispose);
    },
  );
  testWidgets('Git panel ignores unrelated updates and refreshes silently', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    final git = IndicatorGit();
    final session = await testSession(git: git);
    final root = Uri.parse('memory:///project/');
    session.workspaceRoot = root;
    session.workspaceHasGit = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: const TamtootApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-git')));
    await tester.pumpAndSettle();
    final initialCalls = git.statusCalls;

    session.log('Unrelated Output message');
    await tester.pump(const Duration(milliseconds: 700));
    expect(git.statusCalls, initialCalls);

    final document = session.documents.create(
      'a.dart',
      'saved',
      uri: root.resolve('a.dart'),
      savedText: 'saved',
    );
    session.observe(document);
    git.pendingStatus = Completer<List<GitStatusEntry>>();
    document.editor.replaceSelection('changed');
    await tester.pump(const Duration(milliseconds: 700));
    expect(git.statusCalls, initialCalls);
    expect(find.textContaining('Unsaved —'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await session.documents.save(document);
    await tester.pump(const Duration(milliseconds: 700));
    expect(git.statusCalls, initialCalls + 1);
    git.pendingStatus!.complete(git.entries);
    await tester.pumpAndSettle();
    expect(find.textContaining('Unsaved —'), findsNothing);
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
      final wordPoint = origin + const Offset(105, 11);
      await tester.tapAt(wordPoint);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(wordPoint);
      await tester.pump();
      expect(session.documents.active!.editor.selection.isCollapsed, false);
      final selection = session.documents.active!.editor.selection;
      final selected = session.documents.active!.editor.text.substring(
        selection.start,
        selection.end,
      );
      expect(selected, matches(RegExp(r'^\w+$')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(session.dispose);
    },
  );

  test(
    'folding discovers class and method bodies but skips control blocks',
    () {
      final regions = foldingRegionsForLines(const [
        'class Car {',
        '  void drive() {',
        '    if (ready) {',
        '      print("go");',
        '    }',
        '  }',
        '}',
      ]);
      expect(regions.map((region) => (region.startLine, region.endLine)), [
        (0, 6),
        (1, 5),
      ]);
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
