import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../app/ide_session.dart';
import '../../languages/language_registry.dart';
import '../../languages/document_syntax.dart';
import '../buffer/text_buffer.dart';
import '../document/editor_controller.dart';
import '../viewport/editor_viewport.dart';
import '../input/keyboard_mapping.dart';
import '../rendering/code_painter.dart';
import '../rendering/expanded_line.dart';

/// Custom text surface; TextInputClient integrates platform IME without TextField.
class CodeEditor extends StatefulWidget {
  const CodeEditor({
    super.key,
    required this.controller,
    required this.session,
    this.language,
  });
  final EditorController controller;
  final IdeSession session;
  final LanguageDefinition? language;
  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> implements TextInputClient {
  final _syntax = DocumentSyntax();
  final _focus = FocusNode(debugLabel: 'Code editor');
  final _scroll = ScrollController();
  final _horizontal = ScrollController();
  StreamSubscription<void>? _subscription;
  TextInputConnection? _connection;
  TextEditingValue _ime = TextEditingValue.empty;
  bool _receiving = false;
  double _height = 400;
  int? _dragAnchor;
  double get _fontSize => widget.session.settings.fontSize;
  double get _lineHeight => _fontSize * 1.6;
  EditorController get _editor => widget.controller;
  TextStyle get _style => TextStyle(
    fontFamily: widget.session.settings.get('fontFamily') as String,
    fontSize: _fontSize,
    height: 1.6,
    color: Color(widget.session.theme.color('foreground')),
  );
  @override
  void initState() {
    super.initState();
    _subscription = _editor.changes.listen((_) => _onChange());
    _focus.addListener(_focusChanged);
    _scroll.addListener(_repaint);
    _horizontal.addListener(_repaint);
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(CodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != _editor) {
      _subscription?.cancel();
      _subscription = _editor.changes.listen((_) => _onChange());
      _connection?.close();
      _connection = null;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      if (_focus.hasFocus) _attach();
    }
    if (_editor.readOnly) {
      _connection?.close();
      _connection = null;
    }
  }

  void _focusChanged() {
    if (_focus.hasFocus) {
      _attach();
    } else {
      _connection?.close();
      _connection = null;
    }
    _repaint();
  }

  void _attach() {
    if (_editor.readOnly) return;
    _connection ??= TextInput.attach(
      this,
      const TextInputConfiguration(
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
      ),
    );
    _syncIme();
    _connection!.show();
  }

  void _syncIme() {
    if (_receiving) return;
    _ime = TextEditingValue(
      text: _editor.text,
      selection: TextSelection(
        baseOffset: _editor.selection.anchor,
        extentOffset: _editor.selection.extent,
      ),
    );
    _connection?.setEditingState(_ime);
  }

  void _onChange() {
    _syncIme();
    _ensureVisible();
    _repaint();
  }

  void _ensureVisible() {
    if (!_scroll.hasClients) return;
    final point = _editor.buffer.positionAt(_editor.selection.extent);
    final y = point.line * _lineHeight;
    final offset = _scroll.offset;
    if (y < offset) {
      _scroll.jumpTo(y.clamp(0, _scroll.position.maxScrollExtent));
    } else if (y + _lineHeight > offset + _height) {
      _scroll.jumpTo(
        (y + _lineHeight - _height).clamp(0, _scroll.position.maxScrollExtent),
      );
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final command = widget.session.keys.resolve(keyChord(event));
    if (command != null) {
      unawaited(widget.session.run(command));
      return KeyEventResult.handled;
    }
    // Printable text is delivered only by IME (avoids duplicate text events).
    return KeyEventResult.ignored;
  }

  int _offsetAt(Offset point) {
    final line =
        ((point.dy + (_scroll.hasClients ? _scroll.offset : 0)) / _lineHeight)
            .floor()
            .clamp(0, _editor.buffer.lineCount - 1);
    final raw = _editor.buffer.getLine(line);
    final expanded = ExpandedLine(raw, _editor.tabSize);
    final painter = TextPainter(
      text: TextSpan(text: expanded.text, style: _style),
      textDirection: TextDirection.ltr,
    )..layout();
    final display = painter
        .getPositionForOffset(
          Offset(
            math.max(
              0,
              point.dx - 64 + (_horizontal.hasClients ? _horizontal.offset : 0),
            ),
            0,
          ),
        )
        .offset;
    painter.dispose();
    return _editor.buffer.offsetAt(
      TextPoint(line, expanded.rawOffset(display)),
    );
  }

  void _select(int start, int end) =>
      unawaited(widget.session.run('editor.select', [start, end]));
  void _tap(Offset position) {
    _focus.requestFocus();
    _attach();
    final offset = _offsetAt(position);
    _select(
      HardwareKeyboard.instance.isShiftPressed
          ? _editor.selection.anchor
          : offset,
      offset,
    );
  }

  void _word(Offset point) {
    _focus.requestFocus();
    _attach();
    final offset = _offsetAt(point);
    final text = _editor.text;
    var start = offset, end = offset;
    final word = RegExp(r'[\w\u0080-\uFFFF]');
    while (start > 0 && word.hasMatch(text[start - 1])) {
      start--;
    }
    while (end < text.length && word.hasMatch(text[end])) {
      end++;
    }
    _select(start, end);
    _dragAnchor = start;
  }

  Future<void> _context(Offset global) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        global & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        for (final entry in {
          'editor.copy': 'Copy',
          'editor.cut': 'Cut',
          'editor.paste': 'Paste',
          'editor.selectAll': 'Select all',
        }.entries)
          PopupMenuItem(value: entry.key, child: Text(entry.value)),
      ],
    );
    if (action != null) await widget.session.run(action);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _height = constraints.maxHeight;
        final totalHeight = math.max(
          _height,
          _editor.buffer.lineCount * _lineHeight + 32,
        );
        // Width is measured from visible lines only, with a useful horizontal runway.
        final viewport = EditorViewport(
          scrollOffset: _scroll.hasClients ? _scroll.offset : 0,
          height: _height,
          lineHeight: _lineHeight,
        );
        var width = constraints.maxWidth;
        for (
          var i = viewport.firstLine(_editor.buffer.lineCount);
          i < viewport.endLine(_editor.buffer.lineCount);
          i++
        ) {
          width = math.max(
            width,
            ExpandedLine(
                      _editor.buffer.getLine(i),
                      _editor.tabSize,
                    ).text.length *
                    _fontSize +
                100,
          );
        }
        return Semantics(
          label: 'Code editor',
          textField: true,
          readOnly: _editor.readOnly,
          child: Focus(
            focusNode: _focus,
            onKeyEvent: _key,
            child: MouseRegion(
              cursor: SystemMouseCursors.text,
              child: Listener(
                onPointerDown: (e) {
                  if (e.kind == PointerDeviceKind.mouse &&
                      e.buttons == kPrimaryMouseButton) {
                    _focus.requestFocus();
                    _dragAnchor = _offsetAt(e.localPosition);
                    _select(
                      HardwareKeyboard.instance.isShiftPressed
                          ? _editor.selection.anchor
                          : _dragAnchor!,
                      _dragAnchor!,
                    );
                  }
                },
                onPointerMove: (e) {
                  if (e.kind == PointerDeviceKind.mouse &&
                      e.buttons == kPrimaryMouseButton &&
                      _dragAnchor != null) {
                    _select(_dragAnchor!, _offsetAt(e.localPosition));
                  }
                },
                onPointerUp: (_) {
                  _dragAnchor = null;
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (e) => _tap(e.localPosition),
                  onDoubleTapDown: (e) => _word(e.localPosition),
                  onSecondaryTapUp: (e) => _context(e.globalPosition),
                  onLongPressStart: (e) => _word(e.localPosition),
                  onLongPressMoveUpdate: (e) => _select(
                    _dragAnchor ?? _editor.selection.anchor,
                    _offsetAt(e.localPosition),
                  ),
                  onLongPressEnd: (_) {
                    _dragAnchor = null;
                  },
                  child: Stack(
                    children: [
                      Scrollbar(
                        controller: _horizontal,
                        thumbVisibility: true,
                        notificationPredicate: (n) =>
                            n.metrics.axis == Axis.horizontal,
                        child: Scrollbar(
                          controller: _scroll,
                          thumbVisibility: true,
                          notificationPredicate: (n) =>
                              n.metrics.axis == Axis.vertical,
                          child: SingleChildScrollView(
                            controller: _scroll,
                            child: SingleChildScrollView(
                              controller: _horizontal,
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: width,
                                height: totalHeight,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: CodePainter(
                                editor: _editor,
                                syntax: _syntax,
                                language: widget.language,
                                theme: widget.session.theme,
                                style: _style,
                                scrollY: _scroll.hasClients
                                    ? _scroll.offset
                                    : 0,
                                scrollX: _horizontal.hasClients
                                    ? _horizontal.offset
                                    : 0,
                                lineHeight: _lineHeight,
                                focused: _focus.hasFocus,
                                composing: _ime.composing,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  TextEditingValue get currentTextEditingValue => _ime;
  @override
  AutofillScope? get currentAutofillScope => null;
  @override
  void updateEditingValue(TextEditingValue value) {
    if (_editor.readOnly) {
      _syncIme();
      return;
    }
    _receiving = true;
    try {
      final old = _editor.text;
      if (old != value.text) {
        var start = 0;
        while (start < old.length &&
            start < value.text.length &&
            old.codeUnitAt(start) == value.text.codeUnitAt(start)) {
          start++;
        }
        var a = old.length, b = value.text.length;
        while (a > start &&
            b > start &&
            old.codeUnitAt(a - 1) == value.text.codeUnitAt(b - 1)) {
          a--;
          b--;
        }
        // The IME edit enters the same command path as hardware/paste input.
        widget.session.commands.execute('editor.select', [start, a]);
        widget.session.commands.execute(
          'editor.insert',
          value.text.substring(start, b),
        );
      }
      if (value.selection.isValid) {
        widget.session.commands.execute('editor.select', [
          value.selection.baseOffset,
          value.selection.extentOffset,
        ]);
      }
      _ime = value;
    } finally {
      _receiving = false;
    }
    _repaint();
  }

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline) {
      unawaited(widget.session.run('editor.newline'));
    }
  }

  @override
  bool onFocusReceived() {
    _focus.requestFocus();
    return true;
  }

  @override
  void connectionClosed() {
    _connection = null;
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}
  @override
  void insertTextPlaceholder(Size size) {}
  @override
  void removeTextPlaceholder() {}
  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override
  void showToolbar() {}
  @override
  void performSelector(String selectorName) {}
  @override
  void insertContent(KeyboardInsertedContent content) {}
  @override
  void didChangeInputControl(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {}
  @override
  void dispose() {
    _subscription?.cancel();
    _connection?.close();
    _focus.dispose();
    _scroll.dispose();
    _horizontal.dispose();
    super.dispose();
  }
}
