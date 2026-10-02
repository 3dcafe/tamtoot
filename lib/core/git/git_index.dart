import 'dart:convert';
import 'dart:typed_data';
import 'git_objects.dart';
import 'git_service.dart';

/// Ordinary index v2/v3 support. Refuse specialized indexes rather than
/// discarding conflicts, sparse checkout flags or someone else's staging.
Map<String, TreeEntry> readGitIndex(Uint8List bytes) {
  if (bytes.length < 32 || ascii.decode(bytes.sublist(0, 4)) != 'DIRC') {
    throw GitException('Unsupported Git index');
  }
  final data = ByteData.sublistView(bytes);
  final version = data.getUint32(4);
  if ((version != 2 && version != 3) ||
      hashHex(bytes.sublist(0, bytes.length - 20)) !=
          bytesToHex(bytes.sublist(bytes.length - 20))) {
    throw GitException(
      'Unsupported or corrupt Git index. Tamtoot supports standard index v2/v3.',
    );
  }
  var offset = 12;
  final result = <String, TreeEntry>{};
  for (var i = 0; i < data.getUint32(8); i++) {
    final start = offset;
    if (offset + 62 >= bytes.length - 20) {
      throw GitException('Truncated Git index');
    }
    final flags = data.getUint16(offset + 60);
    final stage = (flags >> 12) & 0x3;
    final extended = (flags & 0x4000) != 0;
    if (stage != 0 || extended) {
      throw GitException(
        'Resolve index conflicts, sparse entries or intent-to-add flags with your other Git client first.',
      );
    }
    final mode = data.getUint32(offset + 24).toRadixString(8);
    final hash = bytesToHex(bytes.sublist(offset + 40, offset + 60));
    final end = bytes.indexOf(0, offset + 62);
    if (end < 0 || end >= bytes.length - 20) {
      throw GitException('Truncated index path');
    }
    final name = utf8.decode(bytes.sublist(offset + 62, end));
    result[name] = TreeEntry(mode, name, hash);
    offset = start + ((end - start + 1 + 7) ~/ 8) * 8;
  }
  // Optional uppercase extensions (e.g. TREE) can be regenerated. Required
  // lowercase extensions are not safe to ignore (e.g. a split index).
  while (offset < bytes.length - 20) {
    if (offset + 8 > bytes.length - 20 ||
        bytes[offset] < 65 ||
        bytes[offset] > 90) {
      throw GitException('Unsupported Git index extension');
    }
    offset += 8 + data.getUint32(offset + 4);
  }
  if (offset != bytes.length - 20) {
    throw GitException('Invalid Git index extension');
  }
  return result;
}

Uint8List encodeGitIndex(List<TreeEntry> files) {
  final sorted = [...files]
    ..sort((a, b) {
      final left = utf8.encode(a.name), right = utf8.encode(b.name);
      for (var i = 0; i < left.length && i < right.length; i++) {
        if (left[i] != right[i]) return left[i].compareTo(right[i]);
      }
      return left.length.compareTo(right.length);
    });
  final output = BytesBuilder();
  final header = ByteData(12)
    ..setUint32(0, 0x44495243)
    ..setUint32(4, 2)
    ..setUint32(8, sorted.length);
  output.add(header.buffer.asUint8List());
  for (final file in sorted) {
    final path = utf8.encode(file.name);
    final length = ((62 + path.length + 1 + 7) ~/ 8) * 8;
    final bytes = Uint8List(length);
    final data = ByteData.sublistView(bytes);
    // Zero stat cache makes other Git clients recheck the file on next status.
    data.setUint32(24, int.parse(file.mode, radix: 8));
    data.setUint16(60, path.length < 0xfff ? path.length : 0xfff);
    bytes.setRange(40, 60, hexToBytes(file.hash));
    bytes.setRange(62, 62 + path.length, path);
    output.add(bytes);
  }
  final content = output.toBytes();
  return Uint8List.fromList([...content, ...hexToBytes(hashHex(content))]);
}
