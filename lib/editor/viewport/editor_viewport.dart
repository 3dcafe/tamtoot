/// Viewport calculations are pure and independently benchmarkable.
class EditorViewport {
  const EditorViewport({
    required this.scrollOffset,
    required this.height,
    required this.lineHeight,
    this.overscan = 3,
  });
  final double scrollOffset, height, lineHeight;
  final int overscan;
  int firstLine(int count) =>
      ((scrollOffset / lineHeight).floor() - overscan).clamp(0, count - 1);
  int endLine(int count) =>
      ((scrollOffset + height) / lineHeight).ceil().clamp(0, count) + overscan <
          count
      ? ((scrollOffset + height) / lineHeight).ceil().clamp(0, count) + overscan
      : count;
}
