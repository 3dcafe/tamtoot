import 'dart:typed_data';

/// Apply a git binary delta (from pack ofs/ref delta) onto [base].
Uint8List applyGitDelta(List<int> base, List<int> delta) {
  var i = 0;
  final (baseSize, i1) = _readVarInt(delta, i);
  i = i1;
  if (baseSize != base.length) {
    throw FormatException(
      'Delta base size mismatch: expected $baseSize, got ${base.length}',
    );
  }
  final (targetSize, i2) = _readVarInt(delta, i);
  i = i2;
  final out = BytesBuilder(copy: false);
  while (i < delta.length) {
    final op = delta[i++];
    if (op == 0) continue;
    if ((op & 0x80) != 0) {
      var offset = 0;
      var size = 0;
      if ((op & 0x01) != 0) offset |= delta[i++];
      if ((op & 0x02) != 0) offset |= delta[i++] << 8;
      if ((op & 0x04) != 0) offset |= delta[i++] << 16;
      if ((op & 0x08) != 0) offset |= delta[i++] << 24;
      if ((op & 0x10) != 0) size |= delta[i++];
      if ((op & 0x20) != 0) size |= delta[i++] << 8;
      if ((op & 0x40) != 0) size |= delta[i++] << 16;
      if (size == 0) size = 0x10000;
      out.add(base.sublist(offset, offset + size));
    } else {
      final size = op;
      out.add(delta.sublist(i, i + size));
      i += size;
    }
  }
  final result = out.toBytes();
  if (result.length != targetSize) {
    throw FormatException(
      'Delta target size mismatch: expected $targetSize, got ${result.length}',
    );
  }
  return result;
}

(int, int) _readVarInt(List<int> data, int offset) {
  var value = 0;
  var shift = 0;
  var i = offset;
  while (true) {
    if (i >= data.length) throw FormatException('Truncated delta varint');
    final b = data[i++];
    value |= (b & 0x7f) << shift;
    if ((b & 0x80) == 0) return (value, i);
    shift += 7;
  }
}
