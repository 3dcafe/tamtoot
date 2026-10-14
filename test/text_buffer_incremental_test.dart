import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/editor/buffer/text_buffer.dart';

void main() {
  test('incremental line index matches full rebuild across random edits', () {
    final random = Random(729);
    var text = 'first\n\nlast 🌍\n';
    final buffer = IndexedTextBuffer(text);
    final chunks = ['', 'x', '\n', '\n\n', 'hello\nworld', 'я', '🌍', '\r\n'];
    for (var step = 0; step < 1500; step++) {
      final start = random.nextInt(text.length + 1);
      final end = start + random.nextInt(text.length - start + 1);
      final inserted = chunks[random.nextInt(chunks.length)];
      expect(
        buffer.applyEdit(BufferEdit(start, end, inserted)),
        text.substring(start, end),
      );
      text = text.replaceRange(start, end, inserted);
      // Raw edits can contain CRLF, so compare with a literal line reference.
      final lines = text.split('\n');
      expect(buffer.getText(0, buffer.length), text);
      expect(buffer.lineCount, lines.length);
      var offset = 0;
      for (var line = 0; line < lines.length; line++) {
        expect(
          buffer.getLine(line),
          lines[line],
          reason: 'step $step line $line',
        );
        expect(
          buffer.offsetAt(TextPoint(line, 99999)),
          offset + lines[line].length,
        );
        for (var column = 0; column <= lines[line].length; column++) {
          final point = buffer.positionAt(offset + column);
          expect((point.line, point.column), (line, column));
        }
        offset += lines[line].length + 1;
      }
    }
  });
}
