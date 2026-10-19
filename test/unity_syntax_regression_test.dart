import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/languages/document_syntax.dart';
import 'package:tamtoot/languages/language_registry.dart';
import 'language_syntax_test.dart' show loadLanguage;

List<(int, int, String)> signature(List<SyntaxToken> tokens) =>
    tokens.map((t) => (t.start, t.end, t.scope)).toList();

void main() {
  for (final id in [
    'csharp',
    'shader',
    'yaml',
    'json',
    'cpp',
    'arm',
    'aarch64',
    'linker',
  ]) {
    test(
      '$id cached edits, line insertion, deletion and restored contents match full parsing',
      () {
        final language = loadLanguage(id);
        final cache = DocumentSyntax();
        final source = Object();
        var revision = 0, changed = 0, reads = 0;
        var lines = [
          'float value = 1;',
          '/* region',
          'float4 color;',
          '*/',
          'return value;',
        ];
        List<SyntaxToken> cached(int line) => cache.tokensFor(
          source: source,
          revision: revision,
          language: language,
          lineCount: lines.length,
          readLine: (i) {
            reads++;
            return lines[i];
          },
          line: line,
          firstChangedLineSince: (_) => changed,
        );
        void compare() {
          SyntaxState? state;
          for (var i = 0; i < lines.length; i++) {
            final full = language.tokenizeLine(lines[i], state);
            expect(
              signature(cached(i)),
              signature(full.tokens),
              reason: '$id line $i revision $revision',
            );
            state = full.state;
          }
          reads = 0;
          final first = cached(lines.length - 1);
          expect(identical(first, cached(lines.length - 1)), true);
          expect(
            reads,
            0,
            reason: 'unchanged repaint must not read the buffer',
          );
        }

        compare();
        final original = [...lines];
        changed = 1;
        revision++;
        lines[1] = '// region removed';
        compare();
        changed = 1;
        revision++;
        lines = [...original];
        compare();
        changed = 2;
        revision++;
        lines.insert(2, '"/* literal */"');
        compare();
        changed = 1;
        revision++;
        lines.removeRange(1, 4);
        compare();
        changed = 0;
        revision++;
        lines = [''];
        compare();
      },
    );
    test('$id last-line edit in 10000 lines reads only one line', () {
      final language = loadLanguage(id), cache = DocumentSyntax();
      final source = Object();
      var revision = 0, reads = 0;
      var last = 'float value = 1;';
      List<SyntaxToken> read() => cache.tokensFor(
        source: source,
        revision: revision,
        language: language,
        lineCount: 10000,
        readLine: (i) {
          reads++;
          return i == 9999 ? last : 'float value = 1;';
        },
        line: 9999,
        firstChangedLineSince: (_) => 9999,
      );
      read();
      expect(reads, 10000);
      reads = 0;
      read();
      expect(reads, 0);
      revision++;
      last = '// changed';
      final result = read();
      expect(reads, 1);
      expect(signature(result), signature(language.tokenizeLine(last).tokens));
    });
  }
  test(
    'shader comments, unterminated strings and long near-matches recover',
    () {
      final shader = loadLanguage('shader');
      expect(shader.tokenizeLine('"unterminated').state, isNull);
      final open = shader.tokenizeLine('/* open');
      final closed = shader.tokenizeLine('*/ float4 color;', open.state);
      expect(closed.state, isNull);
      expect(closed.tokens.any((t) => t.scope == 'type'), true);
      final line = 'float4${'x' * 20000};';
      final tokens = shader.tokenizeLine(line).tokens;
      expect(tokens.any((t) => t.scope == 'type'), false);
      for (final t in tokens) {
        expect(t.start, greaterThanOrEqualTo(0));
        expect(t.end, lessThanOrEqualTo(line.length));
        expect(t.end, greaterThan(t.start));
      }
    },
  );
}
