import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../core/git/git_http.dart';
import '../core/git/git_service.dart';
import '../core/git/git_store.dart';
import '../core/git/http_git_service.dart';

/// File-backed repository store for mobile / desktop.
final class FileGitRepositoryStore extends GitRepositoryStore {
  FileGitRepositoryStore(this.root);
  final Directory root;

  File _file(String path) => File.fromUri(root.uri.resolve(path));
  Directory _dir(String path) => Directory.fromUri(root.uri.resolve(path));

  @override
  Future<bool> exists(String path) async {
    final file = _file(path);
    if (await file.exists()) return true;
    return _dir(path).exists();
  }

  @override
  Future<Uint8List> readBytes(String path) => _file(path).readAsBytes();

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
    await for (final entity in base.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = _relative(entity.path);
      if (rel == '.git' || rel.startsWith('.git/')) continue;
      out.add(rel);
    }
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

final class IoGitHttpTransport implements GitHttpTransport {
  IoGitHttpTransport({HttpClient? client}) : _client = client ?? HttpClient();
  final HttpClient _client;

  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final request = await _client.openUrl(method, url);
    headers?.forEach(request.headers.set);
    if (body != null) {
      request.add(body);
    }
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      <int>[],
      (prev, chunk) => prev..addAll(chunk),
    );
    return GitHttpResponse(
      statusCode: response.statusCode,
      body: Uint8List.fromList(bytes),
      contentType: response.headers.contentType?.mimeType,
    );
  }
}

/// Find end of a zlib stream via smallest successful inflate window.
({Uint8List data, int next}) ioInflateAt(List<int> pack, int offset) {
  FormatException? last;
  // Exponential grow then binary-search the end for speed on large objects.
  var size = 32;
  final remaining = pack.length - offset;
  while (size < remaining) {
    try {
      final slice = pack.sublist(offset, offset + size);
      final data = ZLibCodec().decode(slice);
      // Success may include trailing junk that Dart rejects — try shrink.
      return _shrinkInflate(pack, offset, size, Uint8List.fromList(data));
    } catch (e) {
      last = FormatException('$e');
      size = min(remaining, size * 2);
    }
  }
  try {
    final data = ZLibCodec().decode(pack.sublist(offset));
    return (data: Uint8List.fromList(data), next: pack.length);
  } catch (e) {
    throw last ?? FormatException('$e');
  }
}

({Uint8List data, int next}) _shrinkInflate(
  List<int> pack,
  int offset,
  int maxSize,
  Uint8List data,
) {
  var low = 2;
  var high = maxSize;
  var best = maxSize;
  while (low <= high) {
    final mid = (low + high) >> 1;
    try {
      final decoded = ZLibCodec().decode(pack.sublist(offset, offset + mid));
      // Prefer smallest window that yields same length (complete stream).
      if (decoded.length == data.length) {
        best = mid;
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    } catch (_) {
      low = mid + 1;
    }
  }
  return (
    data: Uint8List.fromList(
      ZLibCodec().decode(pack.sublist(offset, offset + best)),
    ),
    next: offset + best,
  );
}

Uint8List ioDeflate(List<int> data) =>
    Uint8List.fromList(ZLibCodec().encode(data));

/// Mobile/desktop git client over HTTPS Smart HTTP — no system git required.
class PlatformGitService extends HttpGitService {
  PlatformGitService({HttpClient? client})
    : super(
        transport: IoGitHttpTransport(client: client),
        openStore: (uri) {
          if (uri.scheme != 'file') {
            throw ArgumentError('Expected file:// directory, got $uri');
          }
          return FileGitRepositoryStore(Directory.fromUri(uri));
        },
        inflateAt: ioInflateAt,
        deflate: ioDeflate,
      );
}

GitService createGitService({String? gitExecutable}) => PlatformGitService();
