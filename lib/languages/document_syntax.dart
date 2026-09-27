import 'language_registry.dart';

/// Per-editor cache of line tokens and continuation states. Scrolling into the
/// middle of a region scans the preceding lines once. Edits invalidate the
/// changed suffix; changing document or language clears the cache entirely.
class DocumentSyntax {
  Object? _source;
  LanguageDefinition? _language;
  int _revision = -1;
  final _text = <String>[];
  final _lines = <SyntaxLine>[];

  List<SyntaxToken> tokensFor({
    required Object source,
    required int revision,
    required LanguageDefinition? language,
    required int lineCount,
    required String Function(int) readLine,
    required int line,
  }) {
    if (source != _source || language != _language) {
      _source = source;
      _language = language;
      _text.clear();
      _lines.clear();
      _revision = -1;
    }
    if (language == null) return const [];
    if (revision != _revision) {
      var common = 0;
      while (common < _text.length &&
          common < lineCount &&
          _text[common] == readLine(common)) {
        common++;
      }
      _text.length = common;
      _lines.length = common;
      _revision = revision;
    }
    while (_lines.length <= line) {
      final raw = readLine(_lines.length);
      final result = language.tokenizeLine(raw, _lines.lastOrNull?.state);
      _text.add(raw);
      _lines.add(result);
    }
    return _lines[line].tokens;
  }
}
