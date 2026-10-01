import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/filesystem/filesystem.dart';
import 'package:tamtoot/workspace/documents/document_service.dart';
import 'support.dart';

class CancelDialogs extends FakeDialogs {
  @override
  Future<Uri?> save(String name, String content) async => null;
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
