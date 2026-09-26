import 'dart:io';
import 'package:tamtoot/app/ide_session.dart';
import 'package:tamtoot/core/filesystem/filesystem.dart';
import 'package:tamtoot/core/themes/ide_theme.dart';
import 'package:tamtoot/workspace/documents/document_service.dart';

class MemoryStore implements PersistenceStore {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }
}

class FakeDialogs implements FileDialogs {
  @override
  bool get supportsDirectories => false;
  @override
  Future<FileEntry?> open() async => null;
  @override
  Future<Uri?> openWorkspace() async => null;
  @override
  Future<Uri?> save(String name, String content) async =>
      Uri.parse('memory:///$name');
}

Future<IdeSession> testSession({MemoryStore? store}) async {
  final session = IdeSession(
    store: store ?? MemoryStore(),
    documents: DocumentService(MemoryFileSystem(), FakeDialogs()),
  );
  for (final id in ['night', 'day']) {
    session.themes[id] = IdeTheme.parse(
      File('assets/themes/$id.json').readAsStringSync(),
    );
  }
  await session.restore();
  return session;
}
