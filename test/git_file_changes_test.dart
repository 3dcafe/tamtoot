import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/app/app.dart';
import 'package:tamtoot/app/providers.dart';
import 'package:tamtoot/app/git_file_changes.dart';
import 'package:tamtoot/core/filesystem/filesystem.dart';
import 'package:tamtoot/core/git/git_service.dart';
import 'package:tamtoot/core/git/git_store.dart';
import 'package:tamtoot/core/git/http_git_service.dart';
import 'package:tamtoot/core/git/text_diff.dart';
import 'package:tamtoot/platform/git_shared.dart';
import 'explorer_test.dart' show RepositoryMemory;
import 'git_commit_push_test.dart' show PushTransport;
import 'support.dart';

class ChangeFiles extends MemoryFileSystem {
  ChangeFiles(this.store);
  final RepositoryMemory store;
  String path(Uri uri) => uri.path.substring('/project/'.length);
  @override
  Future<String> read(Uri uri) => store.readText(path(uri));
  @override
  Future<Uint8List> readBytes(Uri uri) => store.readBytes(path(uri));
  @override
  Future<void> write(Uri uri, String text) => store.writeText(path(uri), text);
  @override
  Future<List<FileEntry>> list(Uri directory) async => [
    for (final path in await store.listFiles(''))
      FileEntry(directory.resolve(Uri(path: path).toString()), path),
  ];
}

void main() {
  final root = Uri.parse('memory:///project/'),
      uri = Uri.parse('memory:///project/a.txt');
  late RepositoryMemory store;
  late HttpGitService git;
  late GitObjectDatabase db;
  setUp(() async {
    store = RepositoryMemory();
    git = HttpGitService(
      transport: PushTransport(),
      openStore: (_) => store,
      inflateAt: archiveInflateAt,
      deflate: archiveDeflate,
    );
    db = GitObjectDatabase(store, archiveInflateAt, archiveDeflate);
    await db.writeHead('refs/heads/main');
    await db.writeConfig(
      remote: Uri.parse('https://example.com/repo.git'),
      branch: 'main',
    );
    await git.setIdentity(root, 'Author', 'author@example.com');
    await store.writeText('a.txt', 'before\n');
    (await git.add(root, paths: ['a.txt'])).ensureOk();
    (await git.commit(root, 'Initial')).ensureOk();
  });
  test(
    'snapshots HEAD and working bytes, restores modified and deleted files',
    () async {
      await store.writeText('a.txt', 'after\r\n');
      final snapshot = await git.fileSnapshot(root, 'a.txt');
      expect(utf8.decode(snapshot.original!), 'before\n');
      expect(utf8.decode(snapshot.working!), 'after\r\n');
      await git.discardFile(snapshot);
      expect(await store.readText('a.txt'), 'before\n');
      await store.delete('a.txt');
      final deleted = await git.fileSnapshot(root, 'a.txt');
      expect(deleted.working, isNull);
      await git.discardFile(deleted);
      expect(await store.readText('a.txt'), 'before\n');
    },
  );
  test('untracked discard removes only the reviewed file', () async {
    await store.writeText('new.txt', 'new');
    await store.writeText('keep.txt', 'keep');
    final snapshot = await git.fileSnapshot(root, 'new.txt');
    expect(snapshot.original, isNull);
    await git.discardFile(snapshot);
    expect(await store.exists('new.txt'), isFalse);
    expect(await store.readText('keep.txt'), 'keep');
    expect(await store.readText('a.txt'), 'before\n');
  });
  test(
    'stale file, changed HEAD and protected paths cannot be discarded',
    () async {
      final snapshot = await git.fileSnapshot(root, 'a.txt');
      await store.writeText('a.txt', 'new external change');
      await expectLater(
        git.discardFile(snapshot),
        throwsA(isA<GitException>()),
      );
      expect(await store.readText('a.txt'), 'new external change');
      final next = await git.fileSnapshot(root, 'a.txt');
      await git.add(root, paths: ['a.txt']);
      await git.commit(root, 'New HEAD');
      await expectLater(git.discardFile(next), throwsA(isA<GitException>()));
      for (final path in [
        '../a.txt',
        '/a.txt',
        '.git/config',
        '.tamtoot/project.json',
        'a/../../other',
      ]) {
        await expectLater(
          git.fileSnapshot(root, path),
          throwsA(isA<GitException>()),
        );
      }
    },
  );
  test(
    'editor edits after review are preserved; confirmed restore updates buffer and disk',
    () async {
      final session = await testSession(git: git, files: ChangeFiles(store));
      session.workspaceRoot = root;
      final document = session.documents.create(
        'a.txt',
        'unsaved',
        uri: uri,
        savedText: 'before\n',
      );
      final review = await session.reviewFile(uri);
      expect(review.unsavedText, 'unsaved');
      document.editor.replaceSelection('new');
      await expectLater(
        session.discardReviewedFile(review),
        throwsA(isA<GitException>()),
      );
      expect(document.editor.text, 'newunsaved');
      final current = await session.reviewFile(uri);
      await session.discardReviewedFile(current);
      expect(document.editor.text, 'before\n');
      expect(document.dirty, isFalse);
      expect(await store.readText('a.txt'), 'before\n');
      expect(session.gitBusy, isFalse);
      await session.dispose();
    },
  );
  test(
    'binary content is restored byte-for-byte but not decoded as text',
    () async {
      await store.writeBytes('binary.bin', [0, 255, 1]);
      await git.add(root, paths: ['binary.bin']);
      await git.commit(root, 'Binary');
      await store.writeBytes('binary.bin', [0, 5, 6]);
      final review = await git.fileSnapshot(root, 'binary.bin');
      expect(() => gitText(review.original), throwsFormatException);
      await git.discardFile(review);
      expect(await store.readBytes('binary.bin'), [0, 255, 1]);
    },
  );
  test(
    'diff retains both versions, line numbers and bounds large replacements',
    () {
      final diff = compareText('one\ntwo\nthree', 'one\nnew\nthree\nfour');
      expect(diff.added, 2);
      expect(diff.removed, 1);
      expect(diff.lines.where((l) => l.kind == '-').single.oldLine, 2);
      expect(diff.lines.last.newLine, 4);
      final random = Random(13);
      for (var trial = 0; trial < 50; trial++) {
        final a = List.generate(15, (_) => '${random.nextInt(6)}').join('\n');
        final b = List.generate(20, (_) => '${random.nextInt(6)}').join('\n');
        final rows = compareText(a, b).lines;
        expect(
          rows.where((l) => l.kind != '+').map((l) => l.text).join('\n'),
          a,
        );
        expect(
          rows.where((l) => l.kind != '-').map((l) => l.text).join('\n'),
          b,
        );
      }
      expect(
        compareText(
          List.generate(1100, (i) => 'old$i').join('\n'),
          List.generate(1100, (i) => 'new$i').join('\n'),
        ).coarse,
        isTrue,
      );
    },
  );
  testWidgets(
    'Solution right-click compares and cancel preserves changes; Git click opens diff and restores',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await store.writeText('a.txt', 'after\n');
      final session = await testSession(git: git, files: ChangeFiles(store));
      session.workspaceRoot = root;
      session.workspaceHasGit = true;
      await session.explorer.open(root);
      final document = session.documents.create(
        'a.txt',
        'unsaved editor',
        uri: uri,
        savedText: 'after\n',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(session)],
          child: const TamtootApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Solution'), findsOneWidget);
      expect(find.text('Solution Explorer'), findsNothing);
      await tester.tap(
        find.byKey(ValueKey('explorer-$uri')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Compare with HEAD'));
      await tester.pumpAndSettle();
      expect(find.text('HEAD → Editor (unsaved)'), findsOneWidget);
      expect(find.text('before'), findsOneWidget);
      expect(find.text('unsaved editor'), findsOneWidget);
      await tester.tap(find.text('Discard changes…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await store.readText('a.txt'), 'after\n');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-git')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('git-change-a.txt')));
      await tester.pumpAndSettle();
      expect(find.text('HEAD → Editor (unsaved)'), findsOneWidget);
      await tester.tap(find.text('Discard changes…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard changes'));
      await tester.pumpAndSettle();
      expect(await store.readText('a.txt'), 'before\n');
      expect(document.editor.text, 'before\n');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.dispose);
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets('Git sidebar creates a commit without a modal', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    await store.writeText('a.txt', 'sidebar edit');
    final previous = await db.readHead();
    final session = await testSession(git: git, files: ChangeFiles(store));
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
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('https://example.com'), findsNothing);
    await tester.tap(find.byTooltip('Git settings'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Remote URL (origin)'), findsOneWidget);
    expect(find.text('https://example.com/repo.git'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Author name'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Access token / password'),
      findsOneWidget,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Remote URL (origin)'),
      'https://example.com/updated.git',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Author name'),
      'Updated Author',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Author email'),
      'updated@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Access token / password'),
      'temporary-secret',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((await git.identity(root)).name, 'Updated Author');
    expect((await git.remoteUrl(root)).stdout, 'https://example.com/updated.git');
    expect(await store.readText('.git/config'), isNot(contains('temporary-secret')));
    await tester.tap(find.byKey(const ValueKey('git-history')));
    await tester.pumpAndSettle();
    expect(find.text('Commit history · main'), findsOneWidget);
    expect(find.text('Initial'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.ensureVisible(
      find.widgetWithText(TextField, 'Commit message'),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Commit message'),
      'Sidebar commit',
    );
    await tester.ensureVisible(find.text('Commit'));
    await tester.tap(find.text('Commit'));
    await tester.pumpAndSettle();
    expect(await db.readHead(), isNot(previous));
    expect(session.gitBusy, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(session.dispose);
    await tester.binding.setSurfaceSize(null);
  });
}
