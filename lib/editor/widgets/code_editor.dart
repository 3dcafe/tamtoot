import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../app/ide_session.dart';
import '../../core/completion/project_completion.dart';
import '../../languages/language_registry.dart';
import '../../languages/document_syntax.dart';
import '../buffer/text_buffer.dart';
import '../document/editor_controller.dart';
import '../viewport/editor_viewport.dart';
import '../input/keyboard_mapping.dart';
import '../rendering/code_painter.dart';
import '../rendering/expanded_line.dart';
import 'hex_color_picker.dart';

bool _foldableDeclaration(String line) {
  final trimmed = line.trim();
  if (RegExp(
    r'\b(?:class|enum|interface|mixin|extension|struct|record|namespace)\b',
  ).hasMatch(trimmed)) {
    return true;
  }
  if ({'if', 'for', 'while', 'switch', 'catch', 'try', 'else', 'do'}.any(
    (keyword) =>
        trimmed.startsWith('$keyword ') || trimmed.startsWith('$keyword('),
  )) {
    return false;
  }
  return RegExp(
    r'[A-Za-z_$][\w$<>?,.\[\] ]*\([^;]*\)\s*(?:async\s*)?\{?$',
  ).hasMatch(trimmed);
}

@visibleForTesting
List<FoldingRegion> foldingRegionsForLines(List<String> lines) {
  final stack = <({int startLine, bool foldable})>[];
  final regions = <FoldingRegion>[];
  var previousContent = 0;
  for (var line = 0; line < lines.length; line++) {
    final raw = lines[line];
    final trimmed = raw.trim();
    var startLine = line;
    var declaration = raw;
    if (trimmed == '{' && line > 0) {
      startLine = previousContent;
      declaration = lines[previousContent];
    }
    for (final unit in raw.codeUnits) {
      if (unit == 0x7b) {
        stack.add((
          startLine: startLine,
          foldable: _foldableDeclaration(declaration),
        ));
      } else if (unit == 0x7d && stack.isNotEmpty) {
        final opened = stack.removeLast();
        if (opened.foldable && line > opened.startLine) {
          regions.add(FoldingRegion(opened.startLine, line));
        }
      }
    }
    if (trimmed.isNotEmpty && trimmed != '{') previousContent = line;
  }
  regions.sort((a, b) => a.startLine.compareTo(b.startLine));
  return regions;
}

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
  bool _attachScheduled = false;
  bool _revealScheduled = false;
  TextEditingValue _ime = TextEditingValue.empty;
  bool _receiving = false;
  double _height = 400;
  int? _dragAnchor;
  Timer? _completionTimer;
  final Set<int> _collapsedFolds = {};
  final List<Rect> _colorRects = [];
  List<CompletionSymbol> _completions = const [];
  int _completionSelection = 0;
  double get _fontSize => widget.session.settings.fontSize;
  double get _lineHeight => _fontSize * 1.6;
  EditorController get _editor => widget.controller;
  TextStyle get _style => TextStyle(
    fontFamily: widget.session.settings.get('fontFamily') as String,
    fontSize: _fontSize,
    height: 1.6,
    fontFeatures: const [
      FontFeature.disable('liga'),
      FontFeature.disable('calt'),
    ],
    color: Color(widget.session.theme.color('foreground')),
  );
  @override
  void initState() {
    super.initState();
    _subscription = _editor.changes.listen((_) => _onChange());
    _focus.addListener(_focusChanged);
    _scroll.addListener(_repaint);
    _horizontal.addListener(_repaint);
    _scheduleReveal();
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
      _collapsedFolds.clear();
      _scheduleReveal();
      _completions = const [];
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
      _completions = const [];
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

  void _scheduleAttach() {
    if (_attachScheduled || !mounted || _editor.readOnly) return;
    if (!_focus.hasFocus) return;
    _attachScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attachScheduled = false;
      if (!mounted || _editor.readOnly) return;
      if (_focus.hasFocus) _attach();
    });
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
    final line = _editor.buffer.positionAt(_editor.selection.extent).line;
    for (final region in _foldRegions()) {
      if (region.startLine < line && line <= region.endLine) {
        _collapsedFolds.remove(region.startLine);
      }
    }
    _repaint();
    _scheduleReveal();
    _completionTimer?.cancel();
    _completionTimer = Timer(
      const Duration(milliseconds: 35),
      _updateCompletions,
    );
  }

  void _updateCompletions() {
    if (!mounted || !_focus.hasFocus || widget.language == null) return;
    final index = widget.session.completionIndex;
    if (index == null) return;
    final suggestions = index.suggest(
      source: _editor.text,
      offset: _editor.selection.extent,
      language: widget.language!.id,
    );
    setState(() {
      _completions = suggestions;
      _completionSelection = 0;
    });
    if (suggestions.isEmpty &&
        index.refreshing &&
        RegExp(
          r'\.([A-Za-z_$][\w$]*)?$',
        ).hasMatch(_editor.text.substring(0, _editor.selection.extent))) {
      _completionTimer = Timer(
        const Duration(milliseconds: 350),
        _updateCompletions,
      );
    }
  }

  void _acceptCompletion(CompletionSymbol item) {
    final cursor = _editor.selection.extent;
    final before = _editor.text.substring(0, cursor);
    final prefix =
        RegExp(r'[A-Za-z_$][\w$]*$').firstMatch(before)?.group(0) ?? '';
    _editor.select(cursor - prefix.length, cursor);
    final insertion = item.callable ? '${item.name}()' : item.name;
    _editor.replaceSelection(insertion);
    if (item.callable && item.signature != '${item.name}()') {
      final inside = cursor - prefix.length + item.name.length + 1;
      _editor.select(inside, inside);
    }
    setState(() => _completions = const []);
  }

  // Search selection can arrive before a newly opened editor is laid out.
  List<Widget> _colorSwatches(List<int> lines, double viewportWidth) {
    _colorRects.clear();
    final widgets = <Widget>[];
    final scrollY = _scroll.hasClients ? _scroll.offset : 0.0;
    final scrollX = _horizontal.hasClients ? _horizontal.offset : 0.0;
    final hexPattern = RegExp(
      r'(?<![\w#])#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})(?![\w-])',
    );
    final start = (scrollY / _lineHeight).floor().clamp(0, lines.length);
    final end = ((scrollY + _height) / _lineHeight).ceil().clamp(
      0,
      lines.length,
    );
    for (var display = start; display < end; display++) {
      final line = lines[display];
      final raw = _editor.buffer.getLine(line);
      final matches = hexPattern.allMatches(raw).toList();
      if (matches.isEmpty) continue;
      final expanded = ExpandedLine(raw, _editor.tabSize);
      final painter = TextPainter(
        text: TextSpan(text: expanded.text, style: _style),
        textDirection: TextDirection.ltr,
      )..layout();
      var x = 64 + painter.width + 8 - scrollX;
      painter.dispose();
      final y = display * _lineHeight - scrollY + (_lineHeight - 16) / 2;
      for (final match in matches) {
        final hex = match.group(0)!;
        final rect = Rect.fromLTWH(x, y, 16, 16);
        x += 22;
        if (rect.left < 64 ||
            rect.right > viewportWidth ||
            rect.top < 0 ||
            rect.bottom > _height) {
          continue;
        }
        _colorRects.add(rect);
        final offset = _editor.buffer.offsetAt(TextPoint(line, match.start));
        widgets.add(
          Positioned(
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
            child: Tooltip(
              message:
                  '$hex · ${_editor.readOnly ? 'Color preview' : 'Change color'}',
              child: GestureDetector(
                onTap: () async {
                  if (_editor.readOnly) return;
                  final editor = _editor;
                  final chosen = await showDialog<String>(
                    context: context,
                    builder: (_) => HexColorPicker(hex: hex),
                  );
                  if (!mounted ||
                      chosen == null ||
                      editor != _editor ||
                      editor.readOnly) {
                    return;
                  }
                  if (offset + hex.length > editor.text.length ||
                      editor.text.substring(offset, offset + hex.length) !=
                          hex) {
                    return;
                  }
                  editor.select(offset, offset + hex.length);
                  editor.replaceSelection(chosen);
                  _focus.requestFocus();
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: parseHexColor(hex),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(
                      color: Color(widget.session.theme.color('muted')),
                      width: 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
    return widgets;
  }

  void _scheduleReveal() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (mounted) _ensureVisible();
    });
  }

  void _ensureVisible() {
    if (!_scroll.hasClients) return;
    final point = _editor.buffer.positionAt(_editor.selection.extent);
    final regions = _foldRegions();
    final visible = _visibleLines(regions);
    final y = _displayLine(point.line, visible, regions) * _lineHeight;
    final offset = _scroll.offset;
    if (y < offset) {
      _scroll.jumpTo(y.clamp(0, _scroll.position.maxScrollExtent));
    } else if (y + _lineHeight > offset + _height) {
      _scroll.jumpTo(
        (y + _lineHeight - _height).clamp(0, _scroll.position.maxScrollExtent),
      );
    }
  }

  List<FoldingRegion> _foldRegions() => foldingRegionsForLines([
    for (var line = 0; line < _editor.buffer.lineCount; line++)
      _editor.buffer.getLine(line),
  ]);

  List<int> _visibleLines(List<FoldingRegion> regions) {
    final collapsed = {
      for (final region in regions)
        if (_collapsedFolds.contains(region.startLine))
          region.startLine: region,
    };
    final lines = <int>[];
    for (var line = 0; line < _editor.buffer.lineCount;) {
      lines.add(line);
      final region = collapsed[line];
      line = region == null ? line + 1 : region.endLine + 1;
    }
    return lines;
  }

  int _displayLine(
    int sourceLine,
    List<int> visible,
    List<FoldingRegion> regions,
  ) {
    final exact = visible.indexOf(sourceLine);
    if (exact >= 0) return exact;
    for (final region in regions) {
      if (_collapsedFolds.contains(region.startLine) &&
          sourceLine > region.startLine &&
          sourceLine <= region.endLine) {
        return visible.indexOf(region.startLine).clamp(0, visible.length - 1);
      }
    }
    return 0;
  }

  void _toggleFold(Offset point) {
    final regions = _foldRegions();
    final visible = _visibleLines(regions);
    final display =
        ((point.dy + (_scroll.hasClients ? _scroll.offset : 0)) / _lineHeight)
            .floor()
            .clamp(0, visible.length - 1);
    final line = visible[display];
    final region = regions.where((item) => item.startLine == line).firstOrNull;
    if (region == null) return;
    setState(() {
      if (!_collapsedFolds.add(line)) _collapsedFolds.remove(line);
      if (_collapsedFolds.contains(line)) {
        final current = _editor.buffer
            .positionAt(_editor.selection.extent)
            .line;
        if (current > line && current <= region.endLine) {
          final offset = _editor.buffer.offsetAt(
            TextPoint(line, _editor.buffer.getLine(line).length),
          );
          _editor.select(offset, offset);
        }
      }
    });
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_completions.isNotEmpty) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() {
          _completionSelection =
              (_completionSelection + 1) % _completions.length;
        });
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() {
          _completionSelection =
              (_completionSelection - 1) % _completions.length;
        });
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.tab) {
        _acceptCompletion(_completions[_completionSelection]);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() => _completions = const []);
        return KeyEventResult.handled;
      }
    } else if (event.logicalKey == LogicalKeyboardKey.escape &&
        _focus.hasFocus) {
      if (_connection != null) _hideKeyboard();
      unawaited(widget.session.run('file.close'));
      return KeyEventResult.handled;
    }
    final command = widget.session.keys.resolve(keyChord(event));
    if (command != null) {
      unawaited(widget.session.run(command));
      return KeyEventResult.handled;
    }
    // On Windows a custom TextInputClient can lose the WM_CHAR redispatch
    // after Flutter focus/overlay changes. Handle printable physical keys here;
    // composed input continues through updateEditingValue.
    final character = event.character;
    final keyboard = HardwareKeyboard.instance;
    if (defaultTargetPlatform == TargetPlatform.windows &&
        !keyboard.isControlPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isAltPressed &&
        character != null &&
        character.isNotEmpty &&
        !character.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      _editor.replaceSelection(character);
      return KeyEventResult.handled;
    }
    // Printable text is delivered only by IME (avoids duplicate text events).
    return KeyEventResult.ignored;
  }

  int _offsetAt(Offset point) {
    final regions = _foldRegions();
    final visible = _visibleLines(regions);
    final displayLine =
        ((point.dy + (_scroll.hasClients ? _scroll.offset : 0)) / _lineHeight)
            .floor()
            .clamp(0, visible.length - 1);
    final line = visible[displayLine];
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

  void _select(int start, int end) => _editor.select(start, end);
  void _tap(Offset position) {
    _focus.requestFocus();
    _attach();
    if (position.dx < 60) {
      _toggleFold(position);
      return;
    }
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

  void _hideKeyboard() {
    // Unfocus first so connectionClosed does not re-attach IME.
    _focus.unfocus();
    _connection?.close();
    _connection = null;
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    _repaint();
  }

  bool get _isTouchPlatform =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  Widget _keyboardDismissBar() {
    final theme = widget.session.theme;
    return Material(
      color: Color(theme.color('panel')),
      elevation: 2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Color(theme.color('border')))),
        ),
        child: SafeArea(
          top: false,
          minimum: EdgeInsets.zero,
          child: SizedBox(
            height: 40,
            child: Row(
              children: [
                const SizedBox(width: 8),
                Text(
                  'Клавиатура',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(theme.color('muted')),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Скрыть клавиатуру',
                  visualDensity: VisualDensity.compact,
                  onPressed: _hideKeyboard,
                  icon: Icon(
                    Icons.keyboard_hide_outlined,
                    size: 22,
                    color: Color(theme.color('foreground')),
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final showDismiss =
        _isTouchPlatform &&
        !_editor.readOnly &&
        _focus.hasFocus &&
        (keyboardVisible || _connection != null);
    final editor = LayoutBuilder(
      builder: (context, constraints) {
        _height = constraints.maxHeight;
        final foldRegions = _foldRegions();
        _collapsedFolds.retainAll(
          foldRegions.map((region) => region.startLine),
        );
        final visibleLines = _visibleLines(foldRegions);
        final totalHeight = math.max(
          _height,
          visibleLines.length * _lineHeight + 32,
        );
        // Width is measured from visible lines only, with a useful horizontal runway.
        final viewport = EditorViewport(
          scrollOffset: _scroll.hasClients ? _scroll.offset : 0,
          height: _height,
          lineHeight: _lineHeight,
        );
        var width = constraints.maxWidth;
        for (
          var i = viewport.firstLine(visibleLines.length);
          i < viewport.endLine(visibleLines.length);
          i++
        ) {
          final line = visibleLines[i];
          width = math.max(
            width,
            ExpandedLine(
                      _editor.buffer.getLine(line),
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
                    if (_colorRects.any(
                      (rect) => rect.contains(e.localPosition),
                    )) {
                      _dragAnchor = null;
                      return;
                    }
                    _focus.requestFocus();
                    if (e.localPosition.dx < 60) {
                      _dragAnchor = null;
                      return;
                    }
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
                                visibleLines: visibleLines,
                                foldRegions: foldRegions,
                                collapsedFolds: _collapsedFolds,
                              ),
                            ),
                          ),
                        ),
                      ),
                      ..._colorSwatches(visibleLines, constraints.maxWidth),
                      if (_completions.isNotEmpty)
                        _completionPopup(constraints.maxWidth),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    if (!showDismiss) return editor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: editor),
        _keyboardDismissBar(),
      ],
    );
  }

  Widget _completionPopup(double maxWidth) {
    final point = _editor.buffer.positionAt(_editor.selection.extent);
    final regions = _foldRegions();
    final visible = _visibleLines(regions);
    final left =
        (64 +
                point.column * _fontSize * 0.62 -
                (_horizontal.hasClients ? _horizontal.offset : 0))
            .clamp(8.0, math.max(8.0, maxWidth - 330))
            .toDouble();
    final top =
        ((_displayLine(point.line, visible, regions) + 1) * _lineHeight -
                (_scroll.hasClients ? _scroll.offset : 0))
            .clamp(4.0, math.max(4.0, _height - 260))
            .toDouble();
    return Positioned(
      left: left,
      top: top,
      width: math.min(330, maxWidth - 16),
      child: Material(
        elevation: 8,
        color: Color(widget.session.theme.color('panel')),
        shape: RoundedRectangleBorder(
          side: BorderSide(color: Color(widget.session.theme.color('border'))),
          borderRadius: BorderRadius.circular(6),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            shrinkWrap: true,
            itemCount: _completions.length,
            itemBuilder: (_, index) {
              final item = _completions[index];
              return ListTile(
                dense: true,
                selected: index == _completionSelection,
                leading: Icon(switch (item.kind) {
                  CompletionKind.method => Icons.functions,
                  CompletionKind.variable => Icons.data_object,
                  CompletionKind.field => Icons.view_headline_outlined,
                  CompletionKind.property => Icons.tune,
                  CompletionKind.constant => Icons.lock_outline,
                }, size: 17),
                title: Text(item.signature, maxLines: 1),
                subtitle: Text(
                  item.documentation.isEmpty
                      ? [
                          item.owner,
                          item.path,
                        ].where((value) => value.isNotEmpty).join(' · ')
                      : item.documentation,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _acceptCompletion(item),
              );
            },
          ),
        ),
      ),
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
        // Apply the platform edit to the controller owned by this editor.
        _editor.select(start, a);
        _editor.replaceSelection(value.text.substring(start, b));
      }
      if (value.selection.isValid) {
        _editor.select(
          value.selection.baseOffset,
          value.selection.extentOffset,
        );
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
    _scheduleAttach();
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
    _completionTimer?.cancel();
    _subscription?.cancel();
    _connection?.close();
    _focus.dispose();
    _scroll.dispose();
    _horizontal.dispose();
    super.dispose();
  }
}
