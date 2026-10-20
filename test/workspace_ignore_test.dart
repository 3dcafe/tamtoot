import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/platform/workspace_ignore_io.dart';
import 'package:tamtoot/core/git/git_ignore.dart';

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('tamtoot-ignore-'),
  );
  tearDown(() async => root.delete(recursive: true));

  test(
    'creates rules for local state without hiding shared requests or sources',
    () async {
      expect(await ensureWorkspaceIgnore(root.uri), true);
      final ignore = GitIgnore()
        ..add(await File('${root.path}/.gitignore').readAsString());
      for (final path in [
        '.tamtoot/cache/completions-v7.json',
        'Dialog.DAL/.tamtoot/agents/chat_history.json',
        '.tamtoot/agents/models/local.json',
        '.tamtoot/environment.local.json',
      ]) {
        expect(ignore.ignores(path, directory: false), true, reason: path);
      }
      for (final path in [
        'Program.cs',
        '.tamtoot/requests/api.json',
        '.tamtoot/environment.json',
      ]) {
        expect(ignore.ignores(path, directory: false), false, reason: path);
      }
      expect(await ensureWorkspaceIgnore(root.uri), false);
    },
  );

  test('preserves existing content and CRLF with no final newline', () async {
    final file = File('${root.path}/.gitignore');
    const original = 'bin/\r\nobj/\r\n!important.txt';
    await file.writeAsString(original);
    await ensureWorkspaceIgnore(root.uri);
    final result = await file.readAsString();
    expect(result, startsWith('$original\r\n'));
    expect(result.replaceAll('\r\n', ''), isNot(contains('\n')));
    await ensureWorkspaceIgnore(root.uri);
    expect(await file.readAsString(), result);
  });

  test('does not write through a symbolic link', () async {
    final target = File('${root.path}/target')..writeAsStringSync('original');
    await Link('${root.path}/.gitignore').create(target.path);
    expect(await ensureWorkspaceIgnore(root.uri), false);
    expect(await target.readAsString(), 'original');
  }, skip: Platform.isWindows);
}
