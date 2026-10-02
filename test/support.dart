import 'legacy_examples.dart';
import 'dart:io';
import 'package:tamtoot/app/ide_session.dart';
import 'package:tamtoot/core/filesystem/filesystem.dart';
import 'package:tamtoot/core/git/git_service.dart';
import 'package:tamtoot/core/themes/ide_theme.dart';
import 'package:tamtoot/platform/git_service.dart';
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

Future<IdeSession> testSession({
  MemoryStore? store,
  GitService? git,
  FileSystemProvider? files,
  FileDialogs? dialogs,
}) async {
  final session = IdeSession(
    store: store ?? MemoryStore(),
    documents: DocumentService(
      files ?? MemoryFileSystem(),
      dialogs ?? FakeDialogs(),
    ),
    git: git ?? createGitService(),
  );
  for (final id in ['night', 'day']) {
    session.themes[id] = IdeTheme.parse(
      File('assets/themes/$id.json').readAsStringSync(),
    );
  }
  await session.restore();
  return session;
}

void seedEditorFixture(IdeSession session) {
  session.observe(session.documents.create('example.dart', legacyExample1));
}
