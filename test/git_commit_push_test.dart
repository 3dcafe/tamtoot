import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/git/git_http.dart';
import 'package:tamtoot/core/filesystem/filesystem.dart';
import 'package:tamtoot/core/git/git_objects.dart';
import 'package:tamtoot/core/git/git_pack.dart';
import 'package:tamtoot/core/git/git_service.dart';
import 'package:tamtoot/core/git/git_store.dart';
import 'package:tamtoot/core/git/http_git_service.dart';
import 'package:tamtoot/core/git/pkt_line.dart';
import 'package:tamtoot/features/git_changes_dialog.dart';
import 'package:tamtoot/platform/git_shared.dart';
import 'explorer_test.dart' show RepositoryMemory;
import 'support.dart';

class PushTransport implements GitHttpTransport {
  String old = '0000000000000000000000000000000000000000';
  bool reject = false;
  List<int>? sent;
  Map<String, String>? auth;
  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    auth = headers;
    if (method == 'GET') {
      return GitHttpResponse(
        statusCode: 200,
        body: Uint8List.fromList([
          ...PktLine.encodeText('# service=git-receive-pack'),
          ...PktLine.encodeFlush(),
          ...PktLine.encodeText(
            '$old refs/heads/main\x00report-status side-band-64k',
          ),
          ...PktLine.encodeFlush(),
        ]),
      );
    }
    sent = body;
    final report = [
      ...PktLine.encodeText('unpack ok'),
      ...PktLine.encodeText(
        reject ? 'ng refs/heads/main protected branch' : 'ok refs/heads/main',
      ),
      ...PktLine.encodeFlush(),
    ];
    return GitHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList([
        ...PktLine.encode([2, ...utf8.encode('progress\n')]),
        ...PktLine.encode([1, ...report.sublist(0, 7)]),
        ...PktLine.encode([1, ...report.sublist(7)]),
        ...PktLine.encodeFlush(),
      ]),
    );
  }
}

class RepositoryFiles extends MemoryFileSystem {
  RepositoryFiles(this.store);
  final RepositoryMemory store;
  bool cancelSave = false;
  @override
  Future<void> write(Uri uri, String text) async {
    if (cancelSave) throw StateError('Save failed');
    await store.writeText(uri.path.substring('/project/'.length), text);
  }
}

void main() {
  late RepositoryMemory store;
  late PushTransport http;
  late HttpGitService git;
  late GitObjectDatabase db;
  final root = Uri.parse('memory:///project/');
  setUp(() async {
    store = RepositoryMemory();
    http = PushTransport();
    git = HttpGitService(
      transport: http,
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
    await git.setIdentity(root, 'Test Author', 'test@example.com');
  });
  Future<String> commit(String message, List<String> paths) async {
    (await git.add(root, paths: paths)).ensureOk();
    final result = await git.commit(root, message);
    result.ensureOk();
    return result.stdout;
  }

  Future<Map<String, TreeEntry>> tree() async {
    final head = parseCommit((await db.read((await db.readHead())!)).content);
    return {
      for (final e in parseTree((await db.read(head.tree)).content)) e.name: e,
    };
  }

  test(
    'commits selected snapshots, leaves unselected files and excludes metadata',
    () async {
      await store.writeText('a.txt', 'a');
      await store.writeText('b.txt', 'b');
      await commit('Initial', ['a.txt', 'b.txt']);
      await store.writeText('a.txt', 'selected');
      await store.writeText('b.txt', 'not selected');
      await store.writeText('.tamtoot/project.json', 'private metadata');
      await store.writeText(
        '.tamtoot/requests/health.json',
        '{"version":1,"name":"Health","method":"GET","url":"https://example.com","headers":[],"query":[],"body":{"type":"none"},"auth":{"mode":"none"}}',
      );
      await store.writeText(
        '.tamtoot/environment.json',
        '{"version":1,"variables":{}}',
      );
      await store.writeText(
        '.tamtoot/environment.local.json',
        '{"version":1,"variables":{"token":"secret"}}',
      );
      await store.writeText('secret.txt', 'not selected');
      (await git.add(root, paths: ['a.txt'])).ensureOk();
      await store.writeText('a.txt', 'later edit');
      (await git.commit(root, 'Selected change')).ensureOk();
      final files = await tree();
      expect(files.keys, unorderedEquals(['a.txt', 'b.txt']));
      expect(
        utf8.decode((await db.read(files['a.txt']!.hash)).content),
        'selected',
      );
      expect(utf8.decode((await db.read(files['b.txt']!.hash)).content), 'b');
      final info = parseCommit((await db.read((await db.readHead())!)).content);
      expect(info.author, startsWith('Test Author <test@example.com>'));
      expect(
        (await git.statusEntries(root)).map((e) => e.path),
        isNot(contains('.tamtoot/project.json')),
      );
      expect(
        (await git.statusEntries(root)).map((e) => e.path),
        containsAll([
          '.tamtoot/requests/health.json',
          '.tamtoot/environment.json',
        ]),
      );
      expect(
        (await git.statusEntries(root)).map((e) => e.path),
        isNot(contains('.tamtoot/environment.local.json')),
      );
      await store.delete('a.txt');
      await commit('Delete', ['a.txt']);
      expect((await tree()).keys, ['b.txt']);
    },
  );
  test(
    'empty message, missing staging, detached HEAD and changed HEAD are rejected',
    () async {
      expect((await git.commit(root, 'message')).ok, isFalse);
      await store.writeText('a', 'one');
      final first = await commit('one', ['a']);
      await store.writeText('a', 'two');
      await git.add(root, paths: ['a']);
      expect((await git.commit(root, '  ')).ok, isFalse);
      await store.writeText('.git/HEAD', '$first\n');
      expect((await git.commit(root, 'detached')).ok, isFalse);
      await db.writeHead('refs/heads/main');
      await db.writeRef(
        'refs/heads/main',
        '1111111111111111111111111111111111111111',
      );
      expect((await git.commit(root, 'stale')).ok, isFalse);
    },
  );
  test(
    'push includes every intermediate local commit and confirms sideband status',
    () async {
      await store.writeText('a', 'one');
      final first = await commit('one', ['a']);
      http.old = first;
      await store.writeText('a', 'two');
      final second = await commit('two', ['a']);
      await store.writeText('a', 'three');
      final third = await commit('three', ['a']);
      final result = await git.push(
        root,
        credentials: const GitCredentials(username: 'me', token: 'secret'),
        setUpstream: true,
      );
      expect(result.ok, isTrue);
      final bytes = http.sent!;
      final packAt = utf8.decode(bytes, allowMalformed: true).indexOf('PACK');
      final objects = unpackPackfile(
        Uint8List.fromList(bytes.sublist(packAt)),
        archiveInflateAt,
      );
      final hashes = objects.map((o) => GitObject(o.type, o.data).hash).toSet();
      expect(hashes, containsAll([second, third]));
      expect(hashes, isNot(contains(first)));
      expect(await db.readRef('refs/remotes/origin/main'), third);
      expect(
        http.auth!['Authorization'],
        'Basic ${base64Encode(utf8.encode('me:secret'))}',
      );
      expect(await store.readText('.git/config'), isNot(contains('secret')));
      expect((await git.identity(root)).name, 'Test Author');
    },
  );
  test(
    'rejection and divergent remote do not update remote tracking',
    () async {
      await store.writeText('a', 'one');
      final first = await commit('one', ['a']);
      http.old = first;
      await db.writeRef('refs/remotes/origin/main', first);
      await store.writeText('a', 'two');
      await commit('two', ['a']);
      http.reject = true;
      expect((await git.push(root)).ok, isFalse);
      expect(await db.readRef('refs/remotes/origin/main'), first);
      http.old = '1111111111111111111111111111111111111111';
      http.sent = null;
      expect((await git.push(root)).ok, isFalse);
      expect(http.sent, isNull);
    },
  );
  test('incomplete or failed unpack reports never count as push success', () {
    expect(
      () => verifyReceivePackResponse([], 'refs/heads/main'),
      throwsA(isA<GitException>()),
    );
    expect(
      () => verifyReceivePackResponse([
        ...PktLine.encodeText('unpack error'),
        ...PktLine.encodeText('ok refs/heads/main'),
        ...PktLine.encodeFlush(),
      ], 'refs/heads/main'),
      throwsA(isA<GitException>()),
    );
  });
  testWidgets('unsaved changes appear and failed save prevents a commit', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    await store.writeText('a.txt', 'saved');
    final oldHead = await commit('Initial', ['a.txt']);
    final files = RepositoryFiles(store)..cancelSave = true;
    final session = await testSession(git: git, files: files);
    session.workspaceRoot = root;
    session.documents.create(
      'a.txt',
      'edited',
      uri: root.resolve('a.txt'),
      savedText: 'saved',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GitChangesDialog(session: session)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Unsaved —'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.enterText(
      find.widgetWithText(TextField, 'Commit message'),
      'Unsaved edit',
    );
    await tester.ensureVisible(find.text('Commit selected'));
    await tester.tap(find.text('Commit selected'));
    await tester.pumpAndSettle();
    expect(await db.readHead(), oldHead);
    expect(find.textContaining('Save failed'), findsOneWidget);
    files.cancelSave = false;
    await tester.tap(find.text('Commit selected'));
    await tester.pumpAndSettle();
    expect(await db.readHead(), isNot(oldHead));
    expect(await store.readText('a.txt'), 'edited');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(session.dispose);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('dialog selects, commits and pushes with existing Dart service', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    await store.writeText('a.txt', 'hello');
    final session = await testSession(git: git);
    session.workspaceRoot = root;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GitChangesDialog(session: session)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.enterText(
      find.widgetWithText(TextField, 'Commit message'),
      'From UI',
    );
    await tester.tap(find.text('Commit selected'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Commit created:'), findsOneWidget);
    expect(await db.readHead(), isNotNull);
    await tester.ensureVisible(find.text('Push commits'));
    await tester.tap(find.text('Push commits'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Pushed refs/heads/main'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(session.dispose);
    await tester.binding.setSurfaceSize(null);
  });
}
