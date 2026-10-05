import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tamtoot/core/git/git_service.dart';
import 'package:tamtoot/features/git_changes_dialog.dart';
import 'package:tamtoot/core/git/git_store.dart';
import 'package:tamtoot/platform/git_service_io.dart';
import 'package:tamtoot/platform/git_shared.dart';
import 'explorer_test.dart' show IndicatorGit;
import 'support.dart';

void main() {
  testWidgets(
    'Hidden Git panel does not scan; reopening keeps the previous list during refresh',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final git = IndicatorGit();
      final session = (await tester.runAsync(() => testSession(git: git)))!;
      addTearDown(session.dispose);
      session.workspaceRoot = Uri.parse('memory:///project/');
      Widget panel(bool visible) => MaterialApp(
        home: Scaffold(
          body: GitChangesDialog(
            session: session,
            embedded: true,
            visible: visible,
          ),
        ),
      );
      await tester.pumpWidget(panel(false));
      await tester.pumpAndSettle();
      expect(git.statusCalls, 0);
      await tester.pumpWidget(panel(true));
      await tester.pumpAndSettle();
      expect(git.statusCalls, 1);
      expect(find.text('a.dart'), findsOneWidget);
      await tester.pumpWidget(panel(false));
      final pending = Completer<List<GitStatusEntry>>();
      git.pendingStatus = pending;
      await tester.pumpWidget(panel(true));
      await tester.pump();
      expect(git.statusCalls, 2);
      expect(find.text('a.dart'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      pending.complete(git.entries);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'Background scans detect edits, deletions and untracked files without stale results',
    () async {
      final root = await Directory.systemTemp.createTemp('tamtoot-status-');
      addTearDown(() => root.delete(recursive: true));
      final git = PlatformGitService();
      (await git.init(root.uri, branch: 'main')).ensureOk();
      await git.setIdentity(root.uri, 'Test', 'test@example.com');
      final file = File('${root.path}/file.txt');
      final deleted = File('${root.path}/deleted.txt');
      await file.writeAsString('first');
      await deleted.writeAsString('keep');
      (await git.add(root.uri)).ensureOk();
      (await git.commit(root.uri, 'Initial')).ensureOk();
      expect(await git.statusEntries(root.uri), isEmpty);

      await file.writeAsString(
        'other',
      ); // Same byte length: still must detect edit.
      await deleted.delete();
      await File('${root.path}/новый.txt').writeAsString('new');
      final scans = await Future.wait([
        git.statusEntries(root.uri),
        git.statusEntries(root.uri),
      ]);
      for (final entries in scans) {
        expect(entries.map((entry) => entry.path), [
          'deleted.txt',
          'file.txt',
          'новый.txt',
        ]);
        expect(entries[0].index, 'D');
        expect(entries[1].workTree, 'M');
        expect(entries[2].isUntracked, true);
      }
      await file.writeAsString('first');
      expect(
        (await git.statusEntries(root.uri)).map((entry) => entry.path),
        isNot(contains('file.txt')),
      );
    },
  );

  test('Background publication scan reads updated local history', () async {
    final root = await Directory.systemTemp.createTemp('tamtoot-publication-');
    addTearDown(() => root.delete(recursive: true));
    final git = PlatformGitService();
    (await git.init(root.uri, branch: 'main')).ensureOk();
    await git.setIdentity(root.uri, 'Test', 'test@example.com');
    final file = File('${root.path}/file.txt');
    await file.writeAsString('first');
    (await git.add(root.uri)).ensureOk();
    (await git.commit(root.uri, 'Initial')).ensureOk();
    final db = GitObjectDatabase(
      FileGitRepositoryStore(root),
      sharedInflateAt,
      sharedDeflate,
    );
    await db.writeConfig(
      remote: Uri.parse('https://example.com/repo.git'),
      branch: 'main',
    );
    await git.setIdentity(root.uri, 'Test', 'test@example.com');
    await db.writeRef('refs/remotes/origin/main', (await db.readHead())!);
    expect((await git.publicationState(root.uri)).paths, isEmpty);
    await file.writeAsString('second');
    (await git.add(root.uri)).ensureOk();
    (await git.commit(root.uri, 'Change')).ensureOk();
    final states = await Future.wait([
      git.publicationState(root.uri),
      git.publicationState(root.uri),
    ]);
    for (final state in states) {
      expect(state.paths, {'file.txt'});
    }
  });

  test('Failed worker scan does not prevent subsequent refresh', () async {
    final root = await Directory.systemTemp.createTemp('tamtoot-status-retry-');
    addTearDown(() => root.delete(recursive: true));
    final git = PlatformGitService();
    (await git.init(root.uri, branch: 'main')).ensureOk();
    final ref = File('${root.path}/.git/refs/heads/main');
    await ref.parent.create(recursive: true);
    await ref.writeAsString('${'a' * 40}\n');
    await expectLater(git.statusEntries(root.uri), throwsA(isA<Exception>()));
    await ref.delete();
    expect(await git.statusEntries(root.uri), isEmpty);
  });
}
