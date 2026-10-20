import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'llm.dart';

/// Built-in coding tools, ported from opencode's tool plugins
/// (packages/core/src/tool/plugin/{read,edit,write,shell,glob,grep}.ts).
///
/// Paths resolve against the project root; absolute paths inside the root are
/// accepted, mutations outside the root are rejected (the port of opencode's
/// FileAccess boundary, minus its interactive approvals).

class ToolFailure implements Exception {
  const ToolFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class ToolContext {
  ToolContext({required this.root, required this.sessionId, required this.callId});

  /// Absolute project root; relative tool paths resolve against it.
  final String root;
  final String sessionId;
  final String callId;

  static final _sep = Platform.pathSeparator;

  /// Resolve a model-supplied path to an absolute one inside or outside the
  /// root. Returns the absolute path and whether it is inside the root.
  ({String absolute, bool inside}) resolve(String path) {
    if (path.isEmpty) return (absolute: root, inside: true);
    final isAbsolute = Platform.isWindows
        ? RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) || path.startsWith(r'\\')
        : path.startsWith('/');
    final absolute = isAbsolute ? path : '$root$_sep$path';
    final normalized = _normalize(absolute);
    final normalizedRoot = _normalize(root);
    final inside =
        normalized == normalizedRoot ||
        normalized.startsWith('$normalizedRoot$_sep');
    return (absolute: normalized, inside: inside);
  }

  static String _normalize(String path) {
    final segments = <String>[];
    for (final segment in path.split(RegExp(r'[\\/]'))) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isNotEmpty && segments.last != '..') segments.removeLast();
      } else {
        segments.add(segment);
      }
    }
    final prefix = Platform.isWindows && path.length > 1 && path[1] == ':'
        ? ''
        : _sep;
    return prefix + segments.join(_sep);
  }

  void assertCanMutate(String path) {
    final resolved = resolve(path);
    if (!resolved.inside) {
      throw ToolFailure(
        'Refusing to modify a file outside the project: $path',
      );
    }
  }
}

class ToolResult {
  ToolResult(this.content, {this.metadata = const {}});
  final String content;
  final Map<String, dynamic> metadata;
}

class Tool {
  Tool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.execute,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final Future<ToolResult> Function(
    Map<String, dynamic> input,
    ToolContext context,
  )
  execute;

  LlmToolDef definition() =>
      LlmToolDef(name: name, description: description, parameters: parameters);
}

Map<String, dynamic> _object(Map<String, dynamic> properties, List<String> required) =>
    {'type': 'object', 'properties': properties, 'required': required};

typedef _Match = ({int start, int end});
typedef _ReplaceFn = String Function(_Match);

/// The default coding tool set: read, write, edit, shell, glob, grep.
List<Tool> defaultTools() => [_read(), _write(), _edit(), _shell(), _glob(), _grep()];

// --------------------------------------------------------------------- read

const _readCap = 2000;

Tool _read() => Tool(
  name: 'read',
  description:
      'Read the contents of a file or directory. Each text line is prefixed '
      'by its 1-based line number as <line>: <content>. The prefix is for '
      'reference and is not part of the file content. Directory entries are '
      'returned one per line. Use offset and limit to read large files or '
      'directories in sections. Prefer one larger read over many small '
      'slices, and use grep to find specific content in large files.',
  parameters: _object({
    'path': {'type': 'string', 'description': 'File or directory to read'},
    'offset': {
      'type': 'integer',
      'description': 'The line or directory entry to start reading from (1-based)',
    },
    'limit': {
      'type': 'integer',
      'description':
          'The maximum number of lines or directory entries to read (defaults to and capped at $_readCap)',
    },
  }, ['path']),
  execute: (input, context) async {
    final path = '${input['path'] ?? ''}';
    final resolved = context.resolve(path);
    final entity = FileSystemEntity.typeSync(resolved.absolute);
    if (entity == FileSystemEntityType.notFound) {
      throw ToolFailure(_missingMessage(context, path, resolved.absolute));
    }
    final offset = math.max(1, (input['offset'] as num?)?.toInt() ?? 1);
    final limit = math.min(
      _readCap,
      math.max(1, (input['limit'] as num?)?.toInt() ?? _readCap),
    );

    if (entity == FileSystemEntityType.directory) {
      final entries = Directory(resolved.absolute)
          .listSync()
          .map((e) => (
              name: e.path.split(Platform.pathSeparator).last,
              isDir: e is Directory,
            ))
          .toList()
        ..sort((a, b) => a.isDir == b.isDir
            ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
            : (a.isDir ? -1 : 1));
      final page = entries.skip(offset - 1).take(limit).toList();
      final buffer = StringBuffer(
        page.isEmpty
            ? 'Read directory $path, 0 entries'
            : 'Read directory $path, entries $offset-${offset + page.length - 1}',
      );
      for (final entry in page) {
        buffer.write('\n${entry.name}${entry.isDir ? Platform.pathSeparator : ''}');
      }
      if (offset - 1 + page.length < entries.length) {
        buffer.write(
          '\n[Output truncated. Continue reading with offset: ${offset + page.length}]',
        );
      }
      return ToolResult(buffer.toString(), metadata: {'truncated': page.length < entries.length});
    }

    final file = File(resolved.absolute);
    final bytes = await file.openRead(0, 8192).expand((c) => c).toList();
    if (bytes.contains(0)) {
      throw ToolFailure(
        'Cannot read $path: it appears to be a binary file.',
      );
    }
    final lines = (await file.readAsString()).split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    if (offset > lines.length && lines.isNotEmpty) {
      throw ToolFailure(
        'Offset $offset is out of range: $path has ${lines.length} lines.',
      );
    }
    final page = lines.skip(offset - 1).take(limit).toList();
    final buffer = StringBuffer(
      page.isEmpty
          ? 'Read file $path, 0 lines'
          : 'Read file $path, lines $offset-${offset + page.length - 1}',
    );
    for (var i = 0; i < page.length; i++) {
      buffer.write('\n${offset + i}: ${page[i]}');
    }
    if (offset - 1 + page.length < lines.length) {
      buffer.write(
        '\n[Output truncated. Continue reading with offset: ${offset + page.length}]',
      );
    }
    return ToolResult(buffer.toString());
  },
);

String _missingMessage(ToolContext context, String path, String absolute) {
  final base = absolute.split(Platform.pathSeparator).last.toLowerCase();
  try {
    final parentPath = absolute.substring(
      0,
      absolute.length - absolute.split(Platform.pathSeparator).last.length - 1,
    );
    final suggestions = Directory(parentPath)
        .listSync()
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .where((name) {
          final candidate = name.toLowerCase();
          return candidate.contains(base) || base.contains(candidate);
        })
        .take(3)
        .toList();
    if (suggestions.isNotEmpty) {
      final dir = path.contains(Platform.pathSeparator)
          ? path.substring(0, path.length - path.split(Platform.pathSeparator).last.length)
          : '';
      return 'File not found: $path\n\nDid you mean one of these?\n'
          '${suggestions.map((s) => '$dir$s').join('\n')}';
    }
  } catch (_) {}
  return 'File not found: $path';
}

// -------------------------------------------------------------------- write

Tool _write() => Tool(
  name: 'write',
  description:
      'Writes a file to the local filesystem, overwriting if one exists.\n\n'
      'Missing parent directories are created automatically.\n\n'
      'Use this tool to create new files or overwrite existing files. For '
      'partial changes, use the edit tool instead.',
  parameters: _object({
    'path': {'type': 'string', 'description': 'Path to the file to write to'},
    'content': {'type': 'string', 'description': 'Content to write to the file'},
  }, ['path', 'content']),
  execute: (input, context) async {
    final path = '${input['path'] ?? ''}';
    final content = '${input['content'] ?? ''}';
    context.assertCanMutate(path);
    final resolved = context.resolve(path);
    final file = File(resolved.absolute);
    final existed = file.existsSync();
    // Preserve the byte-order mark of the file being replaced, mirroring
    // opencode's writeTextPreservingBom.
    var output = content;
    if (existed) {
      final head = await file.openRead(0, 3).expand((c) => c).toList();
      final hadBom = head.length >= 3 &&
          head[0] == 0xef &&
          head[1] == 0xbb &&
          head[2] == 0xbf;
      if (hadBom && !content.startsWith('\u{FEFF}')) output = '\u{FEFF}$content';
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(output);
    return ToolResult(
      '${existed ? 'Wrote' : 'Created'} file successfully: $path',
    );
  },
);

// --------------------------------------------------------------------- edit

const _crlf = '\r\n';

String _normalizeForMatch(String value) => value
    .replaceAll(RegExp(r'[‘’‚‛]'), "'")
    .replaceAll(RegExp(r'[“”„‟]'), '"')
    .replaceAll(RegExp(r'[‐‑‒–—―−]'), '-')
    .replaceAll(RegExp(r'[  -   　]'), ' ');

List<_Match> _findOccurrences(String content, String search) {
  final result = <_Match>[];
  var offset = 0;
  while (true) {
    offset = content.indexOf(search, offset);
    if (offset == -1) break;
    result.add((start: offset, end: offset + search.length));
    offset += search.length;
  }
  return result;
}

List<_Match> _findLineOccurrences(String content, String search) {
  final trailingNewline = search.endsWith('\n');
  final expected = search.split('\n');
  if (trailingNewline) expected.removeLast();
  final lines = <({int start, int end, String text, int contentEnd, bool newline})>[];
  final matches = RegExp(r'[^\n]*(?:\n|$)').allMatches(content);
  for (final match in matches) {
    final raw = match.group(0)!;
    if (raw.isEmpty) continue;
    final newline = raw.endsWith('\n');
    final text = newline ? raw.substring(0, raw.length - 1) : raw;
    lines.add((
      start: match.start,
      end: match.start + raw.length,
      text: text,
      contentEnd: match.start + text.length - (text.endsWith('\r') ? 1 : 0),
      newline: newline,
    ));
  }
  final candidates = <_Match>[];
  for (var index = 0; index + expected.length <= lines.length; index++) {
    final actual = lines.sublist(index, index + expected.length);
    var ok = true;
    for (var i = 0; i < expected.length; i++) {
      if (_normalizeForMatch(actual[i].text.trimRight()) !=
          _normalizeForMatch(expected[i].trimRight())) {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    final last = actual.last;
    if (trailingNewline && !last.newline) continue;
    candidates.add((
      start: actual.first.start,
      end: trailingNewline ? last.end : last.contentEnd,
    ));
  }
  // Drop overlapping candidates, keeping the first of each overlapping run.
  final result = <_Match>[];
  for (final candidate in candidates) {
    final overlaps = result.any(
      (match) => match.end > candidate.start && match.start < candidate.end,
    );
    if (!overlaps) result.add(candidate);
  }
  return result;
}

String _lineEnding(String text, String fallback) {
  final crlfCount = _crlf.allMatches(text).length;
  final lfCount = '\n'.allMatches(text).length - crlfCount;
  if (crlfCount == lfCount) return fallback;
  return crlfCount > lfCount ? _crlf : '\n';
}

/// For each line of `after`, the index of the `before` line it keeps (LCS)
/// or the line it replaces; -1 for lines with no counterpart.
List<int> _alignLines(List<String> before, List<String> after) {
  final width = after.length + 1;
  final table = List<int>.filled((before.length + 1) * width, 0);
  for (var i = before.length - 1; i >= 0; i--) {
    for (var j = after.length - 1; j >= 0; j--) {
      table[i * width + j] = before[i] == after[j]
          ? table[(i + 1) * width + j + 1] + 1
          : math.max(table[(i + 1) * width + j], table[i * width + j + 1]);
    }
  }
  final result = List<int>.filled(after.length, -1);
  final gapBefore = <int>[];
  final gapAfter = <int>[];
  void flush() {
    for (var k = 0; k < gapAfter.length; k++) {
      result[gapAfter[k]] = k < gapBefore.length ? gapBefore[k] : -1;
    }
    gapBefore.clear();
    gapAfter.clear();
  }

  var i = 0;
  var j = 0;
  while (i < before.length && j < after.length) {
    if (before[i] == after[j]) {
      flush();
      result[j++] = i++;
      continue;
    }
    if (table[(i + 1) * width + j] >= table[i * width + j + 1]) {
      gapBefore.add(i++);
    } else {
      gapAfter.add(j++);
    }
  }
  while (i < before.length) {
    gapBefore.add(i++);
  }
  while (j < after.length) {
    gapAfter.add(j++);
  }
  flush();
  return result;
}

String _withRegionEndings(String region, String replacement, String fallback) {
  final before = region.split(RegExp(r'\r?\n'));
  final endings = [
    for (final match in RegExp(r'\r?\n').allMatches(region)) match.group(0)!,
  ];
  final after = replacement.split('\n');
  String key(String line) => _normalizeForMatch(line.trimRight());
  final source = _alignLines(
    [for (final line in before) key(line)],
    [for (final line in after) key(line)],
  );
  final buffer = StringBuffer();
  for (var i = 0; i < after.length; i++) {
    buffer.write(after[i]);
    if (i < after.length - 1) {
      final sourceIndex = source[i];
      buffer.write(
        sourceIndex >= 0 && sourceIndex < endings.length
            ? endings[sourceIndex]
            : fallback,
      );
    }
  }
  return buffer.toString();
}

int _countBefore(List<int> positions, int offset) {
  var low = 0;
  var high = positions.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (positions[middle] < offset) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

/// Matches against the LF view Read shows the model, then maps offsets back
/// to the source, so CRLF and mixed endings neither block matches nor leak
/// into untouched regions. Ported from opencode's edit.ts matchView.
({List<_Match> matches, _ReplaceFn replace})
_matchView(String source, String oldString, String newString) {
  final view = source.replaceAll(_crlf, '\n');
  final removed = <int>[];
  var index = 0;
  for (final match in RegExp('\r\n').allMatches(source)) {
    removed.add(match.start - index);
    index++;
  }
  final fileEnding = _lineEnding(source, '\n');
  final search = oldString.replaceAll(_crlf, '\n');
  final replacement = newString.replaceAll(_crlf, '\n');
  final exact = _findOccurrences(view, search);
  final unicode = exact.isNotEmpty
      ? const <_Match>[]
      : _findOccurrences(_normalizeForMatch(view), _normalizeForMatch(search));
  final trailing = exact.isNotEmpty || unicode.isNotEmpty
      ? const <_Match>[]
      : _findLineOccurrences(view, search);
  final tier = exact.isNotEmpty ? exact : (unicode.isNotEmpty ? unicode : trailing);
  return (
    matches: [
      for (final match in tier)
        (
          start: match.start + _countBefore(removed, match.start),
          end: match.end + _countBefore(removed, match.end),
        ),
    ],
    replace: (_Match match) {
      final region = source.substring(match.start, match.end);
      return _withRegionEndings(
        region,
        replacement,
        _lineEnding(region, fileEnding),
      );
    },
  );
}

Tool _edit() => Tool(
  name: 'edit',
  description:
      'Edit the contents of a file by finding and replacing exact text. When '
      'editing text from Read output, preserve the exact indentation (tabs or '
      'spaces) and omit the line-number prefix, such as `1: `. Never include '
      'the prefix in oldString or newString. Write line breaks as \\n; the '
      "file's existing CRLF or LF line endings are matched and preserved. If "
      'there is no exact match, the edit retries while ignoring typographic '
      'quote, dash, and space variants, then trailing whitespace on each '
      'line. The edit fails if oldString is not found. By default, oldString '
      'must identify a UNIQUE location. Multiple matches FAIL unless '
      'replaceAll is true. Add more surrounding context to disambiguate, or '
      'set replaceAll to true to replace every occurrence.',
  parameters: _object({
    'path': {'type': 'string', 'description': 'File to edit'},
    'oldString': {
      'type': 'string',
      'description': 'Exact text to find and replace',
    },
    'newString': {
      'type': 'string',
      'description':
          'Text to replace oldString with (must differ from oldString)',
    },
    'replaceAll': {
      'type': 'boolean',
      'description':
          'Whether to replace every occurrence of oldString. When false, oldString must match exactly once. Defaults to false.',
    },
  }, ['path', 'oldString', 'newString']),
  execute: (input, context) async {
    final path = '${input['path'] ?? ''}';
    final oldString = '${input['oldString'] ?? ''}';
    final newString = '${input['newString'] ?? ''}';
    final replaceAll = input['replaceAll'] == true;

    if (oldString == newString) {
      throw const ToolFailure(
        'No changes to apply: oldString and newString are identical.',
      );
    }
    if (oldString.isEmpty) {
      throw const ToolFailure(
        'oldString must not be empty. Use write to create or overwrite a file.',
      );
    }
    context.assertCanMutate(path);
    final resolved = context.resolve(path);
    final file = File(resolved.absolute);
    if (!file.existsSync()) {
      throw ToolFailure('File not found: $path');
    }
    if (FileSystemEntity.typeSync(resolved.absolute) ==
        FileSystemEntityType.directory) {
      throw ToolFailure('Path is a directory, not a file: $path');
    }
    final raw = await file.readAsBytes();
    final hasBom = raw.length >= 3 &&
        raw[0] == 0xef &&
        raw[1] == 0xbb &&
        raw[2] == 0xbf;
    final source = utf8.decode(hasBom ? raw.sublist(3) : raw);

    // Strings that differ only in \r ask to change line endings themselves.
    final endingsOnly =
        oldString.replaceAll('\r', '') == newString.replaceAll('\r', '');
    late final List<_Match> matches;
    late final _ReplaceFn replace;
    if (endingsOnly) {
      matches = _findOccurrences(source, oldString);
      replace = (_) => newString;
    } else {
      final view = _matchView(source, oldString, newString);
      matches = view.matches;
      replace = view.replace;
    }

    final replacements = matches.length;
    if (replacements == 0) {
      throw ToolFailure(
        'Could not find oldString in $path. It must match exactly, including '
        'whitespace and indentation.',
      );
    }
    if (replacements > 1 && !replaceAll) {
      throw ToolFailure(
        'Found $replacements matches for oldString, but expected exactly '
        'one. Add more surrounding context to make oldString unique, or set '
        'replaceAll to true to replace every occurrence.',
      );
    }
    var replaced = source;
    final targets = replaceAll ? matches : matches.take(1).toList();
    for (final match in targets.reversed) {
      replaced = replaced.replaceRange(match.start, match.end, replace(match));
    }
    if (replaced == source) {
      throw ToolFailure(
        endingsOnly
            ? 'No changes to apply: $path already has those line endings.'
            : 'No changes to apply: the edit leaves $path unchanged. Line '
                'endings follow the file; to change them, write \\r '
                'explicitly in oldString or newString.',
      );
    }
    await file.writeAsBytes([
      if (hasBom || replaced.startsWith('\u{FEFF}')) ...[0xef, 0xbb, 0xbf],
      ...utf8.encode(
        replaced.startsWith('\u{FEFF}') ? replaced.substring(1) : replaced,
      ),
    ]);
    return ToolResult(
      'Edited $path ($replacements replacement${replacements == 1 ? '' : 's'})',
      metadata: {'replacements': replacements},
    );
  },
);

// -------------------------------------------------------------------- shell

const _shellDefaultTimeoutMs = 2 * 60 * 1000;
const _shellOutputCap = 30000;

Tool _shell() => Tool(
  name: 'shell',
  description:
      'Execute a shell command and return its output. Commands run on '
      '${Platform.isMacOS ? 'macOS' : Platform.isWindows ? 'Windows' : Platform.operatingSystem}. '
      'Quote file paths containing spaces or special characters. Prefer '
      'dedicated tools over shell commands when possible. When output is '
      'large, the full result is saved to a file and a truncated preview is '
      'returned.',
  parameters: _object({
    'command': {
      'type': 'string',
      'description': 'Shell command string to execute',
    },
    'workdir': {
      'type': 'string',
      'description':
          'Working directory to execute the command in. Defaults to the project root.',
    },
    'timeout': {
      'type': 'integer',
      'description':
          'Timeout in milliseconds. Set to 0 to disable the timeout. Defaults to $_shellDefaultTimeoutMs.',
    },
  }, ['command']),
  execute: (input, context) async {
    final command = '${input['command'] ?? ''}';
    if (command.trim().isEmpty) {
      throw const ToolFailure('Command must not be empty.');
    }
    final workdir = input['workdir'] is String &&
            (input['workdir'] as String).isNotEmpty
        ? context.resolve(input['workdir'] as String).absolute
        : context.root;
    if (!Directory(workdir).existsSync()) {
      throw ToolFailure('Working directory does not exist: ${input['workdir']}');
    }
    final timeoutMs = (input['timeout'] as num?)?.toInt() ?? _shellDefaultTimeoutMs;

    final process = await Process.start(
      Platform.isWindows ? 'cmd' : '/bin/sh',
      Platform.isWindows ? ['/c', command] : ['-c', command],
      workingDirectory: workdir,
    );
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    final done = Future.wait([
      process.stdout.transform(utf8.decoder).forEach(stdout.write),
      process.stderr.transform(utf8.decoder).forEach(stderr.write),
    ]);

    int? exitCode;
    var timedOut = false;
    try {
      exitCode = await process.exitCode.timeout(
        timeoutMs == 0
            ? const Duration(days: 1)
            : Duration(milliseconds: timeoutMs),
      );
    } on TimeoutException {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      exitCode = await process.exitCode;
    }
    await done;

    var output = [
      if (stdout.isNotEmpty) stdout.toString().trimRight(),
      if (stderr.isNotEmpty) stderr.toString().trimRight(),
    ].join('\n');
    String? savedTo;
    if (output.length > _shellOutputCap) {
      final dir = Directory(
        '${context.root}${Platform.pathSeparator}.tamtoot${Platform.pathSeparator}opencode${Platform.pathSeparator}output',
      );
      await dir.create(recursive: true);
      final file = File(
        '${dir.path}${Platform.pathSeparator}${context.callId}.txt',
      );
      await file.writeAsString(output);
      savedTo = file.path;
      output = output.substring(0, _shellOutputCap);
    }
    final notice = timedOut
        ? 'Command timed out after ${timeoutMs / 1000} seconds and was killed.'
        : (exitCode != 0 ? 'Exit code: $exitCode' : null);
    return ToolResult(
      [
        output,
        if (savedTo != null)
          '[Output truncated. Full result saved to: $savedTo]',
        ?notice,
      ].where((s) => s.isNotEmpty).join('\n'),
      metadata: {
        'exit': exitCode,
        if (timedOut) 'timeout': true,
        'truncated': savedTo != null,
      },
    );
  },
);

// --------------------------------------------------------------------- glob

const _searchLimit = 100;

RegExp _globToRegExp(String pattern) {
  final buffer = StringBuffer('^');
  var i = 0;
  while (i < pattern.length) {
    final char = pattern[i];
    if (char == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        // `**/` crosses directories; bare `**` matches everything.
        if (i + 2 < pattern.length && (pattern[i + 2] == '/' || pattern[i + 2] == '\\')) {
          buffer.write('(?:[^/\\\\]*[/\\\\])*');
          i += 3;
        } else {
          buffer.write('.*');
          i += 2;
        }
      } else {
        buffer.write('[^/\\\\]*');
        i++;
      }
    } else if (char == '?') {
      buffer.write('[^/\\\\]');
      i++;
    } else if (char == '{') {
      final close = pattern.indexOf('}', i);
      if (close == -1) {
        buffer.write(RegExp.escape(char));
        i++;
      } else {
        final options = pattern.substring(i + 1, close).split(',');
        buffer.write('(?:${options.map(RegExp.escape).join('|')})');
        i = close + 1;
      }
    } else {
      buffer.write(RegExp.escape(char));
      i++;
    }
  }
  buffer.write('\$');
  return RegExp(buffer.toString());
}

Iterable<({String path, bool isDir, bool hidden})> _walk(
  Directory root, {
  required bool includeHidden,
}) sync* {
  if (!root.existsSync()) return;
  final rootPath = root.path;
  final stack = <Directory>[root];
  while (stack.isNotEmpty) {
    final dir = stack.removeLast();
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync();
    } catch (_) {
      continue;
    }
    for (final entity in entries) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name == '.git') continue;
      final hidden = name.startsWith('.');
      if (hidden && !includeHidden) continue;
      final relative = entity.path.length > rootPath.length
          ? entity.path.substring(rootPath.length + 1)
          : name;
      yield (path: relative, isDir: entity is Directory, hidden: hidden);
      if (entity is Directory) stack.add(entity);
    }
  }
}

Tool _glob() => Tool(
  name: 'glob',
  description:
      'Search file paths using a glob pattern (examples: "**/*.ts", "src/**/*.tsx").',
  parameters: _object({
    'pattern': {
      'type': 'string',
      'description': 'Glob pattern to match files against',
    },
    'path': {
      'type': 'string',
      'description':
          'Directory to search. Defaults to the project root.',
    },
    'hidden': {
      'type': 'boolean',
      'description': 'Include hidden files and directories (default: false).',
    },
    'limit': {
      'type': 'integer',
      'description':
          'Maximum number of matching files to return (default: $_searchLimit)',
    },
  }, ['pattern']),
  execute: (input, context) async {
    final pattern = '${input['pattern'] ?? ''}';
    if (pattern.isEmpty) throw const ToolFailure('Pattern must not be empty.');
    final rawPath = input['path'];
    final searchPath = rawPath is String && rawPath.isNotEmpty && rawPath != 'undefined' && rawPath != 'null'
        ? rawPath
        : null;
    final resolved = context.resolve(searchPath ?? '.');
    final dir = Directory(resolved.absolute);
    if (!dir.existsSync()) {
      throw ToolFailure('Search path does not exist: ${searchPath ?? '.'}');
    }
    if (FileSystemEntity.typeSync(resolved.absolute) !=
        FileSystemEntityType.directory) {
      throw ToolFailure('Search path is not a directory: ${searchPath ?? '.'}');
    }
    final includeHidden = input['hidden'] == true;
    final limit = math.max(1, (input['limit'] as num?)?.toInt() ?? _searchLimit);
    final matcher = _globToRegExp(pattern);
    final matches = <String>[];
    for (final entry in _walk(dir, includeHidden: includeHidden)) {
      if (entry.isDir) continue;
      if (matcher.hasMatch(entry.path)) matches.add(entry.path);
      if (matches.length > limit) break;
    }
    matches.sort();
    final truncated = matches.length > limit;
    final shown = truncated ? matches.sublist(0, limit) : matches;
    final lines = [
      if (shown.isEmpty) 'No files found' else ...shown,
      if (truncated)
        '\n(Results are truncated: showing first $limit results. Consider using a more specific path or pattern.)',
    ];
    return ToolResult(
      lines.join('\n'),
      metadata: {'count': shown.length, 'truncated': truncated},
    );
  },
);

// --------------------------------------------------------------------- grep

Tool _grep() => Tool(
  name: 'grep',
  description:
      'Search file contents using regular expressions or literal text '
      'matching. Use it to locate specific code, symbols, or text patterns, '
      'and narrow searches with `path` or `include`. Returns matching file '
      'paths, line numbers, and line previews.',
  parameters: _object({
    'pattern': {
      'type': 'string',
      'description':
          'Regular expression or literal text to match in file contents.',
    },
    'path': {
      'type': 'string',
      'description':
          'File or directory to search. Defaults to the project root.',
    },
    'include': {
      'type': 'string',
      'description':
          'Glob pattern to filter files (for example, "*.js" or "*.{ts,tsx}")',
    },
    'literal': {
      'type': 'boolean',
      'description':
          'Treat `pattern` as exact text instead of a regular expression (default: false).',
    },
    'caseSensitive': {
      'type': 'boolean',
      'description': 'Use case-sensitive matching (default: true).',
    },
    'limit': {
      'type': 'integer',
      'description':
          'Maximum number of matching lines to return (default: $_searchLimit)',
    },
  }, ['pattern']),
  execute: (input, context) async {
    final pattern = '${input['pattern'] ?? ''}';
    if (pattern.isEmpty) throw const ToolFailure('Pattern must not be empty.');
    final rawPath = input['path'];
    final resolved = context.resolve(
      rawPath is String && rawPath.isNotEmpty ? rawPath : '.',
    );
    final type = FileSystemEntity.typeSync(resolved.absolute);
    if (type == FileSystemEntityType.notFound) {
      throw ToolFailure(
        'Search path does not exist: ${rawPath ?? '.'}',
      );
    }
    final caseSensitive = input['caseSensitive'] != false;
    final literal = input['literal'] == true;
    final RegExp matcher;
    try {
      matcher = RegExp(
        literal ? RegExp.escape(pattern) : pattern,
        caseSensitive: caseSensitive,
      );
    } catch (e) {
      throw ToolFailure('Invalid regex pattern: $e');
    }
    final include = input['include'] is String &&
            (input['include'] as String).isNotEmpty
        ? _globToRegExp(input['include'] as String)
        : null;
    final limit = math.max(1, (input['limit'] as num?)?.toInt() ?? _searchLimit);

    final files = <({String path, File file})>[];
    if (type == FileSystemEntityType.directory) {
      for (final entry in _walk(
        Directory(resolved.absolute),
        includeHidden: false,
      )) {
        if (entry.isDir) continue;
        if (include != null && !include.hasMatch(entry.path.split(Platform.pathSeparator).last) &&
            !include.hasMatch(entry.path)) {
          continue;
        }
        files.add((path: entry.path, file: File('${resolved.absolute}${Platform.pathSeparator}${entry.path}')));
      }
    } else {
      files.add((
        path: resolved.absolute.split(Platform.pathSeparator).last,
        file: File(resolved.absolute),
      ));
    }
    files.sort((a, b) => a.path.compareTo(b.path));

    final matches = <({String path, int line, String text})>[];
    var truncated = false;
    for (final entry in files) {
      final stat = await entry.file.stat();
      if (stat.size > 4 * 1024 * 1024) continue; // skip very large files
      final String content;
      try {
        content = await entry.file.readAsString();
      } catch (_) {
        continue; // undecodable → treat as binary, skip
      }
      if (content.contains('\u{0}')) continue; // binary file, skip
      final lines = content.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (matcher.hasMatch(lines[i])) {
          matches.add((path: entry.path, line: i + 1, text: lines[i].trimRight()));
          if (matches.length > limit) {
            truncated = true;
            break;
          }
        }
      }
      if (truncated) break;
    }
    if (truncated) matches.removeRange(limit, matches.length);

    if (matches.isEmpty) return ToolResult('No matches found');
    final buffer = StringBuffer('Found ${matches.length} matches');
    var current = '';
    for (final match in matches) {
      if (current != match.path) {
        if (current.isNotEmpty) buffer.writeln();
        current = match.path;
        buffer.write('\n${match.path}:');
      }
      buffer.write('\n  Line ${match.line}: ${match.text}');
    }
    if (truncated) {
      buffer.write(
        '\n\n(Results are truncated: showing first $limit results. Consider using a more specific path or pattern.)',
      );
    }
    return ToolResult(
      buffer.toString(),
      metadata: {'matches': matches.length, 'truncated': truncated},
    );
  },
);
