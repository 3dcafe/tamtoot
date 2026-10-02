import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/filesystem/filesystem.dart';
import 'package:tamtoot/workspace/documents/document_service.dart';

import 'support.dart';

void main() {
  test('opening a PNG loads bytes instead of decoding UTF-8 text', () async {
    final files = MemoryFileSystem();
    final uri = Uri.parse('memory:///assets/branding/icon.png');
    // Minimal PNG-like binary that is not valid UTF-8.
    final bytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0xff]);
    await files.writeBytes(uri, bytes);

    final docs = DocumentService(files, FakeDialogs());
    final doc = await docs.open(FileEntry(uri, 'icon.png'));

    expect(doc.kind, DocumentKind.image);
    expect(doc.bytes, bytes);
    expect(doc.dirty, isFalse);
    expect(doc.editor.text, isEmpty);
  });

  test('opening an SVG keeps editable source and marks svg kind', () async {
    final files = MemoryFileSystem();
    final uri = Uri.parse('memory:///assets/branding/icon.svg');
    const source =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
        '<rect width="10" height="10" fill="#42A5FF"/></svg>';
    await files.write(uri, source);

    final docs = DocumentService(files, FakeDialogs());
    final doc = await docs.open(FileEntry(uri, 'icon.svg'));

    expect(doc.kind, DocumentKind.svg);
    expect(doc.editor.text, source);
    expect(doc.isMediaPreview, isTrue);
    expect(doc.dirty, isFalse);

    doc.editor.replaceSelection(' ');
    expect(doc.dirty, isTrue);
  });

  test('unsupported binary files fail with a clear message', () async {
    final files = MemoryFileSystem();
    final uri = Uri.parse('memory:///lib/native.so');
    await files.writeBytes(uri, Uint8List.fromList([0, 1, 2, 3]));
    final docs = DocumentService(files, FakeDialogs());

    await expectLater(
      docs.open(FileEntry(uri, 'native.so')),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('Cannot open binary file'),
        ),
      ),
    );
  });

  test('reopening the same image activates the existing tab', () async {
    final files = MemoryFileSystem();
    final uri = Uri.parse('memory:///icon.png');
    await files.writeBytes(uri, Uint8List.fromList([1, 2, 3]));
    final docs = DocumentService(files, FakeDialogs());
    final first = await docs.open(FileEntry(uri, 'icon.png'));
    docs.create('other.dart', 'void main() {}');
    final again = await docs.open(FileEntry(uri, 'icon.png'));
    expect(identical(first, again), isTrue);
    expect(docs.activeId, first.id);
  });
}
