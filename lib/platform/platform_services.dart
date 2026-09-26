import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/filesystem/filesystem.dart';
import 'local_files.dart';
import 'workspace_roots.dart';

class PreferenceStore implements PersistenceStore {
  PreferenceStore(this.preferences);
  final SharedPreferences preferences;
  @override
  Future<String?> read(String key) async =>
      preferences.getString('tamtoot.$key');
  @override
  Future<void> write(String key, String value) async {
    if (!await preferences.setString('tamtoot.$key', value)) {
      throw StateError('Unable to persist $key');
    }
  }
}

class PlatformFiles implements FileSystemProvider, FileDialogs {
  final _opened = <Uri, XFile>{};
  static const _android = MethodChannel('dev.tamtoot/documents');
  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  @override
  bool get supportsDirectories =>
      !kIsWeb && !_isAndroid && defaultTargetPlatform != TargetPlatform.iOS;
  @override
  bool canWrite(Uri uri) =>
      !kIsWeb &&
      !_isAndroid &&
      defaultTargetPlatform != TargetPlatform.iOS &&
      uri.scheme == 'file';
  @override
  Future<FileEntry?> open() async {
    final file = await openFile();
    if (file == null) return null;
    final uri = kIsWeb
        ? Uri.parse('picked://${Uri.encodeComponent(file.name)}')
        : Uri.file(file.path);
    _opened[uri] = file;
    return FileEntry(uri, file.name);
  }

  @override
  Future<String> read(Uri uri) async {
    if (_opened.containsKey(uri)) return _opened[uri]!.readAsString();
    final virtual = await WorkspaceRoots.readText(uri);
    if (virtual != null) return virtual;
    return readLocal(uri);
  }

  @override
  Future<void> write(Uri uri, String text) => writeLocal(uri, text);
  @override
  Future<List<FileEntry>> list(Uri directory) async {
    if (WorkspaceRoots.contains(directory)) {
      return WorkspaceRoots.listEntries(directory);
    }
    return listLocal(directory);
  }

  @override
  Future<Uri?> openWorkspace() async {
    if (!supportsDirectories) {
      throw UnsupportedError(
        'Use Open file on this platform; directory provider is not available yet.',
      );
    }
    final path = await getDirectoryPath();
    return path == null ? null : Uri.directory(path);
  }

  @override
  Future<Uri?> save(String name, String content) async {
    if (_isAndroid) {
      final uri = await _android.invokeMethod<String>('saveText', {
        'name': name,
        'text': content,
      });
      return uri == null ? null : Uri.parse(uri);
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      throw UnsupportedError(
        'File export on iOS requires a document provider. Drafts remain in the local session.',
      );
    }
    final file = XFile.fromData(
      Uint8List.fromList(utf8.encode(content)),
      name: name,
      mimeType: 'text/plain',
    );
    if (kIsWeb) {
      await file.saveTo(name);
      return Uri.parse('download://${Uri.encodeComponent(name)}');
    }
    final target = await getSaveLocation(suggestedName: name);
    if (target == null) return null;
    await file.saveTo(target.path);
    return Uri.file(target.path);
  }
}
