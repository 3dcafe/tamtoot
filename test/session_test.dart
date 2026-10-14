import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/app/ide_session.dart';
import 'package:tamtoot/core/filesystem/filesystem.dart';
import 'package:tamtoot/core/git/git_service.dart';
import 'package:tamtoot/workspace/documents/document_service.dart';
import 'support.dart';

class CancelDialogs extends FakeDialogs {
  @override
  Future<Uri?> save(String name, String content) async => null;
}

class UnavailableGit extends Fake implements GitService {
  @override
  bool get available => false;
}

class DelayedFiles extends MemoryFileSystem {
  final gate = Completer<void>();
  @override
  Future<void> write(Uri uri, String text) async {
    await gate.future;
    await super.write(uri, text);
  }
}

void main() {
  test(
    'dirty cache follows edits, cursor changes, snapshots and disk reload',
    () async {
      final docs = DocumentService(MemoryFileSystem(), FakeDialogs());
      final doc = docs.create('cache.dart', 'saved', savedText: 'saved');
      expect(doc.dirty, false);
      doc.editor.select(2, 2);
      expect(doc.dirty, false);
      doc.editor.replaceSelection('x');
      expect(doc.dirty, true);
      doc.editor.undo();
      expect(doc.dirty, false);
      doc.editor.redo();
      expect(doc.dirty, true);
      doc.savedText = doc.editor.text;
      expect(doc.dirty, false);
      doc.savedText = null;
      expect(doc.dirty, true);
      doc.editor.reloadFromDisk('disk');
      doc.savedText = 'disk';
      expect(doc.dirty, false);
      await doc.editor.dispose();
    },
  );
  test(
    'forgetting a project persists its removal without closing documents',
    () async {
      final store = MemoryStore();
      final session = await testSession(store: store);
      final directory = await Directory.systemTemp.createTemp(
        'tamtoot-forget-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final root = directory.uri;
      session.recentWorkspaces.add(root.toString());
      final doc = session.documents.create('draft.dart', 'unsaved');
      await session.forgetProject(Uri.parse(IdeSession.projectKey(root)));
      expect(session.recentWorkspaces, isEmpty);
      expect(session.documents.active, same(doc));
      final restored = await testSession(store: store, git: UnavailableGit());
      expect(restored.recentWorkspaces, isEmpty);
      expect(restored.hiddenProjects, contains(IdeSession.projectKey(root)));
      await restored.openWorkspaceFolder(root);
      expect(restored.hiddenProjects, isEmpty);
      expect(restored.recentWorkspaces, [root.toString()]);
      await session.dispose();
      await restored.dispose();
    },
  );
  test(
    'restore removes unavailable tabs and persists the repaired session',
    () async {
      final store = MemoryStore();
      final files = MemoryFileSystem();
      final first = await testSession(store: store, files: files);
      final kept = Uri.parse('memory:///project/kept.dart');
      final removed = Uri.parse('memory:///project/removed.dart');
      final moved = Uri.parse('memory:///project/moved.dart');
      files.files.addAll({kept: 'kept', removed: 'removed', moved: 'moved'});
      for (final uri in [kept, removed, moved]) {
        first.observe(
          await first.documents.open(FileEntry(uri, uri.pathSegments.last)),
        );
      }
      await first.persistNow();
      files.files.remove(removed);
      files.files[Uri.parse('memory:///elsewhere/moved.dart')] = files.files
          .remove(moved)!;

      final restored = await testSession(store: store, files: files);
      expect(restored.documents.documents.map((doc) => doc.uri), [kept]);
      expect(restored.documents.active!.uri, kept);
      final again = await testSession(store: store, files: files);
      expect(again.documents.documents.map((doc) => doc.uri), [kept]);
      expect(
        again.output.any((line) => line.contains('Closed unavailable file')),
        false,
      );
      await first.dispose();
      await restored.dispose();
      await again.dispose();
    },
  );

  test('restore keeps edits from missing files as unsaved drafts', () async {
    final store = MemoryStore();
    final files = MemoryFileSystem();
    final first = await testSession(store: store, files: files);
    final uri = Uri.parse('memory:///deleted-project/edited.dart');
    files.files[uri] = 'saved';
    final doc = await first.documents.open(FileEntry(uri, 'edited.dart'));
    first.observe(doc);
    doc.editor.replaceSelection('edit');
    final recoveredText = doc.editor.text;
    first.observe(first.documents.create('draft.dart', 'draft'));
    first.documents.activeId = doc.id;
    await first.persistNow();
    files.files.clear();

    final restored = await testSession(store: store, files: files);
    expect(restored.documents.documents.length, 2);
    expect(restored.documents.active!.name, 'edited.dart');
    expect(restored.documents.active!.editor.text, recoveredText);
    expect(restored.documents.active!.uri, isNull);
    expect(restored.documents.active!.dirty, true);
    expect(files.files, isEmpty);
    await first.dispose();
    await restored.dispose();
  });

  test(
    'restore removes missing images and reloads available image bytes',
    () async {
      final store = MemoryStore();
      final files = MemoryFileSystem();
      final first = await testSession(store: store, files: files);
      final kept = Uri.parse('memory:///kept.png');
      final removed = Uri.parse('memory:///removed.png');
      files.files.addAll({kept: 'image', removed: 'image'});
      for (final uri in [kept, removed]) {
        first.observe(
          await first.documents.open(FileEntry(uri, uri.pathSegments.last)),
        );
      }
      await first.persistNow();
      files.files.remove(removed);
      final restored = await testSession(store: store, files: files);
      expect(restored.documents.documents.length, 1);
      expect(restored.documents.active!.uri, kept);
      expect(restored.documents.active!.bytes, 'image'.codeUnits);
      await first.dispose();
      await restored.dispose();
    },
  );

  test(
    'session recovers unsaved content, active tab, settings and layout',
    () async {
      final store = MemoryStore();
      final a = await testSession(store: store);
      seedEditorFixture(a);
      a.documents.active!.editor.replaceSelection('unsaved');
      a.settings.set('fontSize', 20.0);
      a.settings.set('theme', 'day');
      a.settings.set('readOnly', true);
      a.layout = a.layout.resize('horizontal', .31).toggle('terminal');
      await a.persistNow();
      final b = await testSession(store: store);
      expect(b.documents.active!.editor.text, startsWith('unsaved'));
      expect(b.documents.active!.dirty, true);
      expect(b.settings.fontSize, 20);
      expect(b.layout.encode(), a.layout.encode());
      expect(b.settings.theme, 'day');
      expect(b.documents.active!.editor.readOnly, false);
      await a.dispose();
      await b.dispose();
    },
  );
  test(
    'incompatible persisted state logs errors and starts with defaults',
    () async {
      final store = MemoryStore();
      store.data['layout'] = '{"schemaVersion":44}';
      store.data['settings'] = 'not json';
      final session = await testSession(store: store);
      expect(session.errors.length, 2);
      expect(session.documents.documents, isEmpty);
      await session.dispose();
    },
  );
  test('model API tokens stay local and restore by profile id', () async {
    final store = MemoryStore();
    final first = await testSession(store: store);
    first.rememberModelApiKey('ai-star-agent', 'secret-token');
    await first.persistNow();

    final restored = await testSession(store: store);
    expect(restored.modelApiKey('ai-star-agent'), 'secret-token');
    expect(restored.modelApiKey('another-profile'), isEmpty);

    restored.rememberModelApiKey('ai-star-agent', '');
    await restored.persistNow();
    final forgotten = await testSession(store: store);
    expect(forgotten.modelApiKey('ai-star-agent'), isEmpty);

    await first.dispose();
    await restored.dispose();
    await forgotten.dispose();
  });
  test('Git credentials stay local and restore by remote URL', () async {
    final store = MemoryStore();
    final first = await testSession(store: store);
    const remote = 'https://github.com/example/project.git';
    first.rememberGitCredentials(
      remote,
      username: 'developer',
      token: 'github-token',
    );
    await first.persistNow();

    final restored = await testSession(store: store);
    expect(restored.gitCredentials(remote).username, 'developer');
    expect(restored.gitCredentials(remote).token, 'github-token');
    expect(
      restored.gitCredentials('https://example.com/other.git').token,
      isEmpty,
    );

    await first.dispose();
    await restored.dispose();
  });
  test(
    'opening same file activates existing tab and normalizes CRLF cleanly',
    () async {
      final files = MemoryFileSystem();
      final uri = Uri.parse('memory:///a.dart');
      files.files[uri] = 'a\r\nb';
      final docs = DocumentService(files, FakeDialogs());
      final first = await docs.open(FileEntry(uri, 'a.dart'));
      await docs.open(FileEntry(uri, 'a.dart'));
      expect(docs.documents.length, 1);
      expect(first.dirty, false);
      expect(first.editor.text, 'a\nb');
      await first.editor.dispose();
    },
  );
  test('cancelled save leaves URI and dirty state intact', () async {
    final docs = DocumentService(MemoryFileSystem(), CancelDialogs());
    final d = docs.create('x.dart', 'new');
    expect(await docs.save(d), false);
    expect(d.uri, isNull);
    expect(d.dirty, true);
    await d.editor.dispose();
  });
  test('save snapshots text; concurrent edits remain dirty', () async {
    final files = DelayedFiles();
    final docs = DocumentService(files, FakeDialogs());
    final d = docs.create(
      'x.dart',
      'before',
      uri: Uri.parse('memory:///x.dart'),
    );
    final saving = docs.save(d);
    d.editor.replaceSelection('after');
    files.gate.complete();
    await saving;
    expect(files.files[d.uri], 'before');
    expect(d.dirty, true);
    await d.editor.dispose();
  });
  test('undo to saved text clears dirty marker', () async {
    final docs = DocumentService(MemoryFileSystem(), FakeDialogs());
    final d = docs.create('x.dart', 'saved', savedText: 'saved');
    d.editor.replaceSelection('x');
    expect(d.dirty, true);
    d.editor.undo();
    expect(d.dirty, false);
    await d.editor.dispose();
  });
}
