class ExpandedLine {
  ExpandedLine(String raw, int tabSize) {
    final result = StringBuffer();
    positions = [0];
    var column = 0;
    for (var i = 0; i < raw.length; i++) {
      final count = raw[i] == '\t' ? tabSize - column % tabSize : 1;
      result.write(raw[i] == '\t' ? ' ' * count : raw[i]);
      column += count;
      positions.add(column);
    }
    text = result.toString();
  }
  late final String text;
  late final List<int> positions;
  int displayOffset(int raw) => positions[raw.clamp(0, positions.length - 1)];
  int rawOffset(int display) {
    for (var i = 1; i < positions.length; i++) {
      if (positions[i] > display) return i - 1;
    }
    return positions.length - 1;
  }
}
