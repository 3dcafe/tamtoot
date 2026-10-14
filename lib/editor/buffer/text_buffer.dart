/// Zero-based UTF-16 coordinates, matching Flutter text input and LSP adapters.
class TextPoint {
  const TextPoint(this.line, this.column);
  final int line;
  final int column;
}

class BufferEdit {
  const BufferEdit(this.start, this.end, this.text);
  final int start;
  final int end;
  final String text;
}

/// Replaceable storage boundary. Ranges are half-open UTF-16 offsets.
abstract interface class TextBuffer {
  int get length;
  int get lineCount;
  String getText(int start, int end);
  String getLine(int line);
  TextPoint positionAt(int offset);
  int offsetAt(TextPoint position);
  String applyEdit(BufferEdit edit);
}

/// Indexed string storage for MVP. Reads of visible lines do not split the file.
/// Edits still copy the string, but update the line index incrementally.
/// A rope can replace string storage after profiling.
class IndexedTextBuffer implements TextBuffer {
  IndexedTextBuffer(String text) : _text = text.replaceAll('\r\n', '\n') {
    _index();
  }
  String _text;
  List<int> _starts = [];
  void _index() {
    _starts = [0];
    for (var i = 0; i < _text.length; i++) {
      if (_text.codeUnitAt(i) == 10) _starts.add(i + 1);
    }
  }

  @override
  int get length => _text.length;
  @override
  int get lineCount => _starts.length;
  @override
  String getText(int start, int end) => _text.substring(start, end);
  @override
  String getLine(int line) => _text.substring(
    _starts[line],
    line + 1 < lineCount ? _starts[line + 1] - 1 : length,
  );
  @override
  TextPoint positionAt(int offset) {
    offset = offset.clamp(0, length);
    var low = 0;
    var high = _starts.length;
    while (low + 1 < high) {
      final mid = (low + high) ~/ 2;
      if (_starts[mid] <= offset) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return TextPoint(low, offset - _starts[low]);
  }

  @override
  int offsetAt(TextPoint position) {
    final line = position.line.clamp(0, lineCount - 1);
    final end = line + 1 < lineCount ? _starts[line + 1] - 1 : length;
    return _starts[line] + position.column.clamp(0, end - _starts[line]);
  }

  int _firstStartAfter(int offset) {
    var low = 0, high = _starts.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_starts[middle] <= offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  @override
  String applyEdit(BufferEdit edit) {
    if (edit.start < 0 || edit.end < edit.start || edit.end > length) {
      throw RangeError('Invalid edit ${edit.start}..${edit.end}');
    }
    final removed = getText(edit.start, edit.end);
    final first = _firstStartAfter(edit.start);
    final last = _firstStartAfter(edit.end);
    final inserted = <int>[];
    for (var i = 0; i < edit.text.length; i++) {
      if (edit.text.codeUnitAt(i) == 10) inserted.add(edit.start + i + 1);
    }
    _text = _text.replaceRange(edit.start, edit.end, edit.text);
    // Only deleted/inserted newlines change the index. Existing line starts
    // after the edit shift by its length delta; the prefix stays untouched.
    _starts.replaceRange(first, last, inserted);
    final delta = edit.text.length - (edit.end - edit.start);
    if (delta != 0) {
      for (var i = first + inserted.length; i < _starts.length; i++) {
        _starts[i] += delta;
      }
    }
    return removed;
  }
}
