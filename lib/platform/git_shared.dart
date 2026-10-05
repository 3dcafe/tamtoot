import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import '../core/git/git_http.dart';
import '../core/git/git_pack.dart';
import '../core/git/git_service.dart';

/// Inflate one zlib stream from [pack] at [offset], returning consumed end index.
///
/// Uses archive's pure-Dart [Inflate] so only the zlib member is consumed
/// (dart:io's [ZLibDecoder] / archive's IO [decodeStream] would eat trailing
/// pack bytes and desync object boundaries → "Unknown git object type 0").
({Uint8List data, int next}) archiveInflateAt(List<int> pack, int offset) {
  if (offset >= pack.length) {
    throw FormatException('zlib offset past end of pack ($offset)');
  }
  final input = InputMemoryStream(
    pack,
    offset: offset,
    byteOrder: ByteOrder.bigEndian,
  );
  try {
    if (input.length < 2) {
      throw const FormatException('Truncated zlib header');
    }
    final cmf = input.readByte();
    final flg = input.readByte();
    if ((cmf & 0x0f) != 8) {
      throw FormatException('Unsupported zlib method: ${cmf & 0x0f}');
    }
    if (((cmf << 8) + flg) % 31 != 0) {
      throw const FormatException('Invalid zlib header check');
    }
    if ((flg & 0x20) != 0) {
      if (input.length < 4) {
        throw const FormatException('Truncated zlib dictionary');
      }
      input.readUint32();
    }

    final data = Inflate.stream(input).getBytes();
    if (input.length < 4) {
      throw const FormatException('Truncated zlib checksum');
    }
    input.readUint32(); // Adler-32

    return (data: Uint8List.fromList(data), next: offset + input.position);
  } catch (e) {
    if (e is FormatException) rethrow;
    throw FormatException('zlib inflate at $offset: $e');
  }
}

Uint8List archiveDeflate(List<int> data) =>
    Uint8List.fromList(const ZLibEncoder().encodeBytes(data));

final class PackageHttpTransport
    implements GitHttpTransport, GitTransferProgressProvider {
  PackageHttpTransport({http.Client? client})
    : _client = client ?? http.Client();
  final http.Client _client;
  @override
  void Function(GitProgress)? onTransferProgress;

  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final request = http.Request(method, url);
    if (headers != null) request.headers.addAll(headers);
    if (body != null) request.bodyBytes = body;
    final callback = onTransferProgress;
    callback?.call(const GitProgress('Waiting for server…'));
    final streamed = await _client.send(request);
    final total = streamed.contentLength;
    var received = 0;
    final bytes = BytesBuilder(copy: false);
    final timer = Stopwatch()..start();
    void report() => callback?.call(
      GitProgress(
        'Downloading repository…',
        completed: received,
        total: total,
        unit: 'bytes',
      ),
    );
    report();
    await for (final chunk in streamed.stream) {
      bytes.add(chunk);
      received += chunk.length;
      if (timer.elapsedMilliseconds >= 100) {
        report();
        timer.reset();
      }
    }
    report();
    return GitHttpResponse(
      statusCode: streamed.statusCode,
      body: bytes.takeBytes(),
      contentType: streamed.headers['content-type'],
    );
  }
}

GitInflaterAt get sharedInflateAt => archiveInflateAt;
GitDeflater get sharedDeflate => archiveDeflate;
