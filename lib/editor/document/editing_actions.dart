import '../../languages/language_registry.dart';
import '../../languages/document_syntax.dart';
import '../buffer/text_buffer.dart';
import 'editor_controller.dart';

/// Interactive typing helpers. Paste and composing IME edits remain literal.
class EditingActions {
  final _syntax = DocumentSyntax();

  String? scopeAtCaret(EditorController e, LanguageDefinition? language) {
    if (language == null) return null;
    final point = e.buffer.positionAt(e.selection.start);
    final tokens = _syntax.tokensFor(
      source: e,
      revision: e.revision,
      language: language,
      lineCount: e.buffer.lineCount,
      readLine: e.buffer.getLine,
      line: point.line,
    );
    for (final token in tokens) {
      if (token.start < point.column && token.end > point.column) {
        return token.scope;
      }
      if (token.scope == 'comment' &&
          token.start < point.column &&
          token.end == point.column) {
        return 'comment';
      }
    }
    final continuation = _syntax.stateAfterLine(point.line);
    if (point.column == e.buffer.getLine(point.line).length &&
        continuation != null) {
      return continuation.rule.scope;
    }
    // Incomplete single-line quoted strings need not have a syntax token yet.
    final prefix = e.buffer.getLine(point.line).substring(0, point.column);
    String? quote;
    for (var i = 0; i < prefix.length; i++) {
      final c = prefix[i];
      if (c == r'\') {
        i++;
        continue;
      }
      if (c == quote) {
        quote = null;
      } else if (quote == null && (c == '"' || c == "'" || c == '`')) {
        quote = c;
      }
    }
    return quote == null ? null : 'string';
  }

  Map<String, String> _pairs(LanguageDefinition? language) => {
    for (final pair in language?.autoClosingPairs ?? const [])
      if ((pair['open'] as String).length == 1 &&
          (pair['close'] as String).length == 1)
        pair['open'] as String: pair['close'] as String,
  };

  void type(EditorController e, LanguageDefinition? language, String text) {
    if (e.readOnly) return;
    if (text == '\n') {
      newline(e, language);
      return;
    }
    if (text.length != 1 || language == null) {
      e.replaceSelection(text);
      return;
    }
    final selection = e.selection;
    final pairs = _pairs(language);
    final next = e.buffer.getText(
      selection.end,
      (selection.end + 1).clamp(0, e.buffer.length),
    );
    final close = pairs[text];
    final scope = scopeAtCaret(e, language);
    var slashes = 0;
    for (
      var i = selection.start - 1;
      i >= 0 && e.buffer.getText(i, i + 1) == r'\';
      i--
    ) {
      slashes++;
    }
    final escapedQuote = (text == '"' || text == "'") && slashes.isOdd;
    if (selection.isCollapsed &&
        scope != 'comment' &&
        !escapedQuote &&
        (scope != 'string' || text == '"' || text == "'") &&
        next == text &&
        pairs.values.contains(text)) {
      e.select(selection.end + 1, selection.end + 1);
      return;
    }
    if (close == null ||
        escapedQuote ||
        scope == 'string' ||
        scope == 'comment' ||
        (selection.isCollapsed &&
            next.isNotEmpty &&
            RegExp(r'[\w$]').hasMatch(next))) {
      e.replaceSelection(text);
      return;
    }
    final selected = e.buffer.getText(selection.start, selection.end);
    final after = selection.isCollapsed
        ? EditorSelection(selection.start + 1, selection.start + 1)
        : (selection.anchor <= selection.extent
              ? EditorSelection(selection.start + 1, selection.end + 1)
              : EditorSelection(selection.end + 1, selection.start + 1));
    e.transact([
      BufferEdit(selection.start, selection.end, '$text$selected$close'),
    ], selectionAfter: after);
  }

  void backspace(EditorController e, LanguageDefinition? language) {
    if (e.readOnly) return;
    final s = e.selection;
    if (s.isCollapsed && s.start > 0 && s.start < e.buffer.length) {
      final before = e.buffer.getText(s.start - 1, s.start);
      final after = e.buffer.getText(s.start, s.start + 1);
      if (_pairs(language)[before] == after) {
        e.transact([BufferEdit(s.start - 1, s.start + 1, '')]);
        return;
      }
    }
    e.delete();
  }

  void newline(EditorController e, LanguageDefinition? language) {
    if (e.readOnly) return;
    final s = e.selection;
    final point = e.buffer.positionAt(s.start);
    final prefix = e.buffer.getLine(point.line).substring(0, point.column);
    final indent = RegExp(r'^[ \t]*').firstMatch(prefix)!.group(0)!;
    final marker = language?.indentation['increaseAfter'] as String?;
    final scope = scopeAtCaret(e, language);
    final increase =
        marker != null &&
        marker.isNotEmpty &&
        prefix.trimRight().endsWith(marker) &&
        scope != 'comment' &&
        scope != 'string';
    final unit = e.insertSpaces ? ' ' * e.tabSize : '\t';
    final inner = '$indent${increase ? unit : ''}';
    final next = e.buffer.getText(s.end, (s.end + 1).clamp(0, e.buffer.length));
    final split = increase && _pairs(language)[marker] == next;
    final insertion = '\n$inner${split ? '\n$indent' : ''}';
    final cursor = s.start + 1 + inner.length;
    e.transact([
      BufferEdit(s.start, s.end, insertion),
    ], selectionAfter: EditorSelection(cursor, cursor));
  }

  bool canComment(LanguageDefinition? language) =>
      language?.comments['line'] is String ||
      language?.comments['block'] is Map;

  void toggleComment(EditorController e, LanguageDefinition? language) {
    if (e.readOnly || !canComment(language)) return;
    final s = e.selection;
    final first = e.buffer.positionAt(s.start).line;
    final endPoint = e.buffer.positionAt(s.end);
    final last = !s.isCollapsed && endPoint.column == 0
        ? endPoint.line - 1
        : endPoint.line;
    final from = e.buffer.offsetAt(TextPoint(first, 0));
    final to = e.buffer.offsetAt(
      TextPoint(last, e.buffer.getLine(last).length),
    );
    final lines = e.buffer.getText(from, to).split('\n');
    final marker = language!.comments['line'] as String?;
    String replacement;
    if (marker != null) {
      final nonempty = lines.where((line) => line.trim().isNotEmpty).toList();
      if (nonempty.isEmpty) return;
      final remove = nonempty.every(
        (line) => line.trimLeft().startsWith(marker),
      );
      final column = nonempty
          .map((line) => RegExp(r'^[ \t]*').firstMatch(line)!.group(0)!.length)
          .reduce((a, b) => a < b ? a : b);
      replacement = lines
          .map((line) {
            if (line.trim().isEmpty) {
              return line;
            }
            if (!remove) {
              return '${line.substring(0, column)}$marker ${line.substring(column)}';
            }
            final at = line.indexOf(marker);
            var end = at + marker.length;
            if (end < line.length && line[end] == ' ') end++;
            return line.substring(0, at) + line.substring(end);
          })
          .join('\n');
    } else {
      final block = language.comments['block'] as Map;
      final open = block['open'] as String, close = block['close'] as String;
      final content = lines.join('\n');
      replacement =
          content.startsWith('$open\n') && content.endsWith('\n$close')
          ? content.substring(
              open.length + 1,
              content.length - close.length - 1,
            )
          : '$open\n$content\n$close';
    }
    final end = from + replacement.length;
    e.transact([
      BufferEdit(from, to, replacement),
    ], selectionAfter: EditorSelection(from, end));
  }
}
