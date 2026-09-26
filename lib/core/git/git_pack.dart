import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'git_delta.dart';
import 'git_objects.dart';

/// Decode zlib starting at [offset]; return data and index after the stream.
typedef GitInflaterAt =
    ({Uint8List data, int next}) Function(List<int> pack, int offset);

typedef GitDeflater = Uint8List Function(List<int> data);

final class UnpackedObject {
  UnpackedObject(this.type, this.data, this.hash);
  final GitObjectType type;
  final Uint8List data;
  final String hash;
}

/// Parse a packfile body into inflated git objects (supports ofs/ref deltas).
List<UnpackedObject> unpackPackfile(List<int> pack, GitInflaterAt inflateAt) {
  if (pack.length < 12) throw FormatException('Pack too short');
  if (pack[0] != 0x50 ||
      pack[1] != 0x41 ||
      pack[2] != 0x43 ||
      pack[3] != 0x4b) {
    throw FormatException('Missing PACK magic');
  }
  final version = (pack[4] << 24) | (pack[5] << 16) | (pack[6] << 8) | pack[7];
  if (version != 2 && version != 3) {
    throw FormatException('Unsupported pack version $version');
  }
  final count = (pack[8] << 24) | (pack[9] << 16) | (pack[10] << 8) | pack[11];

  var offset = 12;
  final byOffset = <int, UnpackedObject>{};
  final byHash = <String, UnpackedObject>{};
  final ordered = <UnpackedObject>[];

  for (var n = 0; n < count; n++) {
    final start = offset;
    var byte = pack[offset++];
    var typeCode = (byte >> 4) & 0x7;
    var sizeField = byte & 0x0f;
    var shift = 4;
    while ((byte & 0x80) != 0) {
      byte = pack[offset++];
      sizeField |= (byte & 0x7f) << shift;
      shift += 7;
    }
    assert(sizeField >= 0);

    late final UnpackedObject obj;
    if (typeCode == 6) {
      var c = pack[offset++];
      var baseOffset = c & 0x7f;
      while ((c & 0x80) != 0) {
        c = pack[offset++];
        baseOffset += 1;
        baseOffset = (baseOffset << 7) | (c & 0x7f);
      }
      final inflated = inflateAt(pack, offset);
      offset = inflated.next;
      final base = byOffset[start - baseOffset];
      if (base == null) {
        throw FormatException(
          'Missing ofs-delta base at ${start - baseOffset}',
        );
      }
      final data = applyGitDelta(base.data, inflated.data);
      obj = UnpackedObject(base.type, data, hashObject(base.type, data));
    } else if (typeCode == 7) {
      final baseHash = bytesToHex(pack.sublist(offset, offset + 20));
      offset += 20;
      final inflated = inflateAt(pack, offset);
      offset = inflated.next;
      final base = byHash[baseHash];
      if (base == null) {
        throw FormatException('Missing ref-delta base $baseHash');
      }
      final data = applyGitDelta(base.data, inflated.data);
      obj = UnpackedObject(base.type, data, hashObject(base.type, data));
    } else {
      final type = GitObjectType.fromCode(typeCode);
      final inflated = inflateAt(pack, offset);
      offset = inflated.next;
      obj = UnpackedObject(
        type,
        inflated.data,
        hashObject(type, inflated.data),
      );
    }
    byOffset[start] = obj;
    byHash[obj.hash] = obj;
    ordered.add(obj);
  }

  return ordered;
}

/// Build a version-2 pack from inflated objects (no deltas). Includes trailing SHA-1.
Uint8List buildPackfile(List<GitObject> objects, GitDeflater deflate) {
  final body = BytesBuilder(copy: false)
    ..add([0x50, 0x41, 0x43, 0x4b])
    ..add([0, 0, 0, 2]);
  final count = objects.length;
  body.add([
    (count >> 24) & 0xff,
    (count >> 16) & 0xff,
    (count >> 8) & 0xff,
    count & 0xff,
  ]);

  for (final obj in objects) {
    final typeCode = obj.type.code;
    var size = obj.content.length;
    var first = (typeCode << 4) | (size & 0x0f);
    size >>= 4;
    if (size != 0) first |= 0x80;
    body.addByte(first);
    while (size != 0) {
      var b = size & 0x7f;
      size >>= 7;
      if (size != 0) b |= 0x80;
      body.addByte(b);
    }
    body.add(deflate(obj.content));
  }

  final content = body.toBytes();
  final digest = sha1.convert(content).bytes;
  return Uint8List.fromList([...content, ...digest]);
}
