import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/platform/platform_services.dart';
import 'support.dart';
import 'legacy_examples.dart';

MemoryStore savedSession({
  List<String> recent = const [],
  List<Map<String, Object?>> docs = const [],
  int active = 0,
}) => MemoryStore()
  ..data['session'] = jsonEncode({
    'schemaVersion': 1,
    'recentWorkspaces': recent,
    'documents': docs,
    'activeIndex': active,
  });

void main() {
  test('first launch has no project or example documents', () async {
    final session = await testSession();
    expect(session.workspaceRoot, isNull);
    expect(session.explorer.rows, isEmpty);
    expect(session.documents.documents, isEmpty);
    await session.dispose();
  });
  test(
    'startup reopens most recent project and retains its saved tabs',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tamtoot-startup-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/main.dart');
      await file.writeAsString('saved');
      final store = savedSession(
        recent: [directory.uri.toString(), 'file:///older/'],
        docs: [
          {
            'name': 'main.dart',
            'text': 'unsaved edits',
            'savedText': 'saved',
            'uri': file.uri.toString(),
          },
        ],
      );
      final session = await testSession(store: store, files: PlatformFiles());
      expect(session.workspaceRoot, directory.uri);
      expect(session.explorer.rows.single.entry.name, 'main.dart');
      expect(session.documents.active!.editor.text, 'unsaved edits');
      expect(session.documents.active!.dirty, isTrue);
      expect(session.recentWorkspaces.first, directory.uri.toString());
      await session.dispose();
    },
  );
  test(
    'missing last project stays closed without falling back to older project',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tamtoot-missing-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final missing = directory.uri.resolve('deleted/').toString();
      final store = savedSession(recent: [missing, directory.uri.toString()]);
      final session = await testSession(store: store, files: PlatformFiles());
      expect(session.workspaceRoot, isNull);
      expect(session.explorer.root, isNull);
      expect(session.documents.documents, isEmpty);
      expect(session.workspaceHasGit, isFalse);
      expect(session.errors.single, contains('Last project is unavailable'));
      expect(session.message, contains('Last project is unavailable'));
      expect(session.recentWorkspaces.first, missing);
      await session.dispose();
    },
  );
  test(
    'unchanged legacy examples are removed; edited drafts and real files survive',
    () async {
      final store = savedSession(
        active: 3,
        docs: [
          {'name': 'welcome.dart', 'text': legacyExample1},
          {'name': 'Program.cs', 'text': legacyExample2},
          {'name': 'welcome.dart', 'text': '$legacyExample1// my changes'},
          {
            'name': 'Program.cs',
            'text': legacyExample2,
            'uri': 'file:///my/Program.cs',
            'savedText': legacyExample2,
          },
        ],
      );
      final session = await testSession(store: store);
      expect(session.documents.documents.length, 2);
      expect(
        session.documents.documents.first.editor.text,
        endsWith('// my changes'),
      );
      expect(session.documents.active!.uri, Uri.parse('file:///my/Program.cs'));
      await session.persistNow();
      expect(
        (jsonDecode(store.data['session']!)['documents'] as List).length,
        2,
      );
      await session.dispose();
    },
  );
  test('closing every tab keeps the next launch empty', () async {
    final store = MemoryStore();
    final first = await testSession(store: store);
    seedEditorFixture(first);
    await first.documents.close(first.documents.active!);
    await first.dispose();
    final restored = await testSession(store: store);
    expect(restored.documents.documents, isEmpty);
    await restored.dispose();
  });
}
