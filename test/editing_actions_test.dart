import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/editor/document/editor_controller.dart';
import 'package:tamtoot/editor/document/editing_actions.dart';
import 'language_syntax_test.dart' show loadLanguage;

void main() {
  test('pairs wrap backwards selections and undo/redo preserve the cursor', () {
    final e = EditorController('value'), actions = EditingActions();
    addTearDown(e.dispose);
    e.select(5, 0);
    actions.type(e, loadLanguage('dart'), '(');
    expect(e.text, '(value)');
    expect([e.selection.anchor, e.selection.extent], [6, 1]);
    e.undo();
    expect(e.text, 'value');
    expect([e.selection.anchor, e.selection.extent], [5, 0]);
    e.redo();
    expect(e.selection.extent, 1);
  });
  test('closing delimiters skip; paired backspace is a single undo step', () {
    final e = EditorController(''), actions = EditingActions();
    addTearDown(e.dispose);
    final language = loadLanguage('python');
    actions.type(e, language, '(');
    expect(e.text, '()');
    expect(e.selection.extent, 1);
    actions.type(e, language, ')');
    expect(e.text, '()');
    expect(e.selection.extent, 2);
    e.select(1, 1);
    actions.backspace(e, language);
    expect(e.text, '');
    e.undo();
    expect(e.text, '()');
    expect(e.selection.extent, 1);
  });
  test('strings, comments and paste do not insert extra delimiters', () {
    final actions = EditingActions(), language = loadLanguage('dart');
    for (final source in ['// text', '"text', '/* comment\ninside']) {
      final e = EditorController(source);
      addTearDown(e.dispose);
      e.select(e.buffer.length, e.buffer.length);
      actions.type(e, language, '(');
      expect(e.text, '$source(');
    }
    final e = EditorController('');
    addTearDown(e.dispose);
    actions.type(e, language, 'call(\n');
    expect(e.text, 'call(\n');
  });
  test('multiline strings and escaped quotes remain literal', () {
    final actions = EditingActions();
    final e = EditorController('"""text\ninside');
    addTearDown(e.dispose);
    e.select(e.buffer.length, e.buffer.length);
    actions.type(e, loadLanguage('python'), '(');
    expect(e.text, '"""text\ninside(');
    final quoted = EditorController(r'"\"');
    addTearDown(quoted.dispose);
    quoted.select(2, 2);
    actions.type(quoted, loadLanguage('dart'), '"');
    expect(quoted.text, r'"\""');
    expect(quoted.selection.extent, 3);
  });
  test('Enter splits brace pairs and retains configured tab indentation', () {
    final e = EditorController('  {}'), actions = EditingActions();
    addTearDown(e.dispose);
    e.select(3, 3);
    actions.newline(e, loadLanguage('java'));
    expect(e.text, '  {\n    \n  }');
    expect(e.selection.extent, 8);
    e.undo();
    expect(e.text, '  {}');
    expect(e.selection.extent, 3);
    final python = EditorController('\tif ready:')..insertSpaces = false;
    addTearDown(python.dispose);
    python.select(python.buffer.length, python.buffer.length);
    actions.newline(python, loadLanguage('python'));
    expect(python.text, '\tif ready:\n\t\t');
  });
  test(
    'line comments round-trip indentation and exclude the next selected line',
    () {
      final e = EditorController('  first\n    second\nthird'),
          actions = EditingActions();
      addTearDown(e.dispose);
      e.select(0, 19);
      actions.toggleComment(e, loadLanguage('python'));
      expect(e.text, '  # first\n  #   second\nthird');
      actions.toggleComment(e, loadLanguage('python'));
      expect(e.text, '  first\n    second\nthird');
      e.undo();
      expect(e.text, '  # first\n  #   second\nthird');
    },
  );
  test(
    'HTML block comments toggle and read-only actions leave text intact',
    () {
      final e = EditorController('<div>hello</div>'),
          actions = EditingActions();
      addTearDown(e.dispose);
      actions.toggleComment(e, loadLanguage('html'));
      expect(e.text, '<!--\n<div>hello</div>\n-->');
      actions.toggleComment(e, loadLanguage('html'));
      expect(e.text, '<div>hello</div>');
      e.readOnly = true;
      actions.type(e, loadLanguage('html'), '"');
      actions.newline(e, loadLanguage('html'));
      actions.toggleComment(e, loadLanguage('html'));
      expect(e.text, '<div>hello</div>');
    },
  );
}
