import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/ssh/ssh_client.dart';
import '../core/ssh/ssh_error.dart';
import '../core/ssh/transport/ssh_transport.dart';
import '../core/terminal/terminal_screen.dart';

class SshTerminalView extends StatefulWidget {
  const SshTerminalView({super.key, required this.client, required this.title});
  final SshClient client;
  final String title;
  @override
  State<SshTerminalView> createState() => _SshTerminalViewState();
}

class _SshTerminalViewState extends State<SshTerminalView>
    with WidgetsBindingObserver {
  late final TerminalScreen screen;
  SshShellChannel? _channel;
  final _cancel = SshCancellation();
  final _pendingReplies = <List<int>>[];
  final _input = TextEditingController(text: ' ');
  final _focus = FocusNode();
  Timer? _frame, _resizeTimer;
  int _columns = 80, _rows = 24, _scroll = 0, _replyCount = 0;
  bool _starting = false,
      _closed = false,
      _control = false,
      _resetting = false,
      _background = false;
  String _status = 'Opening terminal…';
  Point<int>? _selectionStart, _selectionEnd;
  static const _cellWidth = 8.5, _cellHeight = 18.0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    screen = TerminalScreen(
      onReply: (bytes) {
        if (++_replyCount <= 16) {
          if (_channel == null) {
            if (_pendingReplies.length < 16) {
              _pendingReplies.add(List<int>.from(bytes));
            }
          } else {
            _send(bytes);
          }
        }
      },
      onBell: () {},
    );
    _input.selection = const TextSelection.collapsed(offset: 1);
  }

  void _redraw() {
    _frame ??= Timer(const Duration(milliseconds: 16), () {
      _frame = null;
      _replyCount = 0;
      if (mounted) setState(() {});
    });
  }

  Future<void> _open() async {
    if (_starting || _closed) return;
    _starting = true;
    try {
      final channel = await widget.client.openShell(
        columns: _columns,
        rows: _rows,
        cancellation: _cancel,
        onOutput: (output) {
          if (!mounted || _closed) return;
          // Selection references mutable rows; clear on new server output.
          _selectionStart = null;
          _selectionEnd = null;
          screen.add(output.data);
          _redraw();
        },
      );
      if (!mounted || _closed) {
        await channel.cancel();
        return;
      }
      _channel = channel;
      for (final reply in _pendingReplies) {
        _send(reply);
      }
      _pendingReplies.clear();
      if (defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.iOS) {
        _focus.requestFocus();
      }
      if (screen.columns != _columns || screen.rows != _rows) {
        screen.resize(_columns, _rows);
      }
      await channel.resize(_columns, _rows);
      if (mounted) {
        setState(
          () => _status =
              'Connected · ${SshShellChannel.terminalType} · $_columns × $_rows',
        );
      }
      unawaited(
        channel.result.then(
          (result) {
            if (!mounted) return;
            screen.finish();
            setState(() {
              _closed = true;
              _status = result.exitStatus == null
                  ? 'Terminal closed'
                  : 'Shell exited: ${result.exitStatus}';
            });
          },
          onError: (Object e) {
            if (mounted) {
              setState(() {
                _closed = true;
                _status = _background
                    ? 'Session disconnected while app was in the background. Reconnect explicitly.'
                    : 'Terminal disconnected: ${e is SshException ? e.message : 'connection failed'}';
              });
            }
          },
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _closed = true;
          _status =
              'Terminal could not open: ${e is SshException ? e.message : 'connection failed'}';
        });
      }
    }
  }

  void _dimensions(double width, double height) {
    final columns = (width / _cellWidth).floor().clamp(2, 300),
        rows = (height / _cellHeight).floor().clamp(2, 120);
    if (!_starting) {
      _columns = columns;
      _rows = rows;
      screen.resize(columns, rows);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open();
      });
      return;
    }
    if (columns == _columns && rows == _rows) return;
    _columns = columns;
    _rows = rows;
    _selectionStart = null;
    _selectionEnd = null;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 100), () async {
      if (!mounted || _closed) return;
      setState(() => screen.resize(_columns, _rows));
      try {
        await _channel?.resize(_columns, _rows);
        if (mounted && !_closed) {
          setState(
            () => _status =
                'Connected · ${SshShellChannel.terminalType} · $_columns × $_rows',
          );
        }
      } catch (_) {
        if (mounted) setState(() => _status = 'Unable to resize terminal.');
      }
    });
  }

  void _send(List<int> bytes) {
    if (_channel == null || _closed || bytes.isEmpty) return;
    _scroll = 0;
    _selectionStart = null;
    _selectionEnd = null;
    Future<void> task;
    try {
      task = _channel!.writeStdin(bytes);
    } catch (e) {
      _inputError(e);
      return;
    }
    unawaited(task.catchError((Object e) => _inputError(e)));
    _redraw();
  }

  void _inputError(Object e) {
    if (mounted && !_closed) {
      setState(
        () => _status = e is SshException
            ? e.message
            : 'Unable to send terminal input.',
      );
    }
  }

  void _text(String text) {
    if (_resetting ||
        _input.value.composing.isValid && !_input.value.composing.isCollapsed) {
      return;
    }
    final value = text.startsWith(' ') ? text.substring(1) : text;
    if (text.isEmpty) {
      _send([127]);
    } else if (value.isNotEmpty) {
      if (_control && value.runes.length == 1) {
        final code = value.toUpperCase().codeUnitAt(0);
        if (code >= 64 && code <= 95) {
          _send([code & 31]);
        } else if (code == 32) {
          _send([0]);
        } else if (code == 63) {
          _send([127]);
        }
        setState(() => _control = false);
      } else {
        _send(
          utf8.encode(
            value.runes.length > 1
                ? screen.paste(value)
                : value == '\n'
                ? '\r'
                : value,
          ),
        );
      }
    }
    _resetting = true;
    _input.value = const TextEditingValue(
      text: ' ',
      selection: TextSelection.collapsed(offset: 1),
    );
    _resetting = false;
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey, keyboard = HardwareKeyboard.instance;
    if ((keyboard.isControlPressed || keyboard.isMetaPressed) &&
        keyboard.isShiftPressed) {
      if (key == LogicalKeyboardKey.keyC) {
        _copy();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyV) {
        _paste();
        return KeyEventResult.handled;
      }
    }
    if ((keyboard.isControlPressed || keyboard.isMetaPressed) &&
        key == LogicalKeyboardKey.keyV) {
      _paste();
      return KeyEventResult.handled;
    }
    if (keyboard.isMetaPressed && key == LogicalKeyboardKey.keyC) {
      _copy();
      return KeyEventResult.handled;
    }
    if (screen.applicationKeypad) {
      final keypad = {
        LogicalKeyboardKey.numpad0: 'p',
        LogicalKeyboardKey.numpad1: 'q',
        LogicalKeyboardKey.numpad2: 'r',
        LogicalKeyboardKey.numpad3: 's',
        LogicalKeyboardKey.numpad4: 't',
        LogicalKeyboardKey.numpad5: 'u',
        LogicalKeyboardKey.numpad6: 'v',
        LogicalKeyboardKey.numpad7: 'w',
        LogicalKeyboardKey.numpad8: 'x',
        LogicalKeyboardKey.numpad9: 'y',
        LogicalKeyboardKey.numpadDecimal: 'n',
        LogicalKeyboardKey.numpadAdd: 'k',
        LogicalKeyboardKey.numpadSubtract: 'm',
        LogicalKeyboardKey.numpadMultiply: 'j',
        LogicalKeyboardKey.numpadDivide: 'o',
        LogicalKeyboardKey.numpadEnter: 'M',
      }[key];
      if (keypad != null) {
        _send(utf8.encode('\x1bO$keypad'));
        return KeyEventResult.handled;
      }
    }
    String? text;
    final cursor = screen.applicationCursor ? '\x1bO' : '\x1b[';
    final modifiers =
        1 +
        (keyboard.isShiftPressed ? 1 : 0) +
        (keyboard.isAltPressed ? 2 : 0) +
        (keyboard.isControlPressed ? 4 : 0);
    final arrow = {
      LogicalKeyboardKey.arrowUp: 'A',
      LogicalKeyboardKey.arrowDown: 'B',
      LogicalKeyboardKey.arrowRight: 'C',
      LogicalKeyboardKey.arrowLeft: 'D',
      LogicalKeyboardKey.home: 'H',
      LogicalKeyboardKey.end: 'F',
    }[key];
    if (arrow != null) {
      text = modifiers == 1 ? '$cursor$arrow' : '\x1b[1;$modifiers$arrow';
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      text = '\r';
    } else if (key == LogicalKeyboardKey.backspace) {
      text = '\x7f';
    } else if (key == LogicalKeyboardKey.escape) {
      text = '\x1b';
    } else if (key == LogicalKeyboardKey.tab) {
      text = keyboard.isShiftPressed ? '\x1b[Z' : '\t';
    } else {
      final code = {
        LogicalKeyboardKey.insert: 2,
        LogicalKeyboardKey.delete: 3,
        LogicalKeyboardKey.pageUp: 5,
        LogicalKeyboardKey.pageDown: 6,
        LogicalKeyboardKey.f5: 15,
        LogicalKeyboardKey.f6: 17,
        LogicalKeyboardKey.f7: 18,
        LogicalKeyboardKey.f8: 19,
        LogicalKeyboardKey.f9: 20,
        LogicalKeyboardKey.f10: 21,
        LogicalKeyboardKey.f11: 23,
        LogicalKeyboardKey.f12: 24,
      }[key];
      if (code != null) {
        text = modifiers == 1 ? '\x1b[$code~' : '\x1b[$code;$modifiers~';
      }
      final f = {
        LogicalKeyboardKey.f1: 'P',
        LogicalKeyboardKey.f2: 'Q',
        LogicalKeyboardKey.f3: 'R',
        LogicalKeyboardKey.f4: 'S',
      }[key];
      if (f != null) text = modifiers == 1 ? '\x1bO$f' : '\x1b[1;$modifiers$f';
    }
    if (text == null && (keyboard.isControlPressed || _control)) {
      final label = key.keyLabel.toUpperCase();
      if (label.length == 1) {
        final code = label.codeUnitAt(0);
        if (code >= 64 && code <= 95) text = String.fromCharCode(code & 31);
        if (label == ' ') text = '\x00';
      }
    }
    if (text == null && keyboard.isAltPressed && event.character != null) {
      text = '\x1b${event.character}';
    }
    if (text != null) {
      _send(utf8.encode(text));
      if (_control) setState(() => _control = false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  List<List<TerminalCell>> get _allLines => [
    if (!screen.alternate) ...screen.history,
    ...screen.lines,
  ];
  int get _firstLine =>
      max(0, (screen.alternate ? 0 : screen.historyLength) - _scroll);
  Point<int> _point(Offset offset) => Point(
    (offset.dx / _cellWidth).floor().clamp(0, screen.columns - 1),
    _firstLine + (offset.dy / _cellHeight).floor().clamp(0, screen.rows - 1),
  );
  Future<void> _copy() async {
    final all = _allLines;
    final a = _selectionStart, b = _selectionEnd;
    String value;
    if (a == null || b == null) {
      value = screen.text;
    } else {
      bool before(Point<int> p, Point<int> q) =>
          p.y < q.y || p.y == q.y && p.x <= q.x;
      final start = before(a, b) ? a : b, end = before(a, b) ? b : a;
      final lines = <String>[];
      for (var y = start.y; y <= end.y && y < all.length; y++) {
        if (y < 0) continue;
        final cells = all[y],
            from = y == start.y ? start.x : 0,
            to = y == end.y ? end.x : cells.length - 1;
        final selected = <String>[];
        for (var x = from; x <= to && x < cells.length; x++) {
          if (cells[x].width != 0) {
            selected.add(cells[x].text);
          } else if (x == from && x > 0) {
            selected.add(cells[x - 1].text);
          }
        }
        lines.add(selected.join().replaceFirst(RegExp(r' +$'), ''));
      }
      value = lines.join('\n');
    }
    await Clipboard.setData(ClipboardData(text: value));
  }

  Future<void> _paste() async {
    final value = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || _closed || value?.text == null) return;
    if (utf8.encode(value!.text!).length > 65536) {
      setState(() => _status = 'Paste exceeds 64 KiB.');
      return;
    }
    _send(utf8.encode(screen.paste(value.text!)));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS) &&
        state == AppLifecycleState.paused &&
        !_closed) {
      _background = true;
      _cancel.cancel();
      unawaited(widget.client.close());
      if (mounted) {
        setState(() {
          _closed = true;
          _status =
              'Session disconnected while app was in the background. Reconnect explicitly.';
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _closed = true;
    _cancel.cancel();
    _frame?.cancel();
    _resizeTimer?.cancel();
    unawaited(_channel?.cancel());
    _pendingReplies.clear();
    _input.clear();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Widget _button(String label, String value) => TextButton(
    onPressed: _closed ? null : () => _send(utf8.encode(value)),
    child: Text(label),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      actions: [
        IconButton(
          tooltip: 'Copy selection or screen',
          onPressed: _copy,
          icon: const Icon(Icons.copy),
        ),
        IconButton(
          tooltip: 'Paste',
          onPressed: _closed ? null : _paste,
          icon: const Icon(Icons.paste),
        ),
        IconButton(
          tooltip: 'Disconnect SSH session',
          onPressed: _closed
              ? null
              : () async {
                  _cancel.cancel();
                  await widget.client.close();
                },
          icon: const Icon(Icons.link_off),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(_status, key: const Key('ssh-terminal-status')),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _dimensions(constraints.maxWidth, constraints.maxHeight);
              return Focus(
                onKeyEvent: _key,
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      setState(
                        () => _scroll =
                            (_scroll +
                                    (event.scrollDelta.dy / _cellHeight)
                                        .round())
                                .clamp(
                                  0,
                                  screen.alternate ? 0 : screen.historyLength,
                                ),
                      );
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _focus.requestFocus(),
                    onPanDown: (details) => setState(() {
                      _selectionStart = _point(details.localPosition);
                      _selectionEnd = _selectionStart;
                    }),
                    onPanStart: (details) => setState(() {
                      _selectionEnd = _point(details.localPosition);
                    }),
                    onPanUpdate: (details) => setState(
                      () => _selectionEnd = _point(details.localPosition),
                    ),
                    onLongPressStart: (details) => setState(() {
                      _selectionStart = _point(details.localPosition);
                      _selectionEnd = _selectionStart;
                    }),
                    onLongPressMoveUpdate: (details) => setState(
                      () => _selectionEnd = _point(details.localPosition),
                    ),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            key: const Key('ssh-terminal-screen'),
                            painter: _TerminalPainter(
                              screen,
                              _allLines,
                              _firstLine,
                              _selectionStart,
                              _selectionEnd,
                              _scroll == 0,
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          bottom: 0,
                          width: 1,
                          height: 1,
                          child: Opacity(
                            opacity: 0,
                            child: TextField(
                              key: const Key('ssh-terminal-input'),
                              controller: _input,
                              focusNode: _focus,
                              onChanged: _text,
                              enabled: !_closed,
                              autocorrect: false,
                              enableSuggestions: false,
                              enableIMEPersonalizedLearning: false,
                              smartDashesType: SmartDashesType.disabled,
                              smartQuotesType: SmartQuotesType.disabled,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              maxLines: null,
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (_scroll > 0)
          TextButton(
            onPressed: () => setState(() => _scroll = 0),
            child: const Text('Return to live screen'),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              TextButton(
                onPressed: _closed
                    ? null
                    : () => setState(() => _control = !_control),
                child: Text(_control ? 'Ctrl ●' : 'Ctrl'),
              ),
              _button('Esc', '\x1b'),
              _button('Tab', '\t'),
              _button('↑', screen.applicationCursor ? '\x1bOA' : '\x1b[A'),
              _button('↓', screen.applicationCursor ? '\x1bOB' : '\x1b[B'),
              _button('←', screen.applicationCursor ? '\x1bOD' : '\x1b[D'),
              _button('→', screen.applicationCursor ? '\x1bOC' : '\x1b[C'),
              _button('Enter', '\r'),
              TextButton(
                onPressed: screen.historyLength == 0
                    ? null
                    : () => setState(
                        () => _scroll = min(
                          screen.historyLength,
                          _scroll + screen.rows,
                        ),
                      ),
                child: const Text('History ↑'),
              ),
              TextButton(
                onPressed: _scroll == 0
                    ? null
                    : () => setState(
                        () => _scroll = max(0, _scroll - screen.rows),
                      ),
                child: const Text('History ↓'),
              ),
              IconButton(
                tooltip: 'Keyboard',
                onPressed: () {
                  if (_focus.hasFocus) {
                    _focus.unfocus();
                  } else {
                    _focus.requestFocus();
                  }
                },
                icon: const Icon(Icons.keyboard),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _TerminalPainter extends CustomPainter {
  _TerminalPainter(
    this.screen,
    this.lines,
    this.first,
    this.start,
    this.end,
    this.live,
  );
  final TerminalScreen screen;
  final List<List<TerminalCell>> lines;
  final int first;
  final Point<int>? start, end;
  final bool live;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff151515),
    );
    final a = start, b = end;
    int index(Point<int> p) => p.y * screen.columns + p.x;
    final low = a == null || b == null ? -1 : min(index(a), index(b)),
        high = a == null || b == null ? -1 : max(index(a), index(b));
    for (var row = 0; row < screen.rows && first + row < lines.length; row++) {
      final line = lines[first + row];
      for (var col = 0; col < line.length && col < screen.columns; col++) {
        final cell = line[col], style = cell.style;
        var foreground = Color(style.foreground ?? 0xffe5e5e5),
            background = Color(style.background ?? 0xff151515);
        if (style.inverse) {
          final temp = foreground;
          foreground = background;
          background = temp;
        }
        final selected =
            (first + row) * screen.columns + col >= low &&
            (first + row) * screen.columns + col <= high;
        if (selected) background = const Color(0xff315f8a);
        final rect = Rect.fromLTWH(
          col * _SshTerminalViewState._cellWidth,
          row * _SshTerminalViewState._cellHeight,
          _SshTerminalViewState._cellWidth,
          _SshTerminalViewState._cellHeight,
        );
        canvas.drawRect(rect, Paint()..color = background);
      }
      for (var col = 0; col < line.length && col < screen.columns; col++) {
        final cell = line[col];
        if (cell.width == 0 || cell.text == ' ') continue;
        final style = cell.style,
            foreground = Color(
              style.inverse
                  ? (style.background ?? 0xff151515)
                  : (style.foreground ?? 0xffe5e5e5),
            );
        final painter = TextPainter(
          text: TextSpan(
            text: cell.text,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              color: foreground,
              fontWeight: style.bold ? FontWeight.bold : FontWeight.normal,
              fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
              decoration: style.underline
                  ? TextDecoration.underline
                  : TextDecoration.none,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final rect = Rect.fromLTWH(
          col * _SshTerminalViewState._cellWidth,
          row * _SshTerminalViewState._cellHeight,
          cell.width * _SshTerminalViewState._cellWidth,
          _SshTerminalViewState._cellHeight,
        );
        canvas.save();
        canvas.clipRect(rect);
        painter.paint(canvas, rect.topLeft);
        canvas.restore();
        painter.dispose();
      }
    }
    if (live && screen.cursorVisible) {
      canvas.drawRect(
        Rect.fromLTWH(
          screen.cursorX * _SshTerminalViewState._cellWidth,
          screen.cursorY * _SshTerminalViewState._cellHeight,
          _SshTerminalViewState._cellWidth,
          _SshTerminalViewState._cellHeight,
        ),
        Paint()
          ..color = const Color(0xffe5e5e5)
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TerminalPainter oldDelegate) => true;
}
