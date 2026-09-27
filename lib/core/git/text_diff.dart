import 'dart:typed_data';

class DiffLine {
  const DiffLine(this.kind, this.text, this.oldLine, this.newLine);
  final String kind, text;
  final int? oldLine, newLine;
}

class TextDiff {
  const TextDiff(this.lines, {this.coarse = false});
  final List<DiffLine> lines;
  final bool coarse;
  int get added => lines.where((line) => line.kind == '+').length;
  int get removed => lines.where((line) => line.kind == '-').length;
}

/// Bounded line diff. Large dissimilar blocks use replacement rows instead of
/// allocating a quadratic matrix. Rows retain both versions' line numbers.
TextDiff compareText(String? before, String? after) {
  List<String> split(String? value) => value == null || value.isEmpty
      ? []
      : value.replaceAll('\r\n', '\n').split('\n');
  final a = split(before), b = split(after);
  var prefix = 0, suffix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] == b[prefix]) {
    prefix++;
  }
  while (suffix < a.length - prefix &&
      suffix < b.length - prefix &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  final rows = <DiffLine>[];
  for (var i = 0; i < prefix; i++) {
    rows.add(DiffLine(' ', a[i], i + 1, i + 1));
  }
  final n = a.length - prefix - suffix, m = b.length - prefix - suffix;
  final coarse = (n + 1) * (m + 1) > 1000000;
  if (coarse) {
    for (var i = 0; i < n; i++) {
      rows.add(DiffLine('-', a[prefix + i], prefix + i + 1, null));
    }
    for (var j = 0; j < m; j++) {
      rows.add(DiffLine('+', b[prefix + j], null, prefix + j + 1));
    }
  } else {
    final table = Uint32List((n + 1) * (m + 1));
    int at(int i, int j) => i * (m + 1) + j;
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        final down = table[at(i + 1, j)], right = table[at(i, j + 1)];
        table[at(i, j)] = a[prefix + i] == b[prefix + j]
            ? 1 + table[at(i + 1, j + 1)]
            : (down > right ? down : right);
      }
    }
    var i = 0, j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && a[prefix + i] == b[prefix + j]) {
        rows.add(DiffLine(' ', a[prefix + i], prefix + i + 1, prefix + j + 1));
        i++;
        j++;
      } else if (i < n &&
          (j == m || table[at(i + 1, j)] >= table[at(i, j + 1)])) {
        rows.add(DiffLine('-', a[prefix + i], prefix + i + 1, null));
        i++;
      } else {
        rows.add(DiffLine('+', b[prefix + j], null, prefix + j + 1));
        j++;
      }
    }
  }
  for (var i = suffix; i > 0; i--) {
    rows.add(
      DiffLine(' ', a[a.length - i], a.length - i + 1, b.length - i + 1),
    );
  }
  return TextDiff(rows, coarse: coarse);
}
