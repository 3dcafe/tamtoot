import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/themes/ide_theme.dart';
import 'package:tamtoot/core/completion/project_completion.dart';
import 'package:tamtoot/editor/buffer/text_buffer.dart';
import 'package:tamtoot/editor/document/editor_controller.dart';
import 'package:tamtoot/editor/rendering/line_layout_cache.dart';
import 'package:tamtoot/editor/widgets/code_editor.dart';
import 'package:tamtoot/languages/document_syntax.dart';
import 'language_syntax_test.dart' show loadLanguage;
import 'explorer_test.dart' show RepositoryMemory;
import 'support.dart';

class _CountingBuffer extends IndexedTextBuffer {
  _CountingBuffer(super.text);
  int reads = 0;
  @override
  String getLine(int line) {
    reads++;
    return super.getLine(line);
  }
}

void main() {
  test(
    'dirty ranges cover batch edits, Undo/Redo, reload and history overflow',
    () {
      final e = EditorController('a\nb\nc\nd');
      addTearDown(e.dispose);
      e.transact([const BufferEdit(2, 3, 'B'), const BufferEdit(6, 7, 'D')]);
      expect(e.changedLinesSince(0), (first: 1, last: 3));
      final revision = e.revision;
      e.select(0, 0);
      expect(e.changedLinesSince(revision), (first: 4, last: -1));
      e.undo();
      expect(e.changedLinesSince(revision), (first: 1, last: 3));
      e.redo();
      expect(e.text, 'a\nB\nc\nD');
      e.reloadFromDisk('new\nfile');
      expect(e.changedLinesSince(revision), (first: 0, last: 1));
      for (var i = 0; i < 65; i++) {
        e.replaceSelection('x');
      }
      expect(e.changedLinesSince(0).first, 0);
    },
  );

  test(
    'syntax invalidation does not read the unchanged prefix of 10000 lines',
    () {
      final buffer = _CountingBuffer(
        List.filled(10000, 'int value = 0;').join('\n'),
      );
      final e = EditorController('', storage: buffer),
          syntax = DocumentSyntax();
      addTearDown(e.dispose);
      final language = loadLanguage('dart');
      void read() => syntax.tokensFor(
        source: e,
        revision: e.revision,
        language: language,
        lineCount: buffer.lineCount,
        readLine: buffer.getLine,
        line: 9999,
        firstChangedLineSince: (revision) =>
            e.changedLinesSince(revision).first,
      );
      read();
      e.select(
        buffer.offsetAt(const TextPoint(9999, 0)),
        buffer.offsetAt(const TextPoint(9999, 0)),
      );
      e.replaceSelection('// ');
      buffer.reads = 0;
      read();
      expect(buffer.reads, 1);
      e.undo();
      buffer.reads = 0;
      read();
      expect(buffer.reads, 1);
    },
  );

  test(
    'native layouts are reused and bounded; theme, font, tab and tokens invalidate',
    () {
      final cache = LineLayoutCache(capacity: 2);
      addTearDown(cache.clear);
      final day = IdeTheme.parse(
        File('assets/themes/day.json').readAsStringSync(),
      );
      final night = IdeTheme.parse(
        File('assets/themes/night.json').readAsStringSync(),
      );
      const style = TextStyle(fontSize: 14);
      final tokens = loadLanguage('dart').tokenize('int value;');
      final a = cache.get(
        raw: 'int value;',
        tokens: tokens,
        style: style,
        theme: day,
        tabSize: 2,
      );
      final b = cache.get(
        raw: 'int value;',
        tokens: tokens,
        style: style,
        theme: day,
        tabSize: 2,
      );
      expect(identical(a, b), isTrue);
      expect(cache.layoutsBuilt, 1);
      cache.get(
        raw: 'int value;',
        tokens: tokens,
        style: style,
        theme: night,
        tabSize: 2,
      );
      cache.get(
        raw: 'int value;',
        tokens: tokens,
        style: style.copyWith(fontSize: 16),
        theme: night,
        tabSize: 2,
      );
      cache.get(
        raw: 'int value;',
        tokens: tokens,
        style: style.copyWith(fontSize: 16),
        theme: night,
        tabSize: 4,
      );
      cache.get(
        raw: 'int value;',
        tokens: loadLanguage('dart').tokenize('int value;'),
        style: style.copyWith(fontSize: 16),
        theme: night,
        tabSize: 4,
      );
      expect(cache.length, 2);
      expect(cache.layoutsBuilt, 5);
    },
  );

  test(
    'incremental symbols match full parsing after edits, scope changes and Undo',
    () async {
      final e = EditorController(
        'class Service {\n${List.generate(1000, (i) => '  int value$i = 0;').join('\n')}\n}\nva',
      );
      addTearDown(e.dispose);
      final index = ProjectCompletionIndex(RepositoryMemory());
      await index.initialize();
      List<String> query({bool incremental = true}) => index
          .suggest(
            source: e.text,
            offset: e.buffer.length,
            language: 'dart',
            limit: 2000,
            document: incremental ? e : null,
          )
          .map((symbol) => '${symbol.owner}:${symbol.signature}')
          .toList();
      query();
      var count = index.activeLinesParsed;
      e.select(
        e.buffer.offsetAt(const TextPoint(500, 0)),
        e.buffer.offsetAt(const TextPoint(500, 0)),
      );
      e.replaceSelection(' ');
      final incremental = query();
      expect(index.activeLinesParsed - count, 1);
      expect(incremental, query(incremental: false));
      query();
      count = index.activeLinesParsed;
      e.select(0, 13);
      e.replaceSelection('class Renamed');
      final renamed = query();
      expect(index.activeLinesParsed - count, greaterThan(900));
      expect(renamed, query(incremental: false));
      e.undo();
      expect(query(), query(incremental: false));
      e.select(0, 0);
      e.replaceSelection('// new line\n');
      expect(query(), query(incremental: false));
    },
  );

  test(
    'incremental parser state matches full parsing for all completion languages',
    () async {
      for (final language in [
        'dart',
        'csharp',
        'java',
        'kotlin',
        'typescript',
        'javascript',
        'php',
      ]) {
        final index = ProjectCompletionIndex(RepositoryMemory());
        final baseline = ProjectCompletionIndex(RepositoryMemory());
        await index.initialize();
        await baseline.initialize();
        final declaration = switch (language) {
          'kotlin' => 'val value: Int = 0',
          'typescript' => 'value: number = 0;',
          'javascript' => 'var value = 0;',
          'php' => r'public int $value = 0;',
          _ => 'int value = 0;',
        };
        final e = EditorController('class Service {\n  $declaration\n}\nva');
        addTearDown(e.dispose);
        List<String> query(
          ProjectCompletionIndex provider, {
          bool incremental = true,
        }) => provider
            .suggest(
              source: e.text,
              offset: e.buffer.length,
              language: language,
              document: incremental ? e : null,
            )
            .map((symbol) => '${symbol.owner}:${symbol.signature}')
            .toList();
        query(index);
        final count = index.activeLinesParsed;
        e.select(1, 1);
        query(index);
        expect(index.activeLinesParsed, count);
        e.select(
          e.buffer.offsetAt(const TextPoint(1, 0)),
          e.buffer.offsetAt(const TextPoint(1, 0)),
        );
        e.replaceSelection('  ');
        expect(
          query(index),
          query(baseline, incremental: false),
          reason: language,
        );
        expect(index.activeLinesParsed - count, 1, reason: language);
        e.undo();
        expect(
          query(index),
          query(baseline, incremental: false),
          reason: language,
        );
      }
    },
  );
  testWidgets('cursor-only updates do not rescan folding across 10000 lines', (
    tester,
  ) async {
    final session = await testSession();
    final buffer = _CountingBuffer(
      List.filled(10000, 'int value = 0;').join('\n'),
    );
    final e = EditorController('', storage: buffer);
    await tester.pumpWidget(
      MaterialApp(
        home: CodeEditor(
          controller: e,
          session: session,
          language: loadLanguage('dart'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    buffer.reads = 0;
    e.select(1, 1);
    await tester.pumpAndSettle();
    expect(buffer.reads, lessThan(300));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await e.dispose();
    await tester.runAsync(session.dispose);
  });
}
