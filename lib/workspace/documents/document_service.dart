import 'dart:typed_data';

import '../../editor/document/editor_controller.dart';
import '../../core/filesystem/filesystem.dart';

enum DocumentKind {
  /// Ordinary editable text.
  text,

  /// Raster image opened for preview (not decoded as UTF-8).
  image,

  /// SVG / vector markup: editable source with a live preview pane.
  svg,
}

class OpenDocument {
  OpenDocument(
    this.id,
    this.name,
    String text, {
    this.uri,
    this.savedText,
    this.kind = DocumentKind.text,
    this.bytes,
  }) : editor = EditorController(text);
  final String id;
  String name;
  Uri? uri;
  String? savedText;
  DocumentKind kind;
  Uint8List? bytes;
  final EditorController editor;

  bool get isMediaPreview =>
      kind == DocumentKind.image || kind == DocumentKind.svg;

  bool get dirty =>
      kind == DocumentKind.image ? false : editor.text != savedText;
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
  OpenDocument create(
    String name,
    String text, {
    Uri? uri,
    String? savedText,
    DocumentKind kind = DocumentKind.text,
    Uint8List? bytes,
  }) {
    final doc = OpenDocument(
      'doc-${++_counter}',
      name,
      text,
      uri: uri,
      savedText: savedText?.replaceAll('\r\n', '\n'),
      kind: kind,
      bytes: bytes,
    );
    documents.add(doc);
    activeId = doc.id;
    return doc;
  }

  static const _rasterExtensions = [
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.ico',
    '.icns',
  ];

  static const _binaryExtensions = [
    ..._rasterExtensions,
    '.pdf',
    '.zip',
    '.gz',
    '.tar',
    '.7z',
    '.mp3',
    '.mp4',
    '.mov',
    '.wav',
    '.ogg',
    '.ttf',
    '.otf',
    '.woff',
    '.woff2',
    '.exe',
    '.dll',
    '.dylib',
    '.so',
    '.a',
    '.o',
    '.bin',
    '.jar',
  ];

  /// Binary assets cannot be decoded as UTF-8 text by [FileSystemProvider.read].
  static bool isBinary(String name) {
    final lower = name.toLowerCase();
    return _binaryExtensions.any(lower.endsWith);
  }

  static bool isRasterImage(String name) {
    final lower = name.toLowerCase();
    return _rasterExtensions.any(lower.endsWith);
  }

  static bool isSvg(String name) => name.toLowerCase().endsWith('.svg');

  static DocumentKind kindForName(String name) {
    if (isRasterImage(name)) return DocumentKind.image;
    if (isSvg(name)) return DocumentKind.svg;
    return DocumentKind.text;
  }

  Future<OpenDocument> open(FileEntry entry) async {
    final existing = documents.where((d) => d.uri == entry.uri).firstOrNull;
    if (existing != null) {
      activeId = existing.id;
      return existing;
    }
    final kind = kindForName(entry.name);
    if (kind == DocumentKind.image) {
      final bytes = await files.readBytes(entry.uri);
      return create(
        entry.name,
        '',
        uri: entry.uri,
        savedText: '',
        kind: kind,
        bytes: bytes,
      );
    }
    if (isBinary(entry.name)) {
      throw UnsupportedError(
        'Cannot open binary file “${entry.name}” as text. '
        'Image and SVG previews are supported; other binary formats are not.',
      );
    }
    final text = await files.read(entry.uri);
    return create(
      entry.name,
      text,
      uri: entry.uri,
      savedText: text,
      kind: kind,
    );
  }

  Future<bool> save(OpenDocument doc, {bool saveAs = false}) async {
    if (doc.kind == DocumentKind.image) {
      // Raster previews are view-only; nothing to write back as text.
      return true;
    }
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
