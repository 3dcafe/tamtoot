import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/terminal/terminal_screen.dart';

void feed(TerminalScreen screen, String value) =>
    screen.add(utf8.encode(value));
void main() {
  test(
    'alternate screen restores margins, origin, charset; colon RGB and origin DSR',
    () {
      final replies = <String>[];
      final s = TerminalScreen(
        columns: 12,
        rows: 5,
        onReply: (b) => replies.add(utf8.decode(b)),
      );
      feed(
        s,
        '\x1b[2;4r\x1b[?6h\x1b(0\x1b[2;1H\x1b[?1049hALT\x1b[?1049lq\x1b[6n',
      );
      expect(s.lines[2][0].text, '─');
      expect(replies.last, '\x1b[2;2R');
      feed(s, '\x1b(B\x1b[38:2::12:34:56mC');
      expect(s.lines[2][1].style.foreground, 0xff0c2238);
    },
  );

  test(
    'decomposed Hangul forms one wide syllable; ZWJ does not consume ASCII',
    () {
      final s = TerminalScreen(columns: 12, rows: 2);
      feed(s, '한a\u200db');
      expect(s.lines[0][0].text, '한');
      expect(s.lines[0][0].width, 2);
      expect(s.lines[0][2].text, 'a\u200d');
      expect(s.lines[0][3].text, 'b');
    },
  );

  test('emoji flags, ZWJ, modifiers and VS16 occupy a single wide cluster', () {
    final s = TerminalScreen(columns: 20, rows: 2);
    feed(s, '🇷🇺👩🏽‍💻☀️X');
    expect(s.lines[0][0].text, '🇷🇺');
    expect(s.lines[0][0].width, 2);
    expect(s.lines[0][2].text, '👩🏽‍💻');
    expect(s.lines[0][2].width, 2);
    expect(s.lines[0][4].text, '☀️');
    expect(s.lines[0][4].width, 2);
    expect(s.lines[0][6].text, 'X');
    expect(s.cursorX, 7);
  });

  test('fragmented UTF-8/CSI, controls, overwrite and delayed wrap', () {
    final s = TerminalScreen(columns: 6, rows: 3);
    final bytes = utf8.encode('привет\r\n界e\u0301\x1b[1;1HOK');
    for (final b in bytes) {
      s.add([b]);
    }
    expect(s.lines[0].take(2).map((c) => c.text).join(), 'OK');
    expect(s.lines[1][0].text, '界');
    expect(s.lines[1][1].width, 0);
    expect(s.lines[1][2].text, 'e\u0301');
    feed(s, '\x1b[3;1Habcdef');
    expect(s.cursorY, 2);
    expect(s.historyLength, 0);
    feed(s, 'X');
    expect(s.historyLength, 1);
    expect(s.lines[2][0].text, 'X');
  });
  test(
    'malformed UTF-8 and incomplete tails cannot turn bytes into escapes',
    () {
      final s = TerminalScreen(columns: 20, rows: 2);
      s.add([0xe0, 0x80, 0x80, 0xf4, 0x90, 0x80, 0x80, 0xc2, 65, 0xf0]);
      s.finish();
      expect(s.lines[0].take(5).map((c) => c.text).join(), '���A�');
    },
  );
  test(
    'wide glyph overwrite, insert/delete, erase and resize keep cell invariants',
    () {
      final s = TerminalScreen(columns: 8, rows: 3);
      feed(s, 'A界B\x1b[1;3HX');
      expect(s.lines[0][1].text, ' ');
      expect(s.lines[0][2].text, 'X');
      feed(s, '\x1b[2;1H界界AB\x1b[2;2H\x1b[P\x1b[2@');
      s.resize(5, 2);
      for (final line in s.lines) {
        expect(line.length, 5);
        for (var x = 0; x < 5; x++) {
          if (line[x].width == 0) {
            expect(x, greaterThan(0));
            expect(line[x - 1].width, 2);
          }
          if (line[x].width == 2) {
            expect(x, lessThan(4));
            expect(line[x + 1].width, 0);
          }
        }
      }
      feed(s, '\x1b[2J');
      expect(s.lines.expand((l) => l).every((c) => c.text == ' '), true);
    },
  );
  test('scroll region, origin, line insertion and reverse index', () {
    final s = TerminalScreen(columns: 5, rows: 4);
    feed(s, '11111\r\n22222\r\n33333\r\n44444\x1b[2;3r\x1b[?6h\x1b[2;1H\n');
    expect(s.lineText(s.lines[0]), '11111');
    expect(s.lineText(s.lines[3]), '44444');
    expect(s.lineText(s.lines[1]), '33333');
    expect(s.historyLength, 0);
    feed(s, '\x1b[1;1H\x1bM');
    expect(s.lineText(s.lines[1]), '     ');
  });
  test('alternate screen preserves primary cursor, content and history', () {
    final s = TerminalScreen(columns: 8, rows: 3);
    feed(s, 'main\x1b[?1049h\x1b[2Jalt\n\n\n\n');
    expect(s.alternate, true);
    expect(s.historyLength, 0);
    s.resize(10, 4);
    feed(s, '\x1b[?1049l');
    expect(s.lines[0].take(4).map((c) => c.text).join(), 'main');
    expect(s.cursorX, 4);
    expect(s.cursorY, 0);
  });
  test('ANSI indexed/true colors, attributes and resets', () {
    final s = TerminalScreen(columns: 10, rows: 2);
    feed(s, '\x1b[1;4;31;44mA\x1b[38;5;196;48;2;1;2;3mB\x1b[0mC');
    expect(s.lines[0][0].style.bold, true);
    expect(s.lines[0][0].style.underline, true);
    expect(s.lines[0][1].style.foreground, 0xffff0000);
    expect(s.lines[0][1].style.background, 0xff010203);
    expect(s.lines[0][2].style.foreground, null);
    expect(s.lines[0][2].style.bold, false);
  });
  test(
    'VT100 graphics and device/cursor reports; OSC/DCS are never executed',
    () {
      final replies = <String>[];
      final s = TerminalScreen(
        columns: 12,
        rows: 3,
        onReply: (b) => replies.add(utf8.decode(b)),
      );
      feed(
        s,
        '\x1b(0lqk\x1b(B\x1b[6n\x1b[c\x1b]52;c;evil\x07\x1bPdiscard\x1b\\Z',
      );
      expect(s.lines[0].take(4).map((c) => c.text).join(), '┌─┐Z');
      expect(replies, ['\x1b[1;4R', '\x1b[?1;2c']);
    },
  );
  test('keyboard modes and bracketed paste sanitize embedded controls', () {
    final s = TerminalScreen(columns: 10, rows: 2);
    feed(s, '\x1b[?1h\x1b[?25l\x1b[?2004h');
    expect(s.applicationCursor, true);
    expect(s.cursorVisible, false);
    expect(s.paste('a\r\nb\x1b[201~\x03'), '\x1b[200~a\nb[201~\x1b[201~');
    feed(s, '\x1b[?2004l');
    expect(s.paste('a\nb'), 'a\rb');
  });
  test(
    'scrollback and escape parsing remain bounded under adversarial streams',
    () {
      final s = TerminalScreen(columns: 300, rows: 2);
      for (var i = 0; i < 2100; i++) {
        feed(s, 'x\r\n');
      }
      expect(
        s.history.fold<int>(0, (n, l) => n + l.length),
        lessThanOrEqualTo(TerminalScreen.maxHistoryCells),
      );
      feed(s, '\x1b[${'1' * 10000}mZ\x1b]${'x' * 100000}\x1b\\');
      final random = Random(4254);
      for (var i = 0; i < 100; i++) {
        s.add(List.generate(100, (_) => random.nextInt(256)));
        s.resize(2 + random.nextInt(40), 2 + random.nextInt(12));
      }
      expect(s.cursorX, inInclusiveRange(0, s.columns - 1));
      expect(s.cursorY, inInclusiveRange(0, s.rows - 1));
      expect(s.lines.length, s.rows);
    },
  );
}
