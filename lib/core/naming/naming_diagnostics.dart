import '../../editor/buffer/text_buffer.dart';
import '../../editor/document/editor_controller.dart';
import '../../languages/language_registry.dart';
import 'naming_rules.dart';

typedef _Name = ({int start, int end, String name, NameKind kind});

class _Line {
  _Line(this.state, this.override, this.names);
  final SyntaxState? state;
  final bool override;
  final List<_Name> names;
}

/// Declaration-only lexical advice. Unknown syntax and non-ASCII names are
/// left alone; this is independent from compiler diagnostics.
class NamingDiagnostics {
  EditorController? _document;
  LanguageDefinition? _language;
  int _revision = -1;
  List<_Line> _lines = [];
  int linesParsed = 0;
  bool _same(SyntaxState? a, SyntaxState? b) =>
      identical(a, b) ||
      a != null &&
          b != null &&
          identical(a.rule, b.rule) &&
          a.depth == b.depth &&
          a.end.pattern == b.end.pattern &&
          _same(a.parent, b.parent);

  List<Decoration> analyze(
    EditorController document,
    LanguageDefinition? language,
    NamingProfile profile,
  ) {
    if (language == null ||
        !profile.enabled ||
        !NamingProfile.languages.containsKey(language.id)) {
      return [];
    }
    final same =
        identical(document, _document) && identical(language, _language);
    final range = same
        ? document.changedLinesSince(_revision)
        : (first: 0, last: document.buffer.lineCount - 1);
    final old = same ? _lines : <_Line>[];
    final first = range.first.clamp(0, old.length);
    final next = old.take(first).toList();
    var state = first > 0 ? old[first - 1].state : null;
    var override = first > 0 && old[first - 1].override;
    for (var line = first; line < document.buffer.lineCount; line++) {
      if (line > range.last &&
          old.length == document.buffer.lineCount &&
          _same(state, old[line - 1].state) &&
          override == old[line - 1].override) {
        next.addAll(old.skip(line));
        break;
      }
      final raw = document.buffer.getLine(line);
      final syntax = language.tokenizeLine(raw, state);
      state = syntax.state;
      final chars = raw.split('');
      for (final token in syntax.tokens.where(
        (t) =>
            t.scope == 'comment' ||
            t.scope == 'string' ||
            t.scope.startsWith('string.'),
      )) {
        for (var i = token.start; i < token.end && i < chars.length; i++) {
          chars[i] = ' ';
        }
      }
      final code = chars.join();
      final names = _declarations(code, language.id, override);
      if (code.trim().isNotEmpty) {
        override = code.trim() == '@override' || code.trim() == '@Override';
      }
      next.add(_Line(state, override, names));
      linesParsed++;
    }
    _document = document;
    _language = language;
    _revision = document.revision;
    _lines = next;
    final result = <Decoration>[];
    for (var line = 0; line < next.length; line++) {
      final start = document.buffer.offsetAt(TextPoint(line, 0));
      for (final name in next[line].names) {
        final style = profile.rules[name.kind]!;
        final checked =
            language.id == 'csharp' &&
                name.kind == NameKind.variable &&
                RegExp(r'^([st])_').hasMatch(name.name)
            ? name.name.substring(2)
            : name.name;
        if (!style.accepts(checked)) {
          result.add(
            Decoration(
              start + name.start,
              start + name.end,
              'naming',
              message: '${name.kind.name}: use ${style.label} for ${name.name}',
            ),
          );
        }
      }
    }
    result.sort((a, b) => a.start.compareTo(b.start));
    return result;
  }

  List<_Name> _declarations(String line, String language, bool override) {
    final result = <_Name>[];
    if (RegExp(
      r'^\s*(?:return|throw|await|yield|new|import|using|package)\b',
    ).hasMatch(line)) {
      return result;
    }
    void add(RegExpMatch? match, int group, NameKind kind) {
      if (match == null) return;
      final name = match.group(group)!;
      if (name == '_' || name.startsWith('__') && name.endsWith('__')) return;
      final functionName = kind == NameKind.function
          ? RegExp(
              '${RegExp.escape(name)}'
              r'(?:<[^>]+>)?\s*\(',
            ).firstMatch(match.group(0)!)
          : null;
      final start =
          match.start +
          (functionName?.start ?? match.group(0)!.lastIndexOf(name));
      if (start + name.length < line.length &&
          line.codeUnitAt(start + name.length) > 127) {
        return;
      }
      result.add((
        start: start,
        end: start + name.length,
        name: name,
        kind: kind,
      ));
    }

    final type = RegExp(
      r'\b(?:class|interface|enum|struct|record|mixin|object|type)\s+([A-Za-z_$][\w$]*)',
    ).firstMatch(line);
    add(type, 1, NameKind.type);
    if (type != null) return result;
    if (override || RegExp(r'\boverride\b').hasMatch(line)) return result;
    RegExpMatch? method;
    var group = 1;
    if (language == 'python') {
      method = RegExp(
        r'^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\(',
      ).firstMatch(line);
    } else if (language == 'kotlin') {
      method = RegExp(
        r'\bfun\s+(?:<[^>]+>\s*)?([A-Za-z_]\w*)\s*\(',
      ).firstMatch(line);
    } else if (language == 'javascript' ||
        language == 'typescript' ||
        language == 'php') {
      method = RegExp(
        r'\bfunction\s+([A-Za-z_$][\w$]*)\s*(?:<[^>]+>)?\(',
      ).firstMatch(line);
      method ??= RegExp(
        r'^\s*(?:(?:public|private|protected|static|async|export|default)\s+)*([A-Za-z_$][\w$]*)\s*\([^;]*\)\s*(?::[^={]+)?\s*\{',
      ).firstMatch(line);
    } else {
      method = RegExp(
        r'^\s*(?:(?:public|private|protected|internal|static|virtual|abstract|external|async|final)\s+)*(?:[\w<>,.?\[\]]+\s+)+([A-Za-z_][\w]*)(?:<[^()]+>)?\s*\(',
      ).firstMatch(line);
    }
    if (method != null &&
        !{
          'if',
          'for',
          'while',
          'switch',
          'catch',
          'return',
          'throw',
          'new',
          'await',
        }.contains(method.group(group))) {
      add(method, group, NameKind.function);
      return result;
    }
    if (language == 'python') {
      final variable = RegExp(
        r'^\s*([A-Za-z_]\w*)\s*(?::[^=]+)?=(?!=)',
      ).firstMatch(line);
      final name = variable?.group(1) ?? '';
      add(
        variable,
        1,
        name.isNotEmpty && name == name.toUpperCase()
            ? NameKind.constant
            : NameKind.variable,
      );
    } else if (language == 'php') {
      final constant = RegExp(
        r'\bconst\s+(?:[\w?]+\s+)?([A-Za-z_]\w*)\s*=',
      ).firstMatch(line);
      if (constant != null) {
        add(constant, 1, NameKind.constant);
      } else {
        add(
          RegExp(
            r'^\s*(?:(?:public|private|protected|static|readonly|[\w?]+)\s+)*(\$[A-Za-z_]\w*)\s*=',
          ).firstMatch(line),
          1,
          NameKind.variable,
        );
      }
    } else if (language == 'kotlin' ||
        language == 'javascript' ||
        language == 'typescript') {
      final variable = RegExp(
        r'\b(val|var|const|let)\s+([A-Za-z_$][\w$]*)',
      ).firstMatch(line);
      final constant = language == 'kotlin'
          ? RegExp(r'\bconst\s+val\b').hasMatch(line)
          : variable?.group(1) == 'const';
      add(variable, 2, constant ? NameKind.constant : NameKind.variable);
    } else {
      final variable = RegExp(
        r'^\s*(?:(?:public|private|protected|internal|static|late|readonly|final|required)\s+)*(?:[\w<>,.?\[\]]+\s+)(?:[\w<>,.?\[\]]+\s+)?([@A-Za-z_]\w*)\s*(?:=|;|\{[^}]*\bget\b|=>)',
      ).firstMatch(line);
      final constant =
          RegExp(r'\bconst\b').hasMatch(line) ||
          language == 'java' && RegExp(r'\bstatic\s+final\b').hasMatch(line);
      final property =
          RegExp(r'\bget\s+\w+|\{[^}]*\bget\b').hasMatch(line) ||
          language == 'csharp' &&
              RegExp(r'\b(?:public|protected)\b').hasMatch(line);
      add(
        variable,
        1,
        constant
            ? NameKind.constant
            : property
            ? NameKind.property
            : NameKind.variable,
      );
    }
    return result;
  }
}
