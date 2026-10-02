import 'dart:convert';
import 'dart:typed_data';

class FileEntry {
  const FileEntry(this.uri, this.name, {this.directory = false});
  final Uri uri;
  final String name;
  final bool directory;
}

/// URI-based boundary supports local, SAF, remote and plugin providers.
abstract interface class FileSystemProvider {
  Future<String> read(Uri uri);
  Future<Uint8List> readBytes(Uri uri);
  Future<void> write(Uri uri, String text);
  Future<List<FileEntry>> list(Uri directory);
  bool canWrite(Uri uri);
}

abstract interface class FileDialogs {
  Future<FileEntry?> open();
  Future<Uri?> save(String name, String content);
  Future<Uri?> openWorkspace();
  bool get supportsDirectories;
}

abstract interface class PersistenceStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class MemoryFileSystem implements FileSystemProvider {
  final Map<Uri, String> files = {};
  final Map<Uri, Uint8List> binaryFiles = {};
  @override
  bool canWrite(Uri uri) => uri.scheme == 'memory';
  @override
  Future<String> read(Uri uri) async {
    final text = files[uri];
    if (text != null) return text;
    final bytes = binaryFiles[uri];
    if (bytes != null) return utf8.decode(bytes);
    throw StateError('File not found: $uri');
  }

  @override
  Future<Uint8List> readBytes(Uri uri) async {
    final bytes = binaryFiles[uri];
    if (bytes != null) return Uint8List.fromList(bytes);
    final text = files[uri];
    if (text != null) return Uint8List.fromList(utf8.encode(text));
    throw StateError('File not found: $uri');
  }

  @override
  Future<void> write(Uri uri, String text) async {
    files[uri] = text;
    binaryFiles.remove(uri);
  }

  Future<void> writeBytes(Uri uri, Uint8List bytes) async {
    binaryFiles[uri] = Uint8List.fromList(bytes);
    files.remove(uri);
  }

  @override
  Future<List<FileEntry>> list(Uri directory) async => [
    for (final uri in {...files.keys, ...binaryFiles.keys})
      if (uri.toString().startsWith(directory.toString()))
        FileEntry(uri, uri.pathSegments.last),
  ];
}
