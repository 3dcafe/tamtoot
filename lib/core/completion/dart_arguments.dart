/// Lightweight argument hints. This deliberately does not resolve Dart types.
const flutterNamedArguments = <String, String>{
  'Container':
      'Key? key, AlignmentGeometry? alignment, EdgeInsetsGeometry? padding, Color? color, Decoration? decoration, double? width, double? height, BoxConstraints? constraints, EdgeInsetsGeometry? margin, Matrix4? transform, Widget? child, Clip clipBehavior',
  'Text':
      'Key? key, TextStyle? style, TextAlign? textAlign, TextDirection? textDirection, bool? softWrap, TextOverflow? overflow, int? maxLines, String? semanticsLabel',
  'Row':
      'Key? key, MainAxisAlignment mainAxisAlignment, MainAxisSize mainAxisSize, CrossAxisAlignment crossAxisAlignment, TextDirection? textDirection, VerticalDirection verticalDirection, TextBaseline? textBaseline, List<Widget> children',
  'Column':
      'Key? key, MainAxisAlignment mainAxisAlignment, MainAxisSize mainAxisSize, CrossAxisAlignment crossAxisAlignment, TextDirection? textDirection, VerticalDirection verticalDirection, TextBaseline? textBaseline, List<Widget> children',
  'Padding': 'Key? key, required EdgeInsetsGeometry padding, Widget? child',
  'SizedBox': 'Key? key, double? width, double? height, Widget? child',
  'Center':
      'Key? key, double? widthFactor, double? heightFactor, Widget? child',
  'Expanded': 'Key? key, int flex, required Widget child',
  'Flexible': 'Key? key, int flex, FlexFit fit, required Widget child',
  'Scaffold':
      'Key? key, PreferredSizeWidget? appBar, Widget? body, Widget? floatingActionButton, Widget? drawer, Widget? bottomNavigationBar, Color? backgroundColor, bool? resizeToAvoidBottomInset, bool extendBody, bool extendBodyBehindAppBar',
  'Icon':
      'Key? key, double? size, Color? color, String? semanticLabel, TextDirection? textDirection',
  'FutureBuilder':
      'Key? key, Future<T>? future, T? initialData, required AsyncWidgetBuilder<T> builder',
  'StreamBuilder':
      'Key? key, Stream<T>? stream, T? initialData, required AsyncWidgetBuilder<T> builder',
  'LayoutBuilder': 'Key? key, required LayoutWidgetBuilder builder',
};

bool importsFlutter(String source) =>
    RegExp(r'''\bimport\s+['"]package:flutter/''').hasMatch(source);

/// New UI actions generate unqualified names, so require an unrestricted public
/// Flutter UI import. Prefixed/show/hide imports need semantic import resolution.
bool flutterUiImport(String source, {bool materialOnly = false}) {
  final imports = RegExp(
    r'''^\s*import\s+['"]package:flutter/(material|widgets|cupertino)\.dart['"]([^;]*);''',
    multiLine: true,
  ).allMatches(source);
  return imports.any(
    (m) =>
        (!materialOnly || m.group(1) == 'material') &&
        !RegExp(r'\b(?:as|show|hide)\b').hasMatch(m.group(2)!),
  );
}

/// Returns null outside an argument-name position, including argument values.
({String call, String prefix, Set<String> used, String? parameter})?
dartArgumentContext(String before) {
  // Avoid rescanning an entire large document on every key stroke. Start at a
  // line boundary; incomplete calls outside this window receive no hints.
  var start = before.length > 8192
      ? before.indexOf('\n', before.length - 8192) + 1
      : 0;
  if (start == 0 && before.length > 8192) return null;
  final text = before.substring(start);
  final stack = <({String char, int position})>[];
  String? quote;
  bool lineComment = false, blockComment = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    final next = i + 1 < text.length ? text[i + 1] : '';
    if (lineComment) {
      if (c == '\n') lineComment = false;
      continue;
    }
    if (blockComment) {
      if (c == '*' && next == '/') {
        blockComment = false;
        i++;
      }
      continue;
    }
    if (quote != null) {
      if (c == '\\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '/' && next == '/') {
      lineComment = true;
      i++;
      continue;
    }
    if (c == '/' && next == '*') {
      blockComment = true;
      i++;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }
    if ('([{'.contains(c)) stack.add((char: c, position: i));
    if (')]}'.contains(c)) {
      if (stack.isEmpty || '([{'.indexOf(stack.last.char) != ')]}'.indexOf(c)) {
        return null;
      }
      stack.removeLast();
    }
  }
  if (quote != null ||
      lineComment ||
      blockComment ||
      stack.isEmpty ||
      stack.last.char != '(') {
    return null;
  }
  final opening = stack.last.position;
  final call = RegExp(
    r'([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)?)(?:<[^<>\n]+>)?\s*$',
  ).firstMatch(text.substring(0, opening))?.group(1);
  if (call == null) return null;
  final args = text.substring(opening + 1);
  // The last top-level comma starts the current argument (nested values may
  // contain commas). Quoted values and nested expressions have been closed.
  var depth = 0, lastComma = -1;
  final used = <String>{};
  quote = null;
  for (var i = 0; i < args.length; i++) {
    final c = args[i];
    if (quote != null) {
      if (c == '\\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }
    if ('([{'.contains(c)) depth++;
    if (')]}'.contains(c)) depth--;
    if (c == ',' && depth == 0) {
      final name = RegExp(
        r'^\s*([A-Za-z_$][\w$]*)\s*:',
      ).firstMatch(args.substring(lastComma + 1, i))?.group(1);
      if (name != null) used.add(name);
      lastComma = i;
    }
  }
  final prefix = args.substring(lastComma + 1).trim();
  final value = RegExp(
    r'^([A-Za-z_$][\w$]*)\s*:\s*((?:[A-Za-z_$][\w$]*\.?)*)$',
  ).firstMatch(prefix);
  if (value != null) {
    return (
      call: call,
      prefix: value.group(2)!,
      used: used,
      parameter: value.group(1)!,
    );
  }
  if (!RegExp(r'^[A-Za-z_$][\w$]*$|^$').hasMatch(prefix)) return null;
  return (call: call, prefix: prefix, used: used, parameter: null);
}

Iterable<({String name, String declaration})> dartNamedParameters(
  String parameters,
) sync* {
  final parts = <String>[];
  var depth = 0, start = 0;
  String? quote;
  for (var i = 0; i < parameters.length; i++) {
    final c = parameters[i];
    if (quote != null) {
      if (c == '\\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }
    if ('(<[{'.contains(c)) depth++;
    if (')>]}'.contains(c)) depth--;
    if (c == ',' && depth == 0) {
      parts.add(parameters.substring(start, i));
      start = i + 1;
    }
  }
  parts.add(parameters.substring(start));
  for (final part in parts) {
    final declaration = part.split('=').first.trim();
    final match = RegExp(
      r'(?:^|\s)(?:this\.|super\.)?([A-Za-z_$][\w$]*)$',
    ).firstMatch(declaration);
    if (match != null) yield (name: match.group(1)!, declaration: declaration);
  }
}

/// Declaration headers only; excludes ordinary calls and control statements.
RegExpMatch? dartDeclarationHeader(String line, String owner) {
  final constructor = owner.isEmpty
      ? null
      : RegExp(
          '^(?:(?:const|factory|external)\\s+)*(${RegExp.escape(owner)}(?:\\.[A-Za-z_][\\w]*)?)(<[^()]+>)?\\s*\\(',
        ).firstMatch(line);
  if (constructor != null) return constructor;
  if (RegExp(r'^(?:return|throw|await|yield|new)\b').hasMatch(line)) {
    return null;
  }
  return RegExp(
    r'^(?:(?:static|external|abstract|covariant)\s+)*(?:[\w<>,.?\[\]]+\s+)+([A-Za-z_$][\w$]*)(<[^()]+>)?\s*\(',
  ).firstMatch(line);
}

/// Balances nested callback signatures and defaults without stopping at the
/// first closing parenthesis. Returns -1 for an unfinished declaration.
int dartDeclarationEnd(String text, int opening) {
  var depth = 0;
  String? quote;
  bool blockComment = false, lineComment = false;
  for (var i = opening; i < text.length; i++) {
    final c = text[i];
    final next = i + 1 < text.length ? text[i + 1] : '';
    if (lineComment) {
      if (c == '\n') lineComment = false;
      continue;
    }
    if (blockComment) {
      if (c == '*' && next == '/') {
        blockComment = false;
        i++;
      }
      continue;
    }
    if (quote != null) {
      if (c == '\\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '/' && next == '/') {
      lineComment = true;
      i++;
      continue;
    }
    if (c == '/' && next == '*') {
      blockComment = true;
      i++;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// Removes comments while preserving quoted defaults and line boundaries.
String dartWithoutComments(String text) {
  final result = StringBuffer();
  String? quote;
  var blockDepth = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    final next = i + 1 < text.length ? text[i + 1] : '';
    if (blockDepth > 0) {
      if (c == '/' && next == '*') {
        blockDepth++;
        i++;
      } else if (c == '*' && next == '/') {
        blockDepth--;
        i++;
      } else if (c == '\n') {
        result.write('\n');
      }
      continue;
    }
    if (quote != null) {
      result.write(c);
      if (c == '\\' && i + 1 < text.length) {
        result.write(text[++i]);
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '/' && next == '/') {
      while (i < text.length && text[i] != '\n') {
        i++;
      }
      result.write('\n');
      continue;
    }
    if (c == '/' && next == '*') {
      blockDepth++;
      i++;
      result.write(' ');
      continue;
    }
    if (c == '"' || c == "'") quote = c;
    result.write(c);
  }
  return result.toString();
}

/// A same-length mask lets lexical transforms ignore strings and comments
/// without losing offsets in the original source. Nested comments and triple
/// quotes are included; string interpolation remains inside the string mask.
String dartStructuralMask(String text, {Set<int>? literalLineStarts}) {
  final chars = text.split('');
  String? delimiter;
  var rawString = false;
  var blockDepth = 0;
  var lineComment = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    final next = i + 1 < text.length ? text[i + 1] : '';
    if (lineComment) {
      if (c == '\n') {
        lineComment = false;
      } else {
        chars[i] = ' ';
      }
      continue;
    }
    if (blockDepth > 0) {
      chars[i] = c == '\n' ? '\n' : ' ';
      if (c == '/' && next == '*') {
        blockDepth++;
        chars[++i] = ' ';
      } else if (c == '*' && next == '/') {
        blockDepth--;
        chars[++i] = ' ';
      }
      continue;
    }
    if (delimiter != null) {
      if (c == '\n') literalLineStarts?.add(i + 1);
      if (text.startsWith(delimiter, i)) {
        for (var j = 0; j < delimiter.length; j++) {
          chars[i + j] = ' ';
        }
        i += delimiter.length - 1;
        delimiter = null;
      } else {
        chars[i] = c == '\n' ? '\n' : ' ';
        if (!rawString && c == '\\' && i + 1 < text.length) {
          if (text[i + 1] == '\n') literalLineStarts?.add(i + 2);
          chars[++i] = ' ';
        }
      }
      continue;
    }
    if (c == '/' && next == '/') {
      lineComment = true;
      chars[i] = ' ';
      chars[++i] = ' ';
      continue;
    }
    if (c == '/' && next == '*') {
      blockDepth = 1;
      chars[i] = ' ';
      chars[++i] = ' ';
      continue;
    }
    if (c == '"' || c == "'") {
      rawString = i > 0 && text[i - 1] == 'r';
      delimiter = text.startsWith(c * 3, i) ? c * 3 : c;
      for (var j = 0; j < delimiter.length; j++) {
        chars[i + j] = ' ';
      }
      i += delimiter.length - 1;
    }
  }
  // Unclosed strings/comments cannot be transformed safely.
  if (delimiter != null || blockDepth > 0) return '?' * text.length;
  return chars.join();
}

bool dartBalancedExpression(String mask, int opening) {
  final stack = <String>[];
  for (var i = opening; i < mask.length; i++) {
    final c = mask[i];
    if ('([{'.contains(c)) stack.add(c);
    if (')]}'.contains(c)) {
      if (stack.isEmpty ||
          '([{'.indexOf(stack.removeLast()) != ')]}'.indexOf(c)) {
        return false;
      }
      if (stack.isEmpty && i != mask.length - 1) return false;
    }
  }
  return stack.isEmpty;
}

List<String> dartTopLevelSegments(String text, int start, int end) {
  final mask = dartStructuralMask(text);
  final parts = <String>[];
  var depth = 0, segment = start;
  for (var i = start; i < end; i++) {
    final c = mask[i];
    if ('([{'.contains(c)) depth++;
    if (')]}'.contains(c)) depth--;
    if (c == ',' && depth == 0) {
      parts.add(text.substring(segment, i));
      segment = i + 1;
    }
  }
  parts.add(text.substring(segment, end));
  return parts;
}
