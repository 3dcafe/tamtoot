import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/languages/language_registry.dart';
import 'language_syntax_test.dart' show loadLanguage, scopeAt;

void main() {
  test(
    'JSON is bundled and recognizes configuration files across platforms',
    () {
      expect(bundledLanguageIds, contains('json'));
      final json = loadLanguage('json');
      final registry = LanguageRegistry()..register(json);
      for (final path in [
        'package.json',
        '/project/settings.json',
        r'C:\project\config.JSON',
      ]) {
        expect(registry.forPath(path)?.id, 'json');
      }
      expect(json.comments, isEmpty);
      for (final template in json.fileTemplates.values) {
        expect(
          () => jsonDecode((template as Map)['body'] as String),
          returnsNormally,
        );
      }
    },
  );
  test(
    'JSON distinguishes property names, strings, literals and punctuation',
    () {
      final json = loadLanguage('json');
      expect(scopeAt(json, '{"name": "value"}', '"name"'), 'property');
      expect(scopeAt(json, '{"name": "value"}', '"value"'), 'string');
      expect(scopeAt(json, '{"имя": "значение"}', '"имя"'), 'property');
      expect(scopeAt(json, r'{"a\"b": "hello\"world"}', r'"a\"b"'), 'property');
      expect(
        scopeAt(json, r'{"a\"b": "hello\"world"}', r'hello\"world'),
        'string',
      );
      expect(
        scopeAt(
          json,
          '{"url": "https://example.com/#part"}',
          '//example.com/#part',
        ),
        'string',
      );
      for (final value in ['true', 'false', 'null']) {
        expect(scopeAt(json, '[$value]', value), 'constant');
        expect(scopeAt(json, '["$value"]', '"$value"'), 'string');
      }
      for (final value in ['0', '-12', '3.14', '1e10', '-2.5E-3']) {
        expect(scopeAt(json, '[$value]', value), 'number');
      }
      expect(scopeAt(json, '[1, 2]', ','), 'operator');
    },
  );
  test('an unfinished JSON string does not color subsequent properties', () {
    final json = loadLanguage('json');
    final unfinished = json.tokenizeLine('"unfinished');
    final next = json.tokenizeLine('"next": false', unfinished.state);
    expect(next.tokens.any((token) => token.scope == 'property'), true);
    expect(next.tokens.any((token) => token.scope == 'constant'), true);
  });
}
