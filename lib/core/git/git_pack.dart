import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'git_delta.dart';
import 'git_objects.dart';

/// Decode zlib starting at [offset]; return data and index after the stream.
typedef GitInflaterAt =
    ({Uint8List data, int next}) Function(List<int> pack, int offset);

typedef GitDeflater = Uint8List Function(List<int> data);

/// Version-2 pack index used by ordinary desktop Git clones.
/// Object names are kept in the original sorted byte table and looked up with
/// binary search so large repositories do not allocate one String per object.
final class GitPackIndex {
  GitPackIndex._(this.bytes, this.count, this._offsets, this.packChecksum);

  final Uint8List bytes;
  final int count;
  final List<int> _offsets;
  final String packChecksum;

  int? offsetForHash(String hash) {
    final target = hexToBytes(hash);
    var low = 0, high = count - 1;
    const namesStart = 8 + 256 * 4;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final start = namesStart + middle * 20;
      var comparison = 0;
      for (var i = 0; i < 20; i++) {
        comparison = bytes[start + i].compareTo(target[i]);
        if (comparison != 0) break;
      }
      if (comparison == 0) return _offsetAt(middle);
      if (comparison < 0) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return null;
  }

  int endForOffset(int offset, int packLength) {
    var low = 0, high = _offsets.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_offsets[middle] <= offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low < _offsets.length ? _offsets[low] : packLength - 20;
  }

  int _offsetAt(int objectIndex) {
    const namesStart = 8 + 256 * 4;
    final offsetsStart = namesStart + count * 20 + count * 4;
    final data = ByteData.sublistView(bytes);
    final raw = data.getUint32(offsetsStart + objectIndex * 4);
    if ((raw & 0x80000000) == 0) return raw;
    final largeIndex = raw & 0x7fffffff;
    final largeStart = offsetsStart + count * 4;
    return data.getUint64(largeStart + largeIndex * 8);
  }
}

GitPackIndex readGitPackIndex(Uint8List bytes) {
  if (bytes.length < 8 + 256 * 4 + 40) {
    throw const FormatException('Pack index is truncated');
  }
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(0) != 0xff744f63 || data.getUint32(4) != 2) {
    throw const FormatException('Unsupported Git pack index version');
  }
  final count = data.getUint32(8 + 255 * 4);
  const namesStart = 8 + 256 * 4;
  final offsetsStart = namesStart + count * 20 + count * 4;
  if (offsetsStart + count * 4 + 40 > bytes.length) {
    throw const FormatException('Pack index tables are truncated');
  }
  final regularOffsets = <int>[];
  var largestLargeIndex = -1;
  for (var i = 0; i < count; i++) {
    final raw = data.getUint32(offsetsStart + i * 4);
    if ((raw & 0x80000000) == 0) {
      regularOffsets.add(raw);
    } else {
      final largeIndex = raw & 0x7fffffff;
      if (largeIndex > largestLargeIndex) largestLargeIndex = largeIndex;
    }
  }
  final largeStart = offsetsStart + count * 4;
  if (largeStart + (largestLargeIndex + 1) * 8 + 40 > bytes.length) {
    throw const FormatException('Pack index large offsets are truncated');
  }
  for (var i = 0; i <= largestLargeIndex; i++) {
    regularOffsets.add(data.getUint64(largeStart + i * 8));
  }
  regularOffsets.sort();
  final packChecksumAt = bytes.length - 40;
  final expectedIndexChecksum = bytesToHex(bytes.sublist(bytes.length - 20));
  if (hashHex(bytes.sublist(0, bytes.length - 20)) != expectedIndexChecksum) {
    throw const FormatException('Pack index checksum mismatch');
  }
  return GitPackIndex._(
    bytes,
    count,
    regularOffsets,
    bytesToHex(bytes.sublist(packChecksumAt, packChecksumAt + 20)),
  );
}

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
      if (typeCode < 1 || typeCode > 4) {
        throw FormatException(
          'Unknown git object type $typeCode at pack offset $start '
          '(object ${n + 1}/$count)',
        );
      }
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
