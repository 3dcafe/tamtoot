import 'dart:io';
import '../core/filesystem/filesystem.dart';

Future<String> readLocal(Uri uri) => File.fromUri(uri).readAsString();
Future<void> writeLocal(Uri uri, String text) async {
  await File.fromUri(uri).writeAsString(text, flush: true);
}

Future<List<FileEntry>> listLocal(Uri uri) async {
  final entries = <FileEntry>[];
  await for (final e in Directory.fromUri(uri).list(followLinks: false)) {
    final name = e.uri.pathSegments.where((p) => p.isNotEmpty).last;
    if (name.startsWith('.')) continue;
    if (e is File || e is Directory) {
      entries.add(FileEntry(e.uri, name, directory: e is Directory));
    }
  }
  entries.sort(
    (a, b) => a.directory == b.directory
        ? a.name.compareTo(b.name)
        : a.directory
        ? -1
        : 1,
  );
  return entries;
}
