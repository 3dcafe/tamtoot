// Reproducible diagnostic benchmark; timing is reported, never a CI pass limit.
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/languages/document_syntax.dart';
import 'language_syntax_test.dart' show loadLanguage;

void main() {
  test('report language-tokenization and viewport-cache medians', () {
    const count = 5000;
    for (final entry in {
      'csharp':
          '[SerializeField] private Vector3 position = new Vector3(1f, 2f, 3f);',
      'shader':
          'float4 frag(float2 uv : TEXCOORD0) : SV_Target { return float4(uv, 0, 1); }',
      'yaml': '  m_LocalPosition: {x: 0, y: 1, z: 0}',
      'json': '  "references": ["Game.Runtime", "Unity.InputSystem"],',
      'cpp':
          'volatile uint32_t* reg = reinterpret_cast<volatile uint32_t*>(0x40000000);',
      'aarch64': '    mrs x0, SCTLR_EL1 // system register',
    }.entries) {
      final language = loadLanguage(entry.key);
      for (var i = 0; i < 200; i++) {
        language.tokenizeLine(entry.value);
      }
      final cold = <int>[], warm = <int>[], edit = <int>[];
      var checksum = 0;
      for (var trial = 0; trial < 5; trial++) {
        final cache = DocumentSyntax(), source = Object();
        var revision = 0;
        List<Object> read(int line) => cache.tokensFor(
          source: source,
          revision: revision,
          language: language,
          lineCount: count,
          readLine: (_) => entry.value,
          line: line,
          firstChangedLineSince: (_) => count - 1,
        );
        final timer = Stopwatch()..start();
        checksum += read(count - 1).length;
        cold.add(timer.elapsedMicroseconds);
        timer.reset();
        for (var frame = 0; frame < 100; frame++) {
          for (var line = count - 60; line < count; line++) {
            checksum += read(line).length;
          }
        }
        warm.add(timer.elapsedMicroseconds);
        timer.reset();
        for (var i = 0; i < 100; i++) {
          revision++;
          checksum += read(count - 1).length;
        }
        edit.add(timer.elapsedMicroseconds);
      }
      int median(List<int> values) {
        values.sort();
        return values[2];
      }

      // ignore: avoid_print
      print(
        '${entry.key}: cold5000=${median(cold)}us; cached100x60=${median(warm)}us; lastLine100edits=${median(edit)}us; checksum=$checksum',
      );
      expect(checksum, greaterThan(0));
    }
  }, tags: ['benchmark']);
}
