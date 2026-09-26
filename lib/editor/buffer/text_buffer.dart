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
/// Edits are O(n); a rope can replace this implementation after profiling.
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
    return _starts[line] + position.column.clamp(0, getLine(line).length);
  }

  @override
  String applyEdit(BufferEdit edit) {
    if (edit.start < 0 || edit.end < edit.start || edit.end > length) {
      throw RangeError('Invalid edit ${edit.start}..${edit.end}');
    }
    final removed = getText(edit.start, edit.end);
    _text = _text.replaceRange(edit.start, edit.end, edit.text);
    _index();
    return removed;
  }
}
