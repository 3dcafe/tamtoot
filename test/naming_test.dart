import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/naming/naming_diagnostics.dart';
import 'package:tamtoot/core/naming/naming_rules.dart';
import 'package:tamtoot/core/settings/settings.dart';
import 'package:tamtoot/core/persistence/schema.dart';
import 'package:tamtoot/editor/document/editor_controller.dart';
import 'language_syntax_test.dart' show loadLanguage;

void main() {
  test('styles accept private prefixes and reject other styles', () {
    expect(NameStyle.camel.accepts('_someValue'), isTrue);
    expect(NameStyle.camel.accepts('SomeValue'), isFalse);
    expect(NameStyle.pascal.accepts('SomeValue'), isTrue);
    expect(NameStyle.snake.accepts('some_value'), isTrue);
    expect(NameStyle.upperSnake.accepts('SOME_VALUE'), isTrue);
    expect(NameStyle.snake.accepts('someValue'), isFalse);
    expect(NameStyle.camel.accepts('имя'), isTrue);
  });
  test('project profiles persist separately and validate overrides', () {
    final settings = SettingsService();
    final a = Uri.parse('memory:///a/'), b = Uri.parse('memory:///b/');
    settings.set('projectNaming', {
      a.toString(): {
        'enabled': false,
        'languages': {
          'dart': {'variable': 'snake'},
        },
      },
    });
    final restored = SettingsService()..restore(settings.encode());
    expect(NamingProfile.forProject(restored, a, 'dart').enabled, isFalse);
    expect(
      NamingProfile.forProject(restored, a, 'dart').rules[NameKind.variable],
      NameStyle.snake,
    );
    expect(NamingProfile.forProject(restored, b, 'dart').enabled, isTrue);
    expect(
      NamingProfile.forProject(restored, b, 'dart').rules[NameKind.variable],
      NameStyle.camel,
    );
    expect(
      () => settings.set('projectNaming', {
        'x': {
          'languages': {
            'dart': {'variable': 'wrong'},
          },
        },
      }),
      throwsA(isA<SchemaException>()),
    );
  });
  test(
    'Dart diagnostics target declarations, comments/strings/overrides excluded',
    () {
      const source = '''class bad_type {
  final String Bad_Name = 'class fake_name';
  String get bad_property => '';
  void Bad_Method(String Bad_Method) {}
  void goodMethod() {
    return Bad_Call();
  }
  @override
  // override comment

  void Inherited_Name() {}
  // const BAD_CONSTANT = 1;
  const BadConstant = 1;
}
class café {}''';
      final editor = EditorController(source);
      addTearDown(editor.dispose);
      final result = NamingDiagnostics().analyze(
        editor,
        loadLanguage('dart'),
        NamingProfile.defaults('dart'),
      );
      expect(result.map((d) => source.substring(d.start, d.end)), [
        'bad_type',
        'Bad_Name',
        'bad_property',
        'Bad_Method',
        'BadConstant',
      ]);
      expect(result.every((d) => d.kind == 'naming'), isTrue);
    },
  );
  test('language profiles check C#, Python, PHP, Java, Kotlin and JS/TS', () {
    final sources = {
      'csharp':
          'class bad_type {\n private int _goodName = 1;\n private static int s_goodName = 1;\n public int badProperty { get; set; }\n public void badMethod() {}\n}',
      'python':
          'class bad_type:\n  def badMethod(self):\n    badVariable = 1\n  def __init__(self):\n    pass',
      'php':
          '<?php\nclass bad_type {\n public function Bad_method() {}\n const badConstant = 1;\n}',
      'java':
          'class bad_type {\n static final int badConstant = 1;\n void BadMethod() {}\n}',
      'kotlin':
          'class bad_type {\n const val badConstant = 1\n fun Bad_method() {}\n}',
      'javascript':
          'class bad_type {}\nfunction GoodComponent() {}\nfunction bad_method() {}\nconst goodValue = 1;\nconst GOOD_VALUE = 1;',
      'typescript':
          'class bad_type {}\nfunction GoodComponent() {}\nfunction bad_method() {}\nconst goodValue = 1;\nconst GOOD_VALUE = 1;',
    };
    for (final entry in sources.entries) {
      final editor = EditorController(entry.value);
      addTearDown(editor.dispose);
      final names = NamingDiagnostics()
          .analyze(
            editor,
            loadLanguage(entry.key),
            NamingProfile.defaults(entry.key),
          )
          .map((d) => entry.value.substring(d.start, d.end))
          .toList();
      expect(names, contains('bad_type'), reason: entry.key);
      expect(names.length, greaterThanOrEqualTo(2), reason: entry.key);
      expect(names, isNot(contains('GoodComponent')), reason: entry.key);
      expect(names, isNot(contains('s_goodName')), reason: entry.key);
      expect(names, isNot(contains('__init__')), reason: entry.key);
    }
  });
  test(
    'incremental diagnostics converge and style changes reuse parsed names',
    () {
      final editor = EditorController(
        List.generate(10000, (i) => 'final goodName$i = $i;').join('\n'),
      );
      addTearDown(editor.dispose);
      final language = loadLanguage('dart');
      final analyzer = NamingDiagnostics();
      expect(
        analyzer.analyze(editor, language, NamingProfile.defaults('dart')),
        isEmpty,
      );
      final count = analyzer.linesParsed;
      final position = editor.text.indexOf('goodName5000');
      editor.select(position, position + 'goodName5000'.length);
      editor.replaceSelection('Bad_Name');
      final result = analyzer.analyze(
        editor,
        language,
        NamingProfile.defaults('dart'),
      );
      expect(result.length, 1);
      expect(analyzer.linesParsed - count, 1);
      final permissive = NamingProfile(
        rules: {for (final kind in NameKind.values) kind: NameStyle.any},
      );
      expect(analyzer.analyze(editor, language, permissive), isEmpty);
      expect(analyzer.linesParsed - count, 1);
      editor.undo();
      expect(
        analyzer.analyze(editor, language, NamingProfile.defaults('dart')),
        isEmpty,
      );
    },
  );
}
