import 'package:flutter/painting.dart';
import '../../core/themes/ide_theme.dart';
import '../../languages/language_registry.dart';
import 'expanded_line.dart';

class LineLayout {
  LineLayout(this.expanded, this.painter);
  final ExpandedLine expanded;
  final TextPainter painter;
}

/// Bounded LRU of native text layouts. Cursor/selection/scroll are not keys.
class LineLayoutCache {
  LineLayoutCache({this.capacity = 256}) : assert(capacity > 0);
  final int capacity;
  final _entries = <Object, LineLayout>{};
  int layoutsBuilt = 0;
  int get length => _entries.length;

  LineLayout get({
    required String raw,
    required List<SyntaxToken> tokens,
    required TextStyle style,
    required IdeTheme theme,
    required int tabSize,
  }) {
    final key = (raw, tokens, style, theme, tabSize);
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return cached;
    }
    final expanded = ExpandedLine(raw, tabSize);
    final spans = <TextSpan>[];
    var position = 0;
    for (final token in tokens) {
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
    final result = LineLayout(
      expanded,
      TextPainter(
        text: TextSpan(style: style, children: spans),
        textDirection: TextDirection.ltr,
      )..layout(),
    );
    layoutsBuilt++;
    _entries[key] = result;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first)!.painter.dispose();
    }
    return result;
  }

  void clear() {
    for (final entry in _entries.values) {
      entry.painter.dispose();
    }
    _entries.clear();
  }
}
