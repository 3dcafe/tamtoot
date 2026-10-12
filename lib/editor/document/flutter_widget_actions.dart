import '../../core/completion/dart_arguments.dart';
import '../buffer/text_buffer.dart';
import 'editor_controller.dart';

/// Lexical widget transforms operate only on an explicitly selected complete
/// constructor expression. Each transform is a single undo transaction.
class FlutterWidgetActions {
  static const wrappers = ['Padding', 'Center', 'Expanded', 'Column', 'Row'];
  static const removable = {
    'Padding',
    'Center',
    'Expanded',
    'Flexible',
    'SizedBox',
    'Container',
    'Column',
    'Row',
  };

  bool available(EditorController editor) =>
      !editor.readOnly &&
      !editor.selection.isCollapsed &&
      flutterUiImport(editor.text);

  ({String text, String prefix, String suffix, String name})? _expression(
    String selected,
  ) {
    if (selected.length > 65536) return null;
    final prefix = RegExp(r'^\s*').firstMatch(selected)!.group(0)!;
    final suffix = RegExp(r'\s*,?\s*$').firstMatch(selected)!.group(0)!;
    final end = selected.length - suffix.length;
    if (end <= prefix.length) return null;
    final text = selected.substring(prefix.length, end);
    final mask = dartStructuralMask(text);
    final header = RegExp(
      r'^(?:const\s+|new\s+)?(?:[a-z_]\w*\.)?([A-Z]\w*)(?:\.[A-Za-z_]\w*)?(?:<[^<>]+>)?\s*\(',
    ).firstMatch(mask);
    if (header == null || !dartBalancedExpression(mask, header.end - 1)) {
      return null;
    }
    return (text: text, prefix: prefix, suffix: suffix, name: header.group(1)!);
  }

  bool canWrap(EditorController editor) =>
      available(editor) &&
      _expression(
            editor.text.substring(editor.selection.start, editor.selection.end),
          ) !=
          null;

  String _indent(EditorController editor) {
    final line = editor.buffer.getLine(
      editor.buffer.positionAt(editor.selection.start).line,
    );
    return RegExp(r'^[ \t]*').firstMatch(line)!.group(0)!;
  }

  String _reindent(String text, String oldIndent, String newIndent) {
    final literalStarts = <int>{};
    dartStructuralMask(text, literalLineStarts: literalStarts);
    final lines = text.split('\n');
    var offset = lines.first.length + 1;
    final result = <String>[lines.first];
    for (final line in lines.skip(1)) {
      result.add(
        literalStarts.contains(offset)
            ? line
            : '$newIndent${line.startsWith(oldIndent) ? line.substring(oldIndent.length) : line}',
      );
      offset += line.length + 1;
    }
    return result.join('\n');
  }

  bool wrap(EditorController editor, String wrapper) {
    if (!wrappers.contains(wrapper) || !canWrap(editor)) return false;
    final expression = _expression(
      editor.text.substring(editor.selection.start, editor.selection.end),
    )!;
    final base = _indent(editor);
    final unit = editor.insertSpaces ? ' ' * editor.tabSize : '\t';
    final collection = wrapper == 'Column' || wrapper == 'Row';
    final childIndent = '$base$unit${collection ? unit : ''}';
    final child = _reindent(expression.text, base, childIndent);
    final body = collection
        ? '$wrapper(\n$base${unit}children: [\n$childIndent$child,\n$base$unit],\n$base)'
        : '$wrapper(\n${wrapper == 'Padding' ? '$base${unit}padding: const EdgeInsets.all(8),\n' : ''}$base${unit}child: $child,\n$base)';
    _replace(editor, '${expression.prefix}$body${expression.suffix}');
    return true;
  }

  String? _child(EditorController editor) {
    if (!available(editor)) return null;
    final expression = _expression(
      editor.text.substring(editor.selection.start, editor.selection.end),
    );
    if (expression == null || !removable.contains(expression.name)) return null;
    final text = expression.text;
    final opening = dartStructuralMask(text).indexOf('(');
    final arguments = dartTopLevelSegments(text, opening + 1, text.length - 1);
    final matches = arguments
        .where(
          (s) => RegExp(
            r'^\s*(?:child|children)\s*:',
          ).hasMatch(dartStructuralMask(s)),
        )
        .toList();
    if (matches.length != 1) return null;
    final segment = matches.single;
    final colon = dartStructuralMask(segment).indexOf(':');
    var child = segment.substring(colon + 1).trim();
    if (RegExp(r'^\s*children\s*:').hasMatch(segment)) {
      if (!child.startsWith('[') || !child.endsWith(']')) return null;
      final children = dartTopLevelSegments(
        child,
        1,
        child.length - 1,
      ).where((s) => dartStructuralMask(s).trim().isNotEmpty).toList();
      if (children.length != 1) return null;
      child = children.single.trim();
    }
    // Avoid replacing a widget by an incomplete expression or dropping comments
    // attached to its child. Widget constructor children are the supported case.
    if (_expression(child) == null) return null;
    final lines = child.split('\n');
    final oldIndent = lines.length > 1
        ? RegExp(r'^[ \t]*').firstMatch(lines.last)!.group(0)!
        : '';
    child = _reindent(child, oldIndent, _indent(editor));
    if (text.startsWith('const ') && !child.startsWith('const ')) {
      child = 'const $child';
    }
    return '${expression.prefix}$child${expression.suffix}';
  }

  bool canUnwrap(EditorController editor) => _child(editor) != null;
  bool unwrap(EditorController editor) {
    final child = _child(editor);
    if (child == null) return false;
    _replace(editor, child);
    return true;
  }

  void _replace(EditorController editor, String text) {
    final start = editor.selection.start;
    editor.transact([
      BufferEdit(start, editor.selection.end, text),
    ], selectionAfter: EditorSelection(start, start + text.length));
  }
}
