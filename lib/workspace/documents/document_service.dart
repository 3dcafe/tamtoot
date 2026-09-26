import '../../editor/document/editor_controller.dart';
import '../../core/filesystem/filesystem.dart';

class OpenDocument {
  OpenDocument(this.id, this.name, String text, {this.uri, this.savedText})
    : editor = EditorController(text);
  final String id;
  String name;
  Uri? uri;
  String? savedText;
  final EditorController editor;
  bool get dirty => editor.text != savedText;
}

class DocumentService {
  DocumentService(this.files, this.dialogs);
  final FileSystemProvider files;
  final FileDialogs dialogs;
  final List<OpenDocument> documents = [];
  String? activeId;
  int _counter = 0;
  OpenDocument? get active =>
      documents.where((d) => d.id == activeId).firstOrNull;
  OpenDocument create(String name, String text, {Uri? uri, String? savedText}) {
    final doc = OpenDocument(
      'doc-${++_counter}',
      name,
      text,
      uri: uri,
      savedText: savedText?.replaceAll('\r\n', '\n'),
    );
    documents.add(doc);
    activeId = doc.id;
    return doc;
  }

  Future<OpenDocument> open(FileEntry entry) async {
    final existing = documents.where((d) => d.uri == entry.uri).firstOrNull;
    if (existing != null) {
      activeId = existing.id;
      return existing;
    }
    final text = await files.read(entry.uri);
    return create(entry.name, text, uri: entry.uri, savedText: text);
  }

  Future<bool> save(OpenDocument doc, {bool saveAs = false}) async {
    final text = doc.editor.text;
    if (!saveAs && doc.uri != null && files.canWrite(doc.uri!)) {
      await files.write(doc.uri!, text);
    } else {
      final target = await dialogs.save(doc.name, text);
      if (target == null) return false;
      doc.uri = target;
      if (target.scheme == 'file') doc.name = target.pathSegments.last;
    }
    doc.savedText = text;
    return true;
  }

  Future<void> close(OpenDocument doc) async {
    documents.remove(doc);
    if (activeId == doc.id) activeId = documents.lastOrNull?.id;
    await doc.editor.dispose();
  }
}
