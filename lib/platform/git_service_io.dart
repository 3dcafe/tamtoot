import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/git/git_service.dart';
import '../core/git/git_ignore.dart';
import '../core/git/git_store.dart';
import '../core/git/http_git_service.dart';
import 'git_shared.dart';

/// File-backed repository store for mobile / desktop.
final class FileGitRepositoryStore extends GitRepositoryStore {
  FileGitRepositoryStore(this.root);
  final Directory root;

  File _file(String path) => File.fromUri(root.uri.resolveUri(Uri(path: path)));
  Directory _dir(String path) =>
      Directory.fromUri(root.uri.resolveUri(Uri(path: path)));

  @override
  Future<void> validateRegularFilePath(String path) async {
    var relative = '';
    for (final part in path.split('/')) {
      relative = relative.isEmpty ? part : '$relative/$part';
      if (await FileSystemEntity.type(
            _file(relative).path,
            followLinks: false,
          ) ==
          FileSystemEntityType.link) {
        throw GitException(
          'Comparison and discard do not follow symbolic links',
        );
      }
    }
  }

  @override
  Future<bool> exists(String path) async {
    final file = _file(path);
    if (await file.exists()) return true;
    return _dir(path).exists();
  }

  @override
  Future<Uint8List> readBytes(String path) => _file(path).readAsBytes();

  @override
  Future<int> byteLength(String path) => _file(path).length();

  @override
  Future<Uint8List> readByteRange(String path, int start, int end) async {
    final input = await _file(path).open();
    try {
      await input.setPosition(start);
      return input.read(end - start);
    } finally {
      await input.close();
    }
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    final file = _file(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> delete(String path) async {
    final file = _file(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> createDirectory(String path) async {
    await _dir(path).create(recursive: true);
  }

  @override
  Future<List<String>> listFiles(String dir) async {
    final base = dir.isEmpty ? root : _dir(dir);
    if (!await base.exists()) return const [];
    final out = <String>[];
    final includeMetadata =
        dir.startsWith('.git/') || dir.startsWith('.tamtoot/');
    await for (final entity in base.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = _relative(entity.path);
      if (!includeMetadata && (rel == '.git' || rel.startsWith('.git/'))) {
        continue;
      }
      out.add(rel);
    }
    return out;
  }

  @override
  Future<List<String>> listGitWorkFiles() async {
    final baseIgnore = GitIgnore();
    final infoExclude = _file('.git/info/exclude');
    if (await infoExclude.exists()) {
      baseIgnore.add(await infoExclude.readAsString());
    }
    final out = <String>[];

    Future<void> walk(
      Directory directory,
      String relative,
      GitIgnore inherited,
    ) async {
      final ignore = inherited.copy();
      final ignoreFile = File.fromUri(directory.uri.resolve('.gitignore'));
      if (await ignoreFile.exists()) {
        ignore.add(await ignoreFile.readAsString(), base: relative);
      }
      await for (final entity in directory.list(followLinks: false)) {
        final path = _relative(entity.path);
        if (relative.isEmpty && path == '.git') continue;
        if (entity is Directory) {
          if (ignore.ignores(path, directory: true)) continue;
          await walk(entity, path, ignore);
        } else if (entity is File && !ignore.ignores(path, directory: false)) {
          out.add(path);
        }
      }
    }

    await walk(root, '', baseIgnore);
    return out;
  }

  String _relative(String absolute) {
    final rootPath = root.path.endsWith(Platform.pathSeparator)
        ? root.path
        : '${root.path}${Platform.pathSeparator}';
    var rel = absolute.startsWith(rootPath)
        ? absolute.substring(rootPath.length)
        : absolute;
    return rel.replaceAll('\\', '/');
  }
}

/// Mobile/desktop git client over HTTPS Smart HTTP — no system git required.
class PlatformGitService extends HttpGitService {
  PlatformGitService({http.Client? client})
    : super(
        transport: PackageHttpTransport(client: client),
        openStore: (uri) {
          if (uri.scheme != 'file') {
            throw ArgumentError('Expected file:// directory, got $uri');
          }
          return FileGitRepositoryStore(Directory.fromUri(uri));
        },
        inflateAt: sharedInflateAt,
        deflate: sharedDeflate,
      );
}

GitService createGitService({String? gitExecutable}) => PlatformGitService();
