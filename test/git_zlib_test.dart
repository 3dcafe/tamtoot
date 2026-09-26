import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/platform/git_shared.dart';

void main() {
  test('archiveInflateAt consumes only the zlib stream', () {
    final payload = List<int>.generate(400, (i) => i % 251);
    final zlib = const ZLibEncoder().encodeBytes(payload);
    final pack = Uint8List.fromList([
      ...zlib,
      0x50, 0x41, 0x43, 0x4b, // trailing PACK-like bytes must stay
      1, 2, 3, 4,
    ]);
    final result = archiveInflateAt(pack, 0);
    expect(result.data, payload);
    expect(result.next, zlib.length);
    expect(pack[result.next], 0x50);
  });
}
