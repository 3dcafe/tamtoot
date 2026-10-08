import 'dart:collection';
import 'dart:convert';
import 'dart:math';
part 'terminal_unicode.dart';
part 'terminal_parser.dart';

class TerminalStyle {
  const TerminalStyle({
    this.foreground,
    this.background,
    this.bold = false,
    this.underline = false,
    this.inverse = false,
    this.italic = false,
  });
  final int? foreground, background;
  final bool bold, underline, inverse, italic;
  TerminalStyle copy({
    int? foreground,
    int? background,
    bool? bold,
    bool? underline,
    bool? inverse,
    bool? italic,
    bool defaultForeground = false,
    bool defaultBackground = false,
  }) => TerminalStyle(
    foreground: defaultForeground ? null : foreground ?? this.foreground,
    background: defaultBackground ? null : background ?? this.background,
    bold: bold ?? this.bold,
    underline: underline ?? this.underline,
    inverse: inverse ?? this.inverse,
    italic: italic ?? this.italic,
  );
}

class TerminalCell {
  const TerminalCell(this.text, this.width, this.style);
  final String text;
  // 0 denotes the continuation of a wide glyph.
  final int width;
  final TerminalStyle style;
}

class TerminalScreen {
  TerminalScreen({int columns = 80, int rows = 24, this.onReply, this.onBell}) {
    _validate(columns, rows);
    this.columns = columns;
    this.rows = rows;
    _primary = _blankScreen();
    _screen = _primary;
    _bottom = rows - 1;
    _tabs = {for (var i = 8; i < columns; i += 8) i};
    _parser = _TerminalParser(this);
  }
  late int columns, rows;
  late List<List<TerminalCell>> _primary, _screen;
  List<List<TerminalCell>>? _alternate;
  final _history = ListQueue<List<TerminalCell>>();
  static const maxHistoryCells = 200000;
  int _historyCells = 0;
  int cursorX = 0, cursorY = 0, _top = 0, _bottom = 0;
  bool alternate = false,
      cursorVisible = true,
      applicationCursor = false,
      applicationKeypad = false,
      bracketedPaste = false,
      autoWrap = true,
      origin = false,
      insert = false,
      _wrap = false,
      _join = false;
  late Set<int> _tabs;
  TerminalStyle _style = const TerminalStyle();
  int _savedX = 0, _savedY = 0, _mainX = 0, _mainY = 0;
  bool _savedOrigin = false,
      _savedWrap = true,
      _savedG0 = false,
      _savedG1 = false,
      _savedShift = false,
      _mainOrigin = false;
  int _mainTop = 0, _mainBottom = 0;
  TerminalStyle _savedStyle = const TerminalStyle();
  bool _g0 = false, _g1 = false, _shift = false;
  late final _TerminalParser _parser;
  final void Function(List<int>)? onReply;
  final void Function()? onBell;
  List<List<TerminalCell>> get lines => _screen;
  Iterable<List<TerminalCell>> get history => _history;
  int get historyLength => _history.length;
  static void _validate(int columns, int rows) {
    if (columns < 2 || columns > 300 || rows < 2 || rows > 120) {
      throw ArgumentError('Terminal dimensions must be 2–300 by 2–120.');
    }
  }

  TerminalCell _blank() => TerminalCell(' ', 1, _style);
  List<TerminalCell> _line() => List.generate(columns, (_) => _blank());
  List<List<TerminalCell>> _blankScreen() =>
      List.generate(rows, (_) => _line());
  void add(List<int> bytes) => _parser.add(bytes);
  void finish() => _parser.finish();
  static bool _inRanges(int scalar, List<int> ranges) {
    var low = 0, high = ranges.length ~/ 2 - 1;
    while (low <= high) {
      final middle = (low + high) ~/ 2, index = middle * 2;
      if (scalar < ranges[index]) {
        high = middle - 1;
      } else if (scalar > ranges[index + 1]) {
        low = middle + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  static int scalarWidth(int scalar) => _inRanges(scalar, _zeroRanges)
      ? 0
      : _inRanges(scalar, _wideRanges)
      ? 2
      : 1;
  void _clearGlyph(List<TerminalCell> line, int x) {
    if (x < 0 || x >= columns) return;
    if (line[x].width == 0 && x > 0) line[x - 1] = _blank();
    if (line[x].width == 2 && x + 1 < columns) line[x + 1] = _blank();
    line[x] = _blank();
  }

  void _repair(List<TerminalCell> line) {
    for (var x = 0; x < columns; x++) {
      if (line[x].width == 2) {
        if (x + 1 == columns || line[x + 1].width != 0) line[x] = _blank();
      } else if (line[x].width == 0 && (x == 0 || line[x - 1].width != 2)) {
        line[x] = _blank();
      }
    }
  }

  int _previousX() {
    var x = _wrap ? cursorX : cursorX - 1;
    if (x >= 0 && _screen[cursorY][x].width == 0) x--;
    return x;
  }

  static int _hangul(int scalar) {
    if ((scalar >= 0x1100 && scalar <= 0x115f) ||
        (scalar >= 0xa960 && scalar <= 0xa97c)) {
      return 1;
    }
    if ((scalar >= 0x1160 && scalar <= 0x11a7) ||
        (scalar >= 0xd7b0 && scalar <= 0xd7c6)) {
      return 2;
    }
    if ((scalar >= 0x11a8 && scalar <= 0x11ff) ||
        (scalar >= 0xd7cb && scalar <= 0xd7fb)) {
      return 3;
    }
    if (scalar >= 0xac00 && scalar <= 0xd7a3) {
      return (scalar - 0xac00) % 28 == 0 ? 4 : 5;
    }
    return 0;
  }

  void _put(int scalar) {
    if ((_shift ? _g1 : _g0) && scalar >= 0x60 && scalar <= 0x7e) {
      const graphics = '◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·';
      scalar = graphics.runes.elementAt(scalar - 0x60);
    }
    final width = scalar >= 0x1f1e6 && scalar <= 0x1f1ff
        ? 2
        : scalarWidth(scalar);
    final prev = _previousX();
    final isModifier = scalar >= 0x1f3fb && scalar <= 0x1f3ff;
    final isRegional = scalar >= 0x1f1e6 && scalar <= 0x1f1ff;
    final previous = prev >= 0 ? _screen[cursorY][prev] : null;
    final pair =
        isRegional &&
        previous != null &&
        previous.text.runes.length == 1 &&
        previous.text.runes.first >= 0x1f1e6 &&
        previous.text.runes.first <= 0x1f1ff;
    final previousHangul = previous == null
            ? 0
            : _hangul(previous.text.runes.last),
        currentHangul = _hangul(scalar);
    final hangul =
        (previousHangul == 1 &&
            (currentHangul == 1 ||
                currentHangul == 2 ||
                currentHangul == 4 ||
                currentHangul == 5)) ||
        ((previousHangul == 2 || previousHangul == 4) &&
            (currentHangul == 2 || currentHangul == 3)) ||
        ((previousHangul == 3 || previousHangul == 5) && currentHangul == 3);
    final emojiJoin =
        _join && previous != null && previous.width == 2 && scalar >= 0x2300;
    if (width == 0 || isModifier || emojiJoin || pair || hangul) {
      if (previous != null && previous.text.length < 64) {
        final text = previous.text + String.fromCharCode(scalar);
        final wideVariation =
            scalar == 0xfe0f &&
            previous.width == 1 &&
            _inRanges(previous.text.runes.first, _emojiVariationRanges);
        if (wideVariation && prev + 1 < columns) {
          _clearGlyph(_screen[cursorY], prev + 1);
          _screen[cursorY][prev] = TerminalCell(text, 2, previous.style);
          _screen[cursorY][prev + 1] = TerminalCell('', 0, previous.style);
          if (prev + 2 >= columns) {
            cursorX = columns - 1;
            _wrap = autoWrap;
          } else {
            cursorX = prev + 2;
          }
        } else if (wideVariation && autoWrap) {
          _clearGlyph(_screen[cursorY], prev);
          cursorX = 0;
          _index();
          _screen[cursorY][0] = TerminalCell(text, 2, previous.style);
          _screen[cursorY][1] = TerminalCell('', 0, previous.style);
          cursorX = min(2, columns - 1);
          _wrap = columns == 2;
        } else {
          _screen[cursorY][prev] = TerminalCell(
            text,
            previous.width,
            previous.style,
          );
        }
      }
      _join = scalar == 0x200d;
      return;
    }
    _join = false;
    if (_wrap) {
      if (autoWrap) {
        cursorX = 0;
        _index();
      }
      _wrap = false;
    }
    if (width == 2 && cursorX == columns - 1) {
      if (!autoWrap) return;
      _clearGlyph(_screen[cursorY], cursorX);
      cursorX = 0;
      _index();
    }
    final line = _screen[cursorY];
    if (insert) _insertChars(width);
    _clearGlyph(line, cursorX);
    if (width == 2) _clearGlyph(line, cursorX + 1);
    line[cursorX] = TerminalCell(String.fromCharCode(scalar), width, _style);
    if (width == 2) line[cursorX + 1] = TerminalCell('', 0, _style);
    if (cursorX + width >= columns) {
      cursorX = columns - 1;
      _wrap = autoWrap;
    } else {
      cursorX += width;
    }
  }

  void _remember(List<TerminalCell> line) {
    _history.add(line);
    _historyCells += line.length;
    while (_historyCells > maxHistoryCells || _history.length > 2000) {
      _historyCells -= _history.removeFirst().length;
    }
  }

  void _scrollUp(int count) {
    count = count.clamp(1, _bottom - _top + 1);
    for (var i = 0; i < count; i++) {
      final line = _screen.removeAt(_top);
      if (!alternate && _top == 0 && _bottom == rows - 1) _remember(line);
      _screen.insert(_bottom, _line());
    }
  }

  void _scrollDown(int count) {
    count = count.clamp(1, _bottom - _top + 1);
    for (var i = 0; i < count; i++) {
      _screen.removeAt(_bottom);
      _screen.insert(_top, _line());
    }
  }

  void _index() {
    _wrap = false;
    _join = false;
    if (cursorY == _bottom) {
      _scrollUp(1);
    } else {
      cursorY = min(rows - 1, cursorY + 1);
    }
  }

  void _reverseIndex() {
    _wrap = false;
    _join = false;
    if (cursorY == _top) {
      _scrollDown(1);
    } else {
      cursorY = max(0, cursorY - 1);
    }
  }

  void _move(int x, int y) {
    cursorX = x.clamp(0, columns - 1);
    cursorY = y.clamp(origin ? _top : 0, origin ? _bottom : rows - 1);
    _wrap = false;
    _join = false;
  }

  void _eraseLine(int start, int end) {
    final line = _screen[cursorY];
    for (var x = start; x <= end; x++) {
      _clearGlyph(line, x);
    }
  }

  void _eraseDisplay(int mode) {
    if (mode == 3) {
      _history.clear();
      _historyCells = 0;
      return;
    }
    if (mode == 2) {
      for (var y = 0; y < rows; y++) {
        _screen[y] = _line();
      }
      return;
    }
    if (mode == 0) {
      _eraseLine(cursorX, columns - 1);
      for (var y = cursorY + 1; y < rows; y++) {
        _screen[y] = _line();
      }
    } else if (mode == 1) {
      _eraseLine(0, cursorX);
      for (var y = 0; y < cursorY; y++) {
        _screen[y] = _line();
      }
    }
  }

  void _insertChars(int count) {
    count = count.clamp(1, columns - cursorX);
    final line = _screen[cursorY];
    if (line[cursorX].width == 0) _clearGlyph(line, cursorX);
    line.insertAll(cursorX, List.generate(count, (_) => _blank()));
    line.removeRange(columns, line.length);
    _repair(line);
  }

  void _deleteChars(int count) {
    count = count.clamp(1, columns - cursorX);
    final line = _screen[cursorY];
    if (line[cursorX].width == 0) _clearGlyph(line, cursorX);
    line.removeRange(cursorX, cursorX + count);
    line.addAll(List.generate(count, (_) => _blank()));
    _repair(line);
  }

  void _save() {
    _savedX = cursorX;
    _savedY = cursorY;
    _savedStyle = _style;
    _savedOrigin = origin;
    _savedG0 = _g0;
    _savedG1 = _g1;
    _savedShift = _shift;
    _savedWrap = autoWrap;
  }

  void _restore() {
    _style = _savedStyle;
    _g0 = _savedG0;
    _g1 = _savedG1;
    _shift = _savedShift;
    origin = _savedOrigin;
    autoWrap = _savedWrap;
    _move(_savedX, _savedY);
  }

  void _setAlternate(bool enabled, {bool save = false, bool clear = false}) {
    if (enabled == alternate) return;
    if (enabled) {
      _mainX = cursorX;
      _mainY = cursorY;
      _mainTop = _top;
      _mainBottom = _bottom;
      _mainOrigin = origin;
      if (save) _save();
      if (clear || _alternate == null) _alternate = _blankScreen();
      _screen = _alternate!;
      _top = 0;
      _bottom = rows - 1;
      origin = false;
      _move(0, 0);
    } else {
      _screen = _primary;
      _top = _mainTop.clamp(0, rows - 2);
      _bottom = _mainBottom.clamp(_top + 1, rows - 1);
      origin = _mainOrigin;
      _move(_mainX, _mainY);
      if (save) _restore();
    }
    alternate = enabled;
  }

  void resize(int columns, int rows) {
    _validate(columns, rows);
    if (columns == this.columns && rows == this.rows) return;
    final oldRows = this.rows, oldColumns = this.columns;
    this.columns = columns;
    this.rows = rows;
    void reshape(List<List<TerminalCell>> screen, bool primary) {
      if (rows < oldRows && cursorY >= rows && primary && !alternate) {
        final shift = min(oldRows - rows, cursorY - rows + 1);
        for (var i = 0; i < shift; i++) {
          _remember(screen.removeAt(0));
        }
        cursorY -= shift;
      }
      while (screen.length > rows) {
        screen.removeLast();
      }
      while (screen.length < rows) {
        screen.add(_line());
      }
      for (final line in screen) {
        if (columns < oldColumns) {
          line.removeRange(columns, line.length);
        } else if (line.length < columns) {
          line.addAll(List.generate(columns - line.length, (_) => _blank()));
        }
        _repair(line);
      }
    }

    _mainTop = 0;
    _mainBottom = rows - 1;
    reshape(_primary, true);
    if (_alternate != null) reshape(_alternate!, false);
    _top = 0;
    _bottom = rows - 1;
    _move(cursorX, cursorY);
    _tabs.removeWhere((x) => x >= columns);
    if (columns > oldColumns) {
      for (var i = ((oldColumns + 7) ~/ 8) * 8; i < columns; i += 8) {
        _tabs.add(i);
      }
    }
  }

  void reset() {
    _style = const TerminalStyle();
    _history.clear();
    _historyCells = 0;
    alternate = false;
    _alternate = null;
    _primary = _blankScreen();
    _screen = _primary;
    _top = 0;
    _bottom = rows - 1;
    origin = false;
    autoWrap = true;
    insert = false;
    applicationCursor = false;
    applicationKeypad = false;
    bracketedPaste = false;
    cursorVisible = true;
    _g0 = false;
    _g1 = false;
    _shift = false;
    _join = false;
    _savedX = 0;
    _savedY = 0;
    _savedStyle = const TerminalStyle();
    _savedOrigin = false;
    _savedWrap = true;
    _savedG0 = false;
    _savedG1 = false;
    _savedShift = false;
    _tabs = {for (var i = 8; i < columns; i += 8) i};
    _move(0, 0);
  }

  String lineText(List<TerminalCell> line) =>
      line.where((c) => c.width != 0).map((c) => c.text).join();
  String get text => _screen.map(lineText).join('\n');
  void _reply(String text) => onReply?.call(utf8.encode(text));
  String paste(String value) {
    // Clipboard content is literal input; remove terminal control injection.
    value = value
        .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    return bracketedPaste
        ? '\x1b[200~$value\x1b[201~'
        : value.replaceAll('\n', '\r');
  }
}
