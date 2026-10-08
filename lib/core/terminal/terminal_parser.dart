part of 'terminal_screen.dart';

class _TerminalParser {
  _TerminalParser(this.screen);
  final TerminalScreen screen;
  int _state = 0, _utf = 0, _scalar = 0, _minimum = 0, _charset = 0;
  String _sequence = '';
  bool _stringEscape = false;
  void add(List<int> bytes) {
    for (final byte in bytes) {
      _byte(byte & 255);
    }
  }

  void finish() {
    if (_utf != 0) {
      _utf = 0;
      _character(0xfffd);
    }
  }

  void _byte(int byte) {
    if (_utf != 0) {
      if (byte >= 0x80 && byte <= 0xbf) {
        _scalar = (_scalar << 6) | (byte & 63);
        if (--_utf == 0) {
          _character(
            _scalar < _minimum ||
                    _scalar > 0x10ffff ||
                    (_scalar >= 0xd800 && _scalar <= 0xdfff)
                ? 0xfffd
                : _scalar,
          );
        }
        return;
      }
      _utf = 0;
      _character(0xfffd);
    }
    if (byte < 128) {
      _character(byte);
    } else if (byte >= 0xc2 && byte <= 0xdf) {
      _utf = 1;
      _scalar = byte & 31;
      _minimum = 128;
    } else if (byte >= 0xe0 && byte <= 0xef) {
      _utf = 2;
      _scalar = byte & 15;
      _minimum = 2048;
    } else if (byte >= 0xf0 && byte <= 0xf4) {
      _utf = 3;
      _scalar = byte & 7;
      _minimum = 65536;
    } else {
      _character(0xfffd);
    }
  }

  void _character(int scalar) {
    if (_state == 4) {
      if ((_stringEscape && scalar == 0x5c) || scalar == 7) {
        _state = 0;
      }
      _stringEscape = scalar == 27;
      return;
    }
    if (scalar == 0x18 || scalar == 0x1a) {
      _state = 0;
      _sequence = '';
      return;
    }
    if (scalar == 27) {
      _state = 1;
      _sequence = '';
      return;
    }
    if (scalar < 32 || scalar == 127) {
      switch (scalar) {
        case 7:
          screen.onBell?.call();
        case 8:
          screen._move(screen.cursorX - 1, screen.cursorY);
        case 9:
          final tabs = screen._tabs.where((x) => x > screen.cursorX).toList()
            ..sort();
          screen._move(
            tabs.isEmpty ? screen.columns - 1 : tabs.first,
            screen.cursorY,
          );
        case 10:
        case 11:
        case 12:
          screen._index();
        case 13:
          screen._move(0, screen.cursorY);
        case 14:
          screen._shift = true;
        case 15:
          screen._shift = false;
      }
      return;
    }
    if (_state == 1) {
      _state = 0;
      switch (scalar) {
        case 0x5b:
          _state = 2;
        case 0x5d:
        case 0x50:
        case 0x5e:
        case 0x5f:
          _state = 4;
          _stringEscape = false;
        case 0x28:
        case 0x29:
          _state = 3;
          _charset = scalar;
        case 0x37:
          screen._save();
        case 0x38:
          screen._restore();
        case 0x44:
          screen._index();
        case 0x45:
          screen._move(0, screen.cursorY);
          screen._index();
        case 0x4d:
          screen._reverseIndex();
        case 0x48:
          screen._tabs.add(screen.cursorX);
        case 0x3d:
          screen.applicationKeypad = true;
        case 0x3e:
          screen.applicationKeypad = false;
        case 0x63:
          screen.reset();
      }
      return;
    }
    if (_state == 3) {
      if (_charset == 0x28) {
        screen._g0 = scalar == 0x30;
      } else {
        screen._g1 = scalar == 0x30;
      }
      _state = 0;
      return;
    }
    if (_state == 2) {
      if (scalar >= 0x40 && scalar <= 0x7e) {
        final sequence = _sequence;
        _sequence = '';
        _state = 0;
        _csi(sequence, String.fromCharCode(scalar));
      } else if (scalar >= 0x20 && scalar <= 0x3f && _sequence.length < 128) {
        _sequence += String.fromCharCode(scalar);
      } else {
        _state = 5;
      }
      return;
    }
    if (_state == 5) {
      if (scalar >= 0x40 && scalar <= 0x7e) _state = 0;
      return;
    }
    screen._put(scalar);
  }

  void _csi(String sequence, String finalByte) {
    final private = sequence.startsWith('?');
    if (private) sequence = sequence.substring(1);
    if (sequence.contains(RegExp(r'[^0-9;:]'))) return;
    if (sequence.contains(':')) {
      if (finalByte != 'm') return;
      sequence = sequence.replaceAllMapped(
        RegExp(r'(38|48):2:(?:0)?:([0-9]+):([0-9]+):([0-9]+)'),
        (match) => '${match[1]};2;${match[2]};${match[3]};${match[4]}',
      );
      sequence = sequence.replaceAll(':', ';');
    }
    final parts = sequence.split(';');
    if (parts.length > 32) return;
    final p = parts.map((v) => (int.tryParse(v) ?? 0).clamp(0, 65535)).toList();
    int n([int index = 0, int fallback = 1]) =>
        index >= p.length || p[index] == 0 ? fallback : p[index];
    final s = screen, x = screen.cursorX, y = screen.cursorY;
    if (private && (finalByte == 'h' || finalByte == 'l')) {
      final enable = finalByte == 'h';
      for (final mode in p) {
        switch (mode) {
          case 1:
            s.applicationCursor = enable;
          case 6:
            s.origin = enable;
            s._move(0, enable ? s._top : 0);
          case 7:
            s.autoWrap = enable;
            s._wrap = false;
          case 25:
            s.cursorVisible = enable;
          case 47:
          case 1047:
            s._setAlternate(enable, clear: mode == 1047);
          case 1048:
            if (enable) {
              s._save();
            } else {
              s._restore();
            }
          case 1049:
            s._setAlternate(enable, save: true, clear: true);
          case 2004:
            s.bracketedPaste = enable;
        }
      }
      return;
    }
    if (private) return;
    switch (finalByte) {
      case 'A':
        s._move(x, y - n());
      case 'B':
      case 'e':
        s._move(x, y + n());
      case 'C':
      case 'a':
        s._move(x + n(), y);
      case 'D':
        s._move(x - n(), y);
      case 'E':
        s._move(0, y + n());
      case 'F':
        s._move(0, y - n());
      case 'G':
      case '`':
        s._move(n() - 1, y);
      case 'd':
        s._move(x, n() - 1 + (s.origin ? s._top : 0));
      case 'H':
      case 'f':
        s._move(n(1) - 1, n() - 1 + (s.origin ? s._top : 0));
      case 'J':
        s._eraseDisplay(p[0]);
      case 'K':
        if (p[0] == 0) {
          s._eraseLine(x, s.columns - 1);
        } else if (p[0] == 1) {
          s._eraseLine(0, x);
        } else if (p[0] == 2) {
          s._eraseLine(0, s.columns - 1);
        }
      case '@':
        s._insertChars(n());
      case 'P':
        s._deleteChars(n());
      case 'X':
        s._eraseLine(x, min(s.columns - 1, x + n() - 1));
      case 'L':
        if (y >= s._top && y <= s._bottom) {
          final old = s._top;
          s._top = y;
          s._scrollDown(n());
          s._top = old;
        }
      case 'M':
        if (y >= s._top && y <= s._bottom) {
          final old = s._top;
          s._top = y;
          s._scrollUp(n());
          s._top = old;
        }
      case 'S':
        s._scrollUp(n());
      case 'T':
        s._scrollDown(n());
      case 'r':
        final top = n() - 1, bottom = n(1, s.rows) - 1;
        if (top >= 0 && bottom < s.rows && top < bottom) {
          s._top = top;
          s._bottom = bottom;
          s._move(0, s.origin ? top : 0);
        }
      case 's':
        s._save();
      case 'u':
        s._restore();
      case 'g':
        if (p[0] == 0) {
          s._tabs.remove(x);
        } else if (p[0] == 3) {
          s._tabs.clear();
        }
      case 'h':
        if (p.contains(4)) s.insert = true;
      case 'l':
        if (p.contains(4)) s.insert = false;
      case 'm':
        _sgr(p);
      case 'n':
        if (p[0] == 5) s._reply('\x1b[0n');
        if (p[0] == 6) {
          s._reply(
            '\x1b[${s.cursorY + 1 - (s.origin ? s._top : 0)};${s.cursorX + 1}R',
          );
        }
      case 'c':
        if (p[0] == 0) s._reply('\x1b[?1;2c');
    }
  }

  static const palette = [
    0xff151515,
    0xffcd3131,
    0xff0dbc79,
    0xffe5e510,
    0xff2472c8,
    0xffbc3fbc,
    0xff11a8cd,
    0xffe5e5e5,
    0xff666666,
    0xfff14c4c,
    0xff23d18b,
    0xfff5f543,
    0xff3b8eea,
    0xffd670d6,
    0xff29b8db,
    0xffffffff,
  ];
  int _color(int index) {
    index = index.clamp(0, 255);
    if (index < 16) return palette[index];
    if (index >= 232) {
      final gray = 8 + (index - 232) * 10;
      return 0xff000000 | (gray << 16) | (gray << 8) | gray;
    }
    index -= 16;
    int component(int n) => n == 0 ? 0 : 55 + 40 * n;
    return 0xff000000 |
        (component(index ~/ 36) << 16) |
        (component((index ~/ 6) % 6) << 8) |
        component(index % 6);
  }

  void _sgr(List<int> p) {
    var style = screen._style;
    for (var i = 0; i < p.length; i++) {
      final v = p[i];
      if (v == 0) {
        style = const TerminalStyle();
      } else if (v == 1) {
        style = style.copy(bold: true);
      } else if (v == 3) {
        style = style.copy(italic: true);
      } else if (v == 4) {
        style = style.copy(underline: true);
      } else if (v == 7) {
        style = style.copy(inverse: true);
      } else if (v == 22) {
        style = style.copy(bold: false);
      } else if (v == 23) {
        style = style.copy(italic: false);
      } else if (v == 24) {
        style = style.copy(underline: false);
      } else if (v == 27) {
        style = style.copy(inverse: false);
      } else if (v == 39) {
        style = style.copy(defaultForeground: true);
      } else if (v == 49) {
        style = style.copy(defaultBackground: true);
      } else if (v >= 30 && v <= 37) {
        style = style.copy(foreground: palette[v - 30]);
      } else if (v >= 40 && v <= 47) {
        style = style.copy(background: palette[v - 40]);
      } else if (v >= 90 && v <= 97) {
        style = style.copy(foreground: palette[v - 90 + 8]);
      } else if (v >= 100 && v <= 107) {
        style = style.copy(background: palette[v - 100 + 8]);
      } else if (v == 38 || v == 48) {
        int? color;
        if (i + 2 < p.length && p[i + 1] == 5) {
          color = _color(p[i + 2]);
          i += 2;
        } else if (i + 4 < p.length && p[i + 1] == 2) {
          color =
              0xff000000 |
              (p[i + 2].clamp(0, 255) << 16) |
              (p[i + 3].clamp(0, 255) << 8) |
              p[i + 4].clamp(0, 255);
          i += 4;
        }
        if (color != null) {
          style = v == 38
              ? style.copy(foreground: color)
              : style.copy(background: color);
        }
      }
    }
    screen._style = style;
  }
}
