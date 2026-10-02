class GitIgnore {
  GitIgnore([List<_GitIgnoreRule>? rules])
    : _rules = rules == null ? [] : List.of(rules);

  final List<_GitIgnoreRule> _rules;

  GitIgnore copy() => GitIgnore(_rules);

  void add(String source, {String base = ''}) {
    final normalizedBase = base
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    for (var line in source.split('\n')) {
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      line = line.trimRight();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith(r'\#') || line.startsWith(r'\!')) {
        line = line.substring(1);
      }
      var negated = false;
      if (line.startsWith('!')) {
        negated = true;
        line = line.substring(1);
      }
      if (line.isEmpty) continue;
      final directoryOnly = line.endsWith('/');
      if (directoryOnly) line = line.substring(0, line.length - 1);
      final anchored = line.startsWith('/') || line.contains('/');
      if (line.startsWith('/')) line = line.substring(1);
      if (line.isEmpty) continue;
      _rules.add(
        _GitIgnoreRule(
          base: normalizedBase,
          pattern: line,
          negated: negated,
          directoryOnly: directoryOnly,
          anchored: anchored,
        ),
      );
    }
  }

  bool ignores(String path, {required bool directory}) {
    final normalized = path
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^/+'), '');
    var ignored = false;
    for (final rule in _rules) {
      if (rule.matches(normalized, directory: directory)) {
        ignored = !rule.negated;
      }
    }
    return ignored;
  }
}

class _GitIgnoreRule {
  _GitIgnoreRule({
    required this.base,
    required this.pattern,
    required this.negated,
    required this.directoryOnly,
    required this.anchored,
  }) : expression = RegExp(_expression(pattern, anchored, descendants: true)),
       exactExpression = RegExp(
         _expression(pattern, anchored, descendants: false),
       );

  final String base, pattern;
  final bool negated, directoryOnly, anchored;
  final RegExp expression, exactExpression;

  bool matches(String path, {required bool directory}) {
    String relative;
    if (base.isEmpty) {
      relative = path;
    } else if (path == base) {
      relative = '';
    } else if (path.startsWith('$base/')) {
      relative = path.substring(base.length + 1);
    } else {
      return false;
    }
    if (relative.isEmpty) return false;
    if (!expression.hasMatch(relative)) return false;
    if (!directoryOnly) return true;
    return directory || !exactExpression.hasMatch(relative);
  }

  static String _expression(
    String pattern,
    bool anchored, {
    required bool descendants,
  }) {
    final out = StringBuffer(anchored ? '^' : r'(^|.*/)');
    for (var i = 0; i < pattern.length; i++) {
      final char = pattern[i];
      if (char == '*') {
        final doubleStar = i + 1 < pattern.length && pattern[i + 1] == '*';
        if (doubleStar) {
          i++;
          if (i + 1 < pattern.length && pattern[i + 1] == '/') {
            i++;
            out.write(r'(?:.*/)?');
          } else {
            out.write('.*');
          }
        } else {
          out.write(r'[^/]*');
        }
      } else if (char == '?') {
        out.write(r'[^/]');
      } else if (char == '[') {
        final close = pattern.indexOf(']', i + 1);
        if (close > i + 1) {
          var content = pattern.substring(i + 1, close);
          if (content.startsWith('!')) content = '^${content.substring(1)}';
          out.write('[$content]');
          i = close;
        } else {
          out.write(r'\[');
        }
      } else if (char == '\\' && i + 1 < pattern.length) {
        out.write(RegExp.escape(pattern[++i]));
      } else {
        out.write(RegExp.escape(char));
      }
    }
    out.write(descendants ? r'(?:/.*)?$' : r'$');
    return out.toString();
  }
}
