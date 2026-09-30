import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/themes/ide_theme.dart';
import '../../languages/language_registry.dart';
import '../../languages/document_syntax.dart';
import '../buffer/text_buffer.dart';
import '../document/editor_controller.dart';
import '../viewport/editor_viewport.dart';
import 'expanded_line.dart';

class CodePainter extends CustomPainter {
  CodePainter({
    required this.editor,
    required this.syntax,
    required this.language,
    required this.theme,
    required this.style,
    required this.scrollY,
    required this.scrollX,
    required this.lineHeight,
    required this.focused,
    required this.composing,
    required this.visibleLines,
    required this.foldRegions,
    required this.collapsedFolds,
  });
  final EditorController editor;
  final DocumentSyntax syntax;
  final LanguageDefinition? language;
  final IdeTheme theme;
  final TextStyle style;
  final double scrollY, scrollX, lineHeight;
  final bool focused;
  final TextRange composing;
  final List<int> visibleLines;
  final List<FoldingRegion> foldRegions;
  final Set<int> collapsedFolds;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final viewport = EditorViewport(
      scrollOffset: scrollY,
      height: size.height,
      lineHeight: lineHeight,
    );
    final current = editor.buffer.positionAt(editor.selection.extent);
    final paint = Paint();
    for (
      var displayLine = viewport.firstLine(visibleLines.length);
      displayLine < viewport.endLine(visibleLines.length);
      displayLine++
    ) {
      final line = visibleLines[displayLine];
      final y = displayLine * lineHeight - scrollY;
      if (line == current.line) {
        canvas.drawRect(
          Rect.fromLTWH(0, y, size.width, lineHeight),
          paint..color = Color(theme.color('currentLine')),
        );
      }
      final raw = editor.buffer.getLine(line);
      final expanded = ExpandedLine(raw, editor.tabSize);
      final spans = <TextSpan>[];
      var position = 0;
      for (final token in syntax.tokensFor(
        source: editor.buffer,
        revision: editor.revision,
        language: language,
        lineCount: editor.buffer.lineCount,
        readLine: editor.buffer.getLine,
        line: line,
      )) {
        if (token.start > position) {
          spans.add(
            TextSpan(
              text: expanded.text.substring(
                expanded.displayOffset(position),
                expanded.displayOffset(token.start),
              ),
            ),
          );
        }
        spans.add(
          TextSpan(
            text: expanded.text.substring(
              expanded.displayOffset(token.start),
              expanded.displayOffset(token.end),
            ),
            style: TextStyle(color: Color(theme.color(token.scope))),
          ),
        );
        position = token.end;
      }
      if (position < raw.length) {
        spans.add(
          TextSpan(
            text: expanded.text.substring(expanded.displayOffset(position)),
          ),
        );
      }
      final painter = TextPainter(
        text: TextSpan(style: style, children: spans),
        textDirection: TextDirection.ltr,
      )..layout();
      final start = editor.buffer.offsetAt(TextPoint(line, 0));
      final origin = Offset(64 - scrollX, y);
      double x(int offset) =>
          painter
              .getOffsetForCaret(
                TextPosition(offset: expanded.displayOffset(offset)),
                Rect.zero,
              )
              .dx +
          origin.dx;
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(60, 0, math.max(0, size.width - 60), size.height),
      );
      for (final selection in editor.selections) {
        if (selection.end > start &&
            selection.start <= start + raw.length &&
            !selection.isCollapsed) {
          final a = (selection.start - start).clamp(0, raw.length),
              b = (selection.end - start).clamp(0, raw.length);
          canvas.drawRect(
            Rect.fromLTWH(x(a), y, math.max(3, x(b) - x(a)), lineHeight),
            paint..color = Color(theme.color('selection')),
          );
        }
      }
      painter.paint(canvas, origin);
      if (focused && line == current.line) {
        canvas.drawRect(
          Rect.fromLTWH(x(current.column), y + 3, 1.5, lineHeight - 5),
          paint..color = Color(theme.color('accent')),
        );
      }
      for (final d in editor.decorations) {
        if (d.end >= start && d.start <= start + raw.length) {
          canvas.drawLine(
            Offset(
              x((d.start - start).clamp(0, raw.length)),
              y + lineHeight - 2,
            ),
            Offset(x((d.end - start).clamp(0, raw.length)), y + lineHeight - 2),
            paint
              ..color = Color(theme.color('error'))
              ..strokeWidth = 1,
          );
        }
      }
      if (composing.isValid &&
          !composing.isCollapsed &&
          composing.end > start &&
          composing.start <= start + raw.length) {
        canvas.drawLine(
          Offset(
            x((composing.start - start).clamp(0, raw.length)),
            y + lineHeight - 2,
          ),
          Offset(
            x((composing.end - start).clamp(0, raw.length)),
            y + lineHeight - 2,
          ),
          paint..color = Color(theme.color('accent')),
        );
      }
      canvas.restore();
      painter.dispose();
      final number = TextPainter(
        text: TextSpan(
          text: '${line + 1}',
          style: style.copyWith(
            color: Color(
              theme.color(line == current.line ? 'accent' : 'muted'),
            ),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      number.paint(canvas, Offset(47 - number.width, y));
      number.dispose();
      if (foldRegions.any((region) => region.startLine == line)) {
        final collapsed = collapsedFolds.contains(line);
        final marker = Path();
        if (collapsed) {
          marker
            ..moveTo(50, y + 5)
            ..lineTo(55, y + lineHeight / 2)
            ..lineTo(50, y + lineHeight - 5);
        } else {
          marker
            ..moveTo(48, y + 7)
            ..lineTo(55, y + 7)
            ..lineTo(51.5, y + lineHeight - 5);
        }
        marker.close();
        canvas.drawPath(marker, paint..color = Color(theme.color('muted')));
      }
    }
    canvas.drawLine(
      const Offset(56, 0),
      Offset(56, size.height),
      paint..color = Color(theme.color('border')),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(CodePainter oldDelegate) => true;
}
