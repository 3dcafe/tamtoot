import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:tamtoot/core/persistence/schema.dart';
import 'package:tamtoot/languages/language_registry.dart';
import 'package:tamtoot/languages/document_syntax.dart';

LanguageDefinition loadLanguage(String id) {
  final base = 'assets/languages/$id';
  return LanguagePackageLoader().load(
    File('$base/language.json').readAsStringSync(),
    File('$base/syntax.json').readAsStringSync(),
    snippets: File('$base/snippets.json').readAsStringSync(),
  );
}

String? scopeAt(LanguageDefinition language, String source, String needle) {
  final offset = source.indexOf(needle);
  expect(offset, greaterThanOrEqualTo(0));
  return language
      .tokenize(source)
      .where((t) => t.start <= offset && t.end >= offset + needle.length)
      .firstOrNull
      ?.scope;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('all language packages are bundled in application assets', () async {
    for (final id in bundledLanguageIds) {
      final base = 'assets/languages/$id';
      final language = LanguagePackageLoader().load(
        await rootBundle.loadString('$base/language.json'),
        await rootBundle.loadString('$base/syntax.json'),
        snippets: await rootBundle.loadString('$base/snippets.json'),
      );
      expect(language.id, id);
    }
  });
  test('all packages load; extensions recognize case and Windows paths', () {
    final registry = LanguageRegistry();
    for (final id in bundledLanguageIds) {
      final language = loadLanguage(id);
      expect(language.rules, isNotEmpty);
      registry.register(language);
    }
    for (final path in ['page.html', 'PAGE.HTM']) {
      expect(registry.forPath(path)?.id, 'html');
    }
    for (final path in [
      'main.js',
      'main.mjs',
      'main.cjs',
      r'C:\project\INDEX.JS',
    ]) {
      expect(registry.forPath(path)?.id, 'javascript');
    }
    expect(registry.forPath('main.DART')?.id, 'dart');
    expect(registry.forPath('Program.CS')?.id, 'csharp');
    expect(registry.forPath('script.js.txt'), isNull);
    expect(registry.forPath(r'C:\project\Index.CSHTML')?.id, 'razor');
    expect(registry.forPath('Component.razor')?.id, 'razor');
    expect(registry.forPath('site.CSS')?.id, 'css');
    expect(registry.forPath('App.CSPROJ')?.id, 'xml');
  });
  test('Dart recognizes modern declarations, annotations, numbers and calls', () {
    final language = loadLanguage('dart');
    const source =
        '@override base class Example { final int count = 0xFF; double n = 1.5e-3; run(); }';
    for (final word in ['base', 'class', 'final']) {
      expect(scopeAt(language, source, word), 'keyword');
    }
    expect(scopeAt(language, source, '@override'), 'annotation');
    expect(scopeAt(language, source, 'int'), 'type');
    expect(scopeAt(language, source, '0xFF'), 'number');
    expect(scopeAt(language, source, '1.5e-3'), 'number');
    expect(scopeAt(language, source, 'run'), 'function');
    expect(
      scopeAt(language, 'final classification = 2;', 'classification'),
      'foreground',
    );
  });
  test(
    'Dart multiline strings and nested comments preserve and release state',
    () {
      final language = loadLanguage('dart');
      var result = language.tokenizeLine('/* outer');
      result = language.tokenizeLine('/* inner */ still outer', result.state);
      expect(result.tokens.single.scope, 'comment');
      expect(result.state, isNotNull);
      result = language.tokenizeLine('*/ final x = 1;', result.state);
      expect(result.state, isNull);
      expect(result.tokens.any((t) => t.scope == 'keyword'), isTrue);
      result = language.tokenizeLine('final text = r"""hello');
      result = language.tokenizeLine('// not a comment', result.state);
      expect(result.tokens.single.scope, 'string');
      result = language.tokenizeLine('world"""; return;', result.state);
      expect(result.state, isNull);
      expect(result.tokens.any((t) => t.scope == 'keyword'), isTrue);
    },
  );
  test('C# contextual words, escaped identifiers, literals and directives', () {
    final language = loadLanguage('csharp');
    for (final word in [
      'required',
      'init',
      'file',
      'scoped',
      'with',
      'when',
      'where',
      'yield',
      'field',
    ]) {
      expect(scopeAt(language, '$word value;', word), 'keyword');
    }
    expect(
      scopeAt(language, 'int @class = 0b1010_0011UL;', '@class'),
      'foreground',
    );
    expect(
      scopeAt(language, 'int @class = 0b1010_0011UL;', '0b1010_0011UL'),
      'number',
    );
    expect(scopeAt(language, 'var price = 12.50m;', '12.50m'), 'number');
    expect(scopeAt(language, '#nullable enable', '#nullable'), 'directive');
    expect(
      scopeAt(language, '[Obsolete("old")] public void Run() {}', '[Obsolete'),
      'annotation',
    );
  });
  test(
    'C# verbatim and variable-delimiter raw strings continue across lines',
    () {
      final language = loadLanguage('csharp');
      var result = language.tokenizeLine('var path = @"a ""quoted""');
      result = language.tokenizeLine('value"; return;', result.state);
      expect(result.state, isNull);
      expect(result.tokens.first.scope, 'string');
      result = language.tokenizeLine(r'var text = $$""""');
      result = language.tokenizeLine(
        '""" is content // not comment',
        result.state,
      );
      expect(result.state, isNotNull);
      expect(result.tokens.single.scope, 'string');
      result = language.tokenizeLine('""""; return;', result.state);
      expect(result.state, isNull);
      expect(result.tokens.any((t) => t.scope == 'keyword'), isTrue);
    },
  );
  test('JavaScript modules, numbers, regex and division', () {
    final language = loadLanguage('javascript');
    const source =
        'export async function run() { const n = 0xFFn + 1_000; return await Promise.resolve(n); }';
    for (final word in [
      'export',
      'async',
      'function',
      'const',
      'return',
      'await',
    ]) {
      expect(scopeAt(language, source, word), 'keyword');
    }
    expect(scopeAt(language, source, '0xFFn'), 'number');
    expect(scopeAt(language, source, '1_000'), 'number');
    expect(scopeAt(language, 'const re = /a[b/]+/gi;', '/a[b/]+/gi'), 'string');
    expect(scopeAt(language, 'const ratio = a / b / c;', '/'), 'operator');
    expect(scopeAt(language, 'const \$return = 1;', '\$return'), 'foreground');
  });
  test('JavaScript templates and comments retain state on later lines', () {
    final language = loadLanguage('javascript');
    var result = language.tokenizeLine('const text = `hello');
    result = language.tokenizeLine(
      r'world ${value} \` still text',
      result.state,
    );
    expect(result.tokens.single.scope, 'string');
    expect(result.state, isNotNull);
    result = language.tokenizeLine('`; const count = 1;', result.state);
    expect(result.state, isNull);
    expect(result.tokens.any((t) => t.scope == 'keyword'), isTrue);
    expect(language.tokenize('// const x = "text"').single.scope, 'comment');
  });
  test('HTML tags, attributes and quoted > respect tag boundaries', () {
    final language = loadLanguage('html');
    const source = '<div data-title="a > b" disabled>&amp; text</div>';
    expect(scopeAt(language, source, '<div'), 'tag');
    expect(scopeAt(language, source, 'data-title'), 'attribute');
    expect(scopeAt(language, source, '"a > b"'), 'string');
    expect(scopeAt(language, source, 'disabled'), 'attribute');
    expect(scopeAt(language, source, '&amp;'), 'constant');
    expect(scopeAt(language, source, 'text'), isNull);
    expect(language.tokenize('It\'s plain "text" with x=y > 2.'), isEmpty);
    var result = language.tokenizeLine('<input title="first');
    result = language.tokenizeLine('second > value"', result.state);
    expect(result.tokens.single.scope, 'string');
    expect(result.state, isNotNull);
    result = language.tokenizeLine('disabled>plain', result.state);
    expect(result.state, isNull);
    expect(result.tokens.first.scope, 'attribute');
    result = language.tokenizeLine('<!-- comment');
    result = language.tokenizeLine('<div>not a tag', result.state);
    expect(result.tokens.single.scope, 'comment');
    result = language.tokenizeLine('--><p>ok</p>', result.state);
    expect(result.state, isNull);
    expect(result.tokens.any((t) => t.scope == 'tag'), isTrue);
  });
  test(
    'viewport cache includes preceding state and invalidates on edits and language switch',
    () {
      final cache = DocumentSyntax(), source = Object();
      final dart = loadLanguage('dart'), html = loadLanguage('html');
      var lines = ['/* open', 'inside', '*/ final x = 1;'];
      List<SyntaxToken> tokens(
        int line,
        int revision, [
        LanguageDefinition? language,
      ]) => cache.tokensFor(
        source: source,
        revision: revision,
        language: language ?? dart,
        lineCount: lines.length,
        readLine: (i) => lines[i],
        line: line,
      );
      expect(tokens(1, 0).single.scope, 'comment');
      expect(tokens(2, 0).any((t) => t.scope == 'keyword'), isTrue);
      lines[0] = '// closed';
      expect(tokens(1, 1).single.scope, 'foreground');
      lines = ['<div title="a', 'b">hello</div>'];
      expect(tokens(1, 2, html).first.scope, 'string');
      expect(tokens(1, 2, dart).first.scope, isNot('string'));
    },
  );
  test(
    'loader rejects invalid region options while keeping v1 pattern packages',
    () {
      const manifest =
          '{"schemaVersion":1,"packageVersion":"1","id":"test","name":"Test","extensions":[]}';
      for (final rule in [
        {'begin': '/\\*', 'scope': 'comment'},
        {'begin': '("+)', 'endCapture': 2, 'scope': 'string'},
        {'begin': 'x', 'end': '', 'scope': 'string'},
        {'pattern': 'x', 'end': 'y', 'scope': 'string'},
        {'begin': 'x', 'end': 'y', 'contentRules': 'wrong', 'scope': 'string'},
      ]) {
        expect(
          () => LanguagePackageLoader().load(
            manifest,
            jsonEncode({
              'schemaVersion': 1,
              'rules': [rule],
            }),
          ),
          throwsA(isA<SchemaException>()),
        );
      }
      expect(
        LanguagePackageLoader()
            .load(
              manifest,
              '{"schemaVersion":1,"rules":[{"pattern":"foo","scope":"keyword"}]}',
            )
            .tokenize('foo')
            .single
            .scope,
        'keyword',
      );
    },
  );
}
