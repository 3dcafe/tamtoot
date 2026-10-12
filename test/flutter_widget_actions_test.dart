import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/editor/document/editor_controller.dart';
import 'package:tamtoot/editor/document/flutter_widget_actions.dart';

const header = "import 'package:flutter/material.dart';\n";
void main() {
  test('transforms keep multiline literals and implicit const', () {
    const literal = "'''first\n  second\nthird'''";
    final editor = EditorController("${header}Text($literal)");
    addTearDown(editor.dispose);
    editor.select(header.length, editor.text.length);
    final actions = FlutterWidgetActions();
    expect(actions.wrap(editor, 'Padding'), isTrue);
    expect(editor.text, contains(literal));
    expect(actions.unwrap(editor), isTrue);
    expect(editor.text, "${header}Text($literal)");
    final constant = EditorController(
      "${header}const Center(child: Text('x'))",
    );
    addTearDown(constant.dispose);
    constant.select(header.length, constant.text.length);
    expect(actions.unwrap(constant), isTrue);
    expect(constant.text, "${header}const Text('x')");
  });
  final actions = FlutterWidgetActions();
  EditorController selected(String text) {
    final editor = EditorController('$header$text');
    editor.select(header.length, editor.text.length);
    addTearDown(editor.dispose);
    return editor;
  }

  test(
    'every wrapper keeps nested strings and is one Undo/Redo transaction',
    () {
      for (final wrapper in FlutterWidgetActions.wrappers) {
        final editor = selected("const Text('a,b)')");
        final original = editor.text;
        expect(actions.wrap(editor, wrapper), isTrue);
        expect(editor.text, contains('$wrapper('));
        expect(editor.text, contains("const Text('a,b)')"));
        expect(
          editor.text,
          contains(
            wrapper == 'Row' || wrapper == 'Column' ? 'children: [' : 'child: ',
          ),
        );
        final wrapped = editor.text;
        expect(actions.unwrap(editor), isTrue);
        expect(editor.text, original);
        editor.undo();
        expect(editor.text, wrapped);
        editor.undo();
        expect(editor.text, original);
        expect(editor.selection.start, header.length);
        editor.redo();
        expect(editor.text, wrapped);
      }
    },
  );
  test('multiline widget preserves nesting, indentation and trailing comma', () {
    final editor = selected("  Container(\n    child: Text('x'),\n  ),")
      ..tabSize = 4;
    expect(actions.wrap(editor, 'Center'), isTrue);
    expect(
      editor.text,
      contains(
        "  Center(\n      child: Container(\n        child: Text('x'),\n      ),\n  ),",
      ),
    );
    expect(actions.unwrap(editor), isTrue);
    expect(editor.text, "$header  Container(\n    child: Text('x'),\n  ),");
  });
  test(
    'unwrap rejects multiple children, spread, variables and incomplete selections',
    () {
      for (final text in [
        "Row(children: [Text('a'), Text('b')])",
        'Column(children: [...items])',
        'Center(child: widget)',
        'Padding(child: Text(',
      ]) {
        expect(actions.canUnwrap(selected(text)), isFalse);
      }
      for (final text in [
        'Text',
        "Text('a');",
        "Text('a'), Text('b')",
        "Text('a'",
      ]) {
        expect(actions.canWrap(selected(text)), isFalse);
      }
    },
  );
  test(
    'read-only, collapsed selection and non-Flutter code stay unchanged',
    () {
      final editor = selected("Text('x')");
      editor.readOnly = true;
      expect(actions.wrap(editor, 'Center'), isFalse);
      editor.readOnly = false;
      editor.select(editor.text.length, editor.text.length);
      expect(actions.wrap(editor, 'Center'), isFalse);
      final plain = EditorController("Text('x')");
      addTearDown(plain.dispose);
      plain.select(0, plain.text.length);
      expect(actions.wrap(plain, 'Center'), isFalse);
    },
  );
  test('triple quotes and comments do not interfere with balancing', () {
    final editor = selected(
      "Container(child: Text('''x ') , ( /* y */'''), /* ) */)",
    );
    expect(actions.wrap(editor, 'Padding'), isTrue);
    editor.undo();
    expect(actions.canWrap(editor), isTrue);
  });
}
