import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/commands/commands.dart';
import 'package:tamtoot/core/persistence/schema.dart';
import 'package:tamtoot/core/settings/settings.dart';
import 'package:tamtoot/core/themes/ide_theme.dart';
import 'package:tamtoot/editor/buffer/text_buffer.dart';
import 'package:tamtoot/editor/document/editor_controller.dart';
import 'package:tamtoot/editor/viewport/editor_viewport.dart';
import 'package:tamtoot/languages/language_registry.dart';
import 'package:tamtoot/languages/package_service.dart';
import 'package:tamtoot/workspace/layout/dock_layout.dart';
import 'support.dart';

void main() {
  group('Text buffer', () {
    test('all offsets round-trip including blank and final lines', () {
      final buffer = IndexedTextBuffer('a\n\nhello 🌍\n');
      expect(buffer.lineCount, 4);
      for (var i = 0; i <= buffer.length; i++) {
        expect(buffer.offsetAt(buffer.positionAt(i)), i);
      }
      expect(buffer.getLine(1), '');
      expect(buffer.getLine(3), '');
    });
    test('normalizes CRLF and clamps positions', () {
      final b = IndexedTextBuffer('a\r\nb');
      expect(b.getText(0, b.length), 'a\nb');
      expect(b.offsetAt(const TextPoint(99, 99)), 3);
      expect(b.positionAt(-1).column, 0);
    });
    test('edits update line index and return deleted text', () {
      final b = IndexedTextBuffer('one\ntwo');
      expect(b.applyEdit(const BufferEdit(3, 4, '\nnew\n')), '\n');
      expect(b.lineCount, 3);
      expect(b.getLine(1), 'new');
      expect(
        () => b.applyEdit(const BufferEdit(99, 100, '')),
        throwsRangeError,
      );
    });
    test('virtualizes 100k lines to viewport + overscan', () {
      final b = IndexedTextBuffer(List.filled(100000, 'line').join('\n'));
      const v = EditorViewport(
        scrollOffset: 500000,
        height: 600,
        lineHeight: 20,
      );
      expect(
        v.endLine(b.lineCount) - v.firstLine(b.lineCount),
        lessThanOrEqualTo(36),
      );
      expect(b.getLine(99999), 'line');
    });
  });
  group('Editor transactions', () {
    late EditorController e;
    setUp(() => e = EditorController('hello\nworld'));
    tearDown(() => e.dispose());
    test('selection replace, undo, redo restore text and cursor', () {
      e.select(0, 5);
      e.replaceSelection('Hi');
      expect(e.text, 'Hi\nworld');
      expect(e.revision, 1);
      e.undo();
      expect(e.text, 'hello\nworld');
      expect(e.selection.end, 5);
      e.redo();
      expect(e.text, 'Hi\nworld');
      expect(e.selection.extent, 2);
    });
    test('batch edits undo atomically', () {
      e.transact([const BufferEdit(0, 5, 'A'), const BufferEdit(6, 11, 'B')]);
      expect(e.text, 'A\nB');
      e.undo();
      expect(e.text, 'hello\nworld');
      e.redo();
      expect(e.text, 'A\nB');
    });
    test('overlapping transactions reject without mutation', () {
      expect(
        () => e.transact([
          const BufferEdit(0, 4, ''),
          const BufferEdit(3, 6, ''),
        ]),
        throwsArgumentError,
      );
      expect(e.text, 'hello\nworld');
    });
    test('new edit invalidates redo', () {
      e.replaceSelection('x');
      e.undo();
      e.replaceSelection('y');
      expect(e.canRedo, false);
    });
    test('read-only rejects edit, delete and undo', () {
      e.replaceSelection('x');
      e.readOnly = true;
      e.replaceSelection('bad');
      e.delete();
      e.undo();
      expect(e.text, 'xhello\nworld');
    });
    test('move and extend selection across lines', () {
      e.select(3, 3);
      e.move('down', extend: true);
      expect(e.selection.anchor, 3);
      expect(e.selection.extent, 9);
      e.move('home');
      expect(e.selection.extent, 6);
    });
    test('surrogate pairs are not split by deletion', () {
      final emoji = EditorController('a🌍b');
      emoji.select(3, 3);
      emoji.delete();
      expect(emoji.text, 'ab');
      emoji.dispose();
    });
    test('find wraps and replace-all is one undo step', () {
      e.select(11, 11);
      expect(e.find('hello'), true);
      expect(e.selection.start, 0);
      e.replaceAll('o', 'XYZ');
      expect(e.text, 'hellXYZ\nwXYZrld');
      e.undo();
      expect(e.text, 'hello\nworld');
    });
  });
  test(
    'command registry validates duplicates, enablement and execution',
    () async {
      final registry = CommandRegistry();
      var calls = 0;
      final command = CommandDescriptor(
        id: 'test',
        title: 'Test',
        handler: (arg) {
          calls++;
          return arg;
        },
      );
      registry.register(command);
      expect(() => registry.register(command), throwsStateError);
      expect(await registry.execute('test', 42), 42);
      expect(calls, 1);
      registry.register(
        CommandDescriptor(
          id: 'disabled',
          title: 'No',
          enabled: () => false,
          handler: (_) => calls++,
        ),
      );
      await registry.execute('disabled');
      expect(calls, 1);
      await expectLater(registry.execute('missing'), throwsStateError);
    },
  );
  test('keybindings default, override and round-trip', () {
    final k = KeybindingRegistry.parse(
      '{"schemaVersion":1,"bindings":[{"key":"ctrl+s","command":"custom.save"}]}',
    );
    expect(k.resolve('CTRL+S'), 'custom.save');
    expect(k.resolve('meta+s'), 'file.save');
    expect(
      KeybindingRegistry.parse(jsonEncode(k.toJson())).bindings,
      k.bindings,
    );
  });
  group('Versioned contracts', () {
    test('reject missing, malformed, unsupported future schemas', () {
      for (final text in [
        '{}',
        '[]',
        'bad',
        '{"schemaVersion":2}',
        '{"schemaVersion":0}',
      ]) {
        expect(
          () => decodeVersioned(text, 'Test'),
          throwsA(isA<SchemaException>()),
        );
      }
    });
    test(
      'v1 normalization supplies documented optional defaults and ignores extras',
      () {
        final language = LanguagePackageLoader().load(
          '{"schemaVersion":1,"packageVersion":"1.0","id":"test","name":"Test","extensions":[".t"],"futureOptional":true}',
          '{"schemaVersion":1,"rules":[]}',
        );
        expect(language.filenames, isEmpty);
        expect(language.comments, isEmpty);
        expect(language.snippets, isEmpty);
      },
    );
    test(
      'both real packages recognize and tokenize independently of editor',
      () {
        final registry = LanguageRegistry();
        for (final id in ['dart', 'csharp']) {
          final base = 'assets/languages/$id';
          registry.register(
            LanguagePackageLoader().load(
              File('$base/language.json').readAsStringSync(),
              File('$base/syntax.json').readAsStringSync(),
              snippets: File('$base/snippets.json').readAsStringSync(),
            ),
          );
        }
        expect(
          registry
              .forPath('main.dart')!
              .tokenize('class Example {}')
              .first
              .scope,
          'keyword',
        );
        expect(registry.forPath('Program.cs')!.id, 'csharp');
        expect(registry.forPath('x.txt'), isNull);
        expect(
          registry.forPath('x.cs')!.tokenize('// public class').single.scope,
          'comment',
        );
      },
    );
    test('invalid regex and required semantics have useful errors', () {
      const manifest =
          '{"schemaVersion":1,"id":"test","name":"Test","packageVersion":"1","extensions":[]}';
      expect(
        () => LanguagePackageLoader().load(
          manifest,
          '{"schemaVersion":1,"rules":[{"pattern":"[","scope":"x"}]}',
        ),
        throwsA(isA<SchemaException>()),
      );
    });
    test('theme assets validate dark and light color contracts', () {
      expect(
        IdeTheme.parse(
          File('assets/themes/night.json').readAsStringSync(),
        ).dark,
        true,
      );
      expect(
        IdeTheme.parse(File('assets/themes/day.json').readAsStringSync()).dark,
        false,
      );
    });
    test('settings layers restore and invalid loads are atomic', () {
      final s = SettingsService();
      s.set('fontSize', 16.0);
      s.set('fontSize', 18.0, forWorkspace: true);
      final restored = SettingsService()..restore(s.encode());
      expect(restored.fontSize, 18);
      expect(
        () => restored.restore('{"schemaVersion":1,"user":{"fontSize":-4}}'),
        throwsA(isA<SchemaException>()),
      );
      expect(restored.fontSize, 18);
    });
    test('installed declarative packages survive restart', () async {
      final store = MemoryStore();
      final registry = LanguageRegistry();
      await PackageService(store, registry).install(
        File('assets/languages/dart/language.json').readAsStringSync(),
        File('assets/languages/dart/syntax.json').readAsStringSync(),
        null,
      );
      final restored = LanguageRegistry();
      final errors = <String>[];
      await PackageService(store, restored).restore(errors.add);
      expect(errors, isEmpty);
      expect(restored.forPath('x.dart')!.id, 'dart');
    });
  });
  group('Docking', () {
    test('round-trip resize, visibility and tab selection', () {
      final layout = DockLayout.defaultLayout
          .resize('horizontal', .35)
          .toggle('terminal')
          .activate('tools', 'problems');
      expect(DockLayout.parse(layout.encode()).encode(), layout.encode());
    });
    test('unknown removed panel recovers by collapsing split', () {
      final layout = DockLayout(
        SplitNode(
          'split',
          'horizontal',
          .2,
          const PanelNode('p', 'obsolete'),
          const DocumentNode('docs'),
        ),
      );
      expect(DockLayout.parse(layout.encode()).root, isA<DocumentNode>());
    });
    test('all obsolete panels or missing document area restores defaults', () {
      final layout = DockLayout(const TabNode('tools', ['old'], 'old'));
      expect(
        DockLayout.parse(layout.encode()).encode(),
        DockLayout.defaultLayout.encode(),
      );
    });
    test(
      'unsupported layout version and required node type reject gracefully',
      () {
        expect(
          () => DockLayout.parse('{"schemaVersion":99}'),
          throwsA(isA<SchemaException>()),
        );
        expect(
          () => DockLayout.parse(
            '{"schemaVersion":1,"root":{"type":"magic","id":"x"}}',
          ),
          throwsA(isA<SchemaException>()),
        );
      },
    );
  });
}
