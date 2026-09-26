import 'dart:async';
import '../buffer/text_buffer.dart';

class EditorSelection {
  const EditorSelection(this.anchor, this.extent);
  final int anchor;
  final int extent;
  int get start => anchor < extent ? anchor : extent;
  int get end => anchor > extent ? anchor : extent;
  bool get isCollapsed => anchor == extent;
}

class Decoration {
  const Decoration(this.start, this.end, this.kind, {this.message});
  final int start, end;
  final String kind;
  final String? message;
}

class FoldingRegion {
  const FoldingRegion(this.startLine, this.endLine, {this.collapsed = false});
  final int startLine, endLine;
  final bool collapsed;
}

class _Transaction {
  _Transaction(this.edits, this.inverse, this.before, this.after);
  final List<BufferEdit> edits, inverse;
  final EditorSelection before, after;
}

/// Framework/language independent editor. Every transaction is one undo step.
class EditorController {
  EditorController(String text, {TextBuffer? storage})
    : buffer = storage ?? IndexedTextBuffer(text);
  final TextBuffer buffer;
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  int revision = 0;
  bool readOnly = false;
  int tabSize = 2;
  bool insertSpaces = true;
  List<EditorSelection> selections = [const EditorSelection(0, 0)];
  final List<Decoration> decorations = [];
  final List<FoldingRegion> folds = [];
  final List<_Transaction> _undo = [], _redo = [];
  EditorSelection get selection => selections.first;
  String get text => buffer.getText(0, buffer.length);
  bool get canUndo => !readOnly && _undo.isNotEmpty;
  bool get canRedo => !readOnly && _redo.isNotEmpty;
  void notify() => _changes.add(null);
  void select(int anchor, int extent) {
    selections = [
      EditorSelection(
        anchor.clamp(0, buffer.length),
        extent.clamp(0, buffer.length),
      ),
    ];
    notify();
  }

  void replaceSelection(String text) => transact([
    BufferEdit(selection.start, selection.end, text.replaceAll('\r\n', '\n')),
  ]);

  /// Edits use original coordinates and must be non-overlapping.
  void transact(List<BufferEdit> edits) {
    if (readOnly || edits.isEmpty) return;
    final ordered = [...edits]..sort((a, b) => a.start.compareTo(b.start));
    var previousEnd = -1;
    for (final edit in ordered) {
      if (edit.start < previousEnd ||
          edit.start < 0 ||
          edit.end < edit.start ||
          edit.end > buffer.length) {
        throw ArgumentError('Overlapping or invalid edits');
      }
      previousEnd = edit.end;
    }
    final before = selection;
    var delta = 0;
    final inverse = <BufferEdit>[];
    for (final e in ordered) {
      inverse.add(
        BufferEdit(
          e.start + delta,
          e.start + delta + e.text.length,
          buffer.getText(e.start, e.end),
        ),
      );
      delta += e.text.length - (e.end - e.start);
    }
    for (final e in ordered.reversed) {
      buffer.applyEdit(e);
    }
    final last = inverse.last;
    final after = EditorSelection(last.end, last.end);
    _undo.add(_Transaction(ordered, inverse, before, after));
    _redo.clear();
    selections = [after];
    revision++;
    notify();
  }

  void undo() {
    if (!canUndo) return;
    final t = _undo.removeLast();
    for (final e in t.inverse.reversed) {
      buffer.applyEdit(e);
    }
    _redo.add(t);
    selections = [t.before];
    revision++;
    notify();
  }

  void redo() {
    if (!canRedo) return;
    final t = _redo.removeLast();
    for (final e in t.edits.reversed) {
      buffer.applyEdit(e);
    }
    _undo.add(t);
    selections = [t.after];
    revision++;
    notify();
  }

  int previousOffset(int offset) {
    if (offset <= 0) return 0;
    final unit = buffer.getText(offset - 1, offset).codeUnitAt(0);
    return (unit >= 0xDC00 && unit <= 0xDFFF && offset > 1)
        ? offset - 2
        : offset - 1;
  }

  int nextOffset(int offset) {
    if (offset >= buffer.length) return buffer.length;
    final unit = buffer.getText(offset, offset + 1).codeUnitAt(0);
    return (unit >= 0xD800 && unit <= 0xDBFF && offset + 1 < buffer.length)
        ? offset + 2
        : offset + 1;
  }

  void delete({bool backwards = true}) {
    if (!selection.isCollapsed) {
      replaceSelection('');
      return;
    }
    final p = selection.extent;
    transact([
      BufferEdit(
        backwards ? previousOffset(p) : p,
        backwards ? p : nextOffset(p),
        '',
      ),
    ]);
  }

  void move(String direction, {bool extend = false}) {
    var offset = selection.extent;
    final point = buffer.positionAt(offset);
    offset = switch (direction) {
      'left' =>
        !extend && !selection.isCollapsed
            ? selection.start
            : previousOffset(offset),
      'right' =>
        !extend && !selection.isCollapsed ? selection.end : nextOffset(offset),
      'up' => buffer.offsetAt(TextPoint(point.line - 1, point.column)),
      'down' => buffer.offsetAt(TextPoint(point.line + 1, point.column)),
      'home' => buffer.offsetAt(TextPoint(point.line, 0)),
      'end' => buffer.offsetAt(
        TextPoint(point.line, buffer.getLine(point.line).length),
      ),
      'start' => 0,
      'finish' => buffer.length,
      _ => offset,
    };
    select(extend ? selection.anchor : offset, offset);
  }

  bool find(String query, {bool next = true}) {
    if (query.isEmpty) return false;
    var found = text.indexOf(query, next ? selection.end : 0);
    if (found < 0) found = text.indexOf(query);
    if (found < 0) return false;
    select(found, found + query.length);
    return true;
  }

  void replaceAll(String query, String replacement) {
    if (query.isEmpty) return;
    final edits = <BufferEdit>[];
    final source = text;
    var offset = 0;
    while (true) {
      final index = source.indexOf(query, offset);
      if (index < 0) break;
      edits.add(BufferEdit(index, index + query.length, replacement));
      offset = index + query.length;
    }
    transact(edits);
  }

  /// Small bounded hook; language providers may supply richer bracket matching.
  int? matchingBracket(String open, String close) {
    final start = selection.extent;
    if (start >= buffer.length || buffer.getText(start, start + 1) != open) {
      return null;
    }
    var depth = 0;
    for (var i = start; i < buffer.length && i < start + 10000; i++) {
      final char = buffer.getText(i, i + 1);
      if (char == open) depth++;
      if (char == close && --depth == 0) return i;
    }
    return null;
  }

  Future<void> dispose() => _changes.close();
}
