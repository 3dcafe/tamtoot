import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../git/git_store.dart';
import '../../editor/document/editor_controller.dart';
import 'angular_completions.dart';
import 'react_completions.dart';
import 'dart_arguments.dart';
import 'flutter_values.dart';

enum CompletionKind { method, variable, field, property, constant, snippet }

class CompletionSymbol {
  const CompletionSymbol({
    required this.name,
    required this.signature,
    required this.language,
    this.kind = CompletionKind.method,
    this.owner = '',
    this.documentation = '',
    this.path = '',
    this.insertText = '',
    this.replacementLength,
  });

  final String name,
      signature,
      language,
      owner,
      documentation,
      path,
      insertText;
  final int? replacementLength;
  final CompletionKind kind;
  bool get callable => kind == CompletionKind.method;

  Map<String, dynamic> toJson() => {
    'name': name,
    'signature': signature,
    'language': language,
    'kind': kind.name,
    'owner': owner,
    'documentation': documentation,
    'path': path,
    'insertText': insertText,
    if (replacementLength != null) 'replacementLength': replacementLength,
  };

  factory CompletionSymbol.fromJson(Map<String, dynamic> json) =>
      CompletionSymbol(
        name: json['name'] as String,
        signature: json['signature'] as String,
        language: json['language'] as String,
        kind:
            CompletionKind.values
                .where((kind) => kind.name == json['kind'])
                .firstOrNull ??
            CompletionKind.method,
        owner: json['owner'] as String? ?? '',
        documentation: json['documentation'] as String? ?? '',
        path: json['path'] as String? ?? '',
        insertText: json['insertText'] as String? ?? '',
        replacementLength: json['replacementLength'] as int?,
      );
}

class _ParseContext {
  String owner = '';
  String dartPending = '';
  int depth = 0, ownerDepth = -1;
  bool blockComment = false;
  final comments = <String>[];
  _ParseContext copy() => _ParseContext()
    ..owner = owner
    ..dartPending = dartPending
    ..depth = depth
    ..ownerDepth = ownerDepth
    ..blockComment = blockComment
    ..comments.addAll(comments);
  bool same(_ParseContext other) =>
      owner == other.owner &&
      dartPending == other.dartPending &&
      depth == other.depth &&
      ownerDepth == other.ownerDepth &&
      blockComment == other.blockComment &&
      comments.length == other.comments.length &&
      List.generate(
        comments.length,
        (i) => comments[i] == other.comments[i],
      ).every((equal) => equal);
}

class _CompletionLine {
  _CompletionLine(this.after, this.symbols);
  final _ParseContext after;
  final List<CompletionSymbol> symbols;
}

class ProjectCompletionIndex {
  ProjectCompletionIndex(this.store);

  static const cachePath = '.tamtoot/cache/completions-v7.json';
  static const _extensions = {
    '.dart': 'dart',
    '.php': 'php',
    '.phtml': 'php',
    '.php8': 'php',
    '.jsx': 'javascript',
    '.ts': 'typescript',
    '.tsx': 'typescript',
    '.mts': 'typescript',
    '.cts': 'typescript',
    '.cs': 'csharp',
    '.java': 'java',
    '.kt': 'kotlin',
    '.kts': 'kotlin',
    '.js': 'javascript',
    '.mjs': 'javascript',
    '.cjs': 'javascript',
  };

  final GitRepositoryStore store;
  final _files = <String, ({String hash, List<CompletionSymbol> symbols})>{};
  DateTime _checkedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void>? _refreshing;
  Future<void>? _loading;
  String _activeSource = '', _activeLanguage = '';
  List<CompletionSymbol> _activeSymbols = const [];

  EditorController? _activeDocument;
  int _activeRevision = -1;
  List<_CompletionLine> _activeLines = [];
  int activeLinesParsed = 0;

  bool angularDetected = false;
  bool reactDetected = false;

  bool get refreshing => _refreshing != null;

  Future<void> initialize() async {
    try {
      await _loadCache();
      await refresh();
    } catch (_) {
      // A workspace can be closed or removed while the background index starts.
      // Completion is optional, so a stale workspace must not fail the session.
    }
  }

  List<CompletionSymbol> suggest({
    required String source,
    required int offset,
    required String language,
    int limit = 12,
    Map<String, dynamic> snippets = const {},
    EditorController? document,
    bool explicit = false,
  }) {
    final before = source.substring(0, offset.clamp(0, source.length));
    final access = RegExp(
      language == 'php'
          ? r'([A-Za-z_$][\w$]*)(?:\?->|->|::)([A-Za-z_$][\w$]*)?$'
          : r'([A-Za-z_$][\w$]*)\??\.([A-Za-z_$][\w$]*)?$',
    ).firstMatch(before);
    final word = access == null
        ? RegExp(r'([A-Za-z_$][\w$]*)$').firstMatch(before)
        : null;
    final argument = language == 'dart' ? dartArgumentContext(before) : null;
    if (access == null && word == null && argument == null && !explicit) {
      return const [];
    }
    unawaited(refreshIfStale().catchError((_) {}));
    final receiver = access?.group(1) ?? '';
    final prefix = access == null
        ? (word?.group(1) ?? '')
        : (access.group(2) ?? '');
    if (document != null) {
      _updateActiveDocument(document, language);
    } else if (_activeSource != source ||
        _activeLanguage != language ||
        _activeDocument != null) {
      _activeDocument = null;
      _activeSource = source;
      _activeLanguage = language;
      _activeSymbols = _parse('<current>', source, language);
    }
    if (argument != null) {
      final named = dartArgumentSuggestions(
        source: source,
        offset: offset,
        symbols: [..._activeSymbols, ..._files.values.expand((f) => f.symbols)],
        limit: limit,
      );
      if (named != null) return named;
    }
    if (access == null && word == null && !explicit) return const [];
    final owner = (receiver == 'this' || receiver == r'$this')
        ? document != null && _activeLines.isNotEmpty
              ? _activeLines[document.buffer.positionAt(offset).line]
                    .after
                    .owner
              : _enclosingType(before)
        : _receiverType(before, receiver, language);
    final lowerPrefix = prefix.toLowerCase();
    var all =
        [..._files.values.expand((file) => file.symbols), ..._activeSymbols]
            .where((symbol) => symbol.language == language)
            .where(
              (symbol) =>
                  prefix.isEmpty ||
                  symbol.name.toLowerCase().startsWith(lowerPrefix),
            )
            .toList();
    if (access != null) {
      final members = all.where(
        (symbol) => symbol.kind != CompletionKind.variable,
      );
      final owned = owner.isEmpty
          ? const <CompletionSymbol>[]
          : members.where((symbol) => symbol.owner == owner).toList();
      all = owned.isNotEmpty ? owned : members.toList();
    } else {
      all = all
          .where(
            (symbol) =>
                symbol.path == '<current>' ||
                symbol.kind != CompletionKind.variable,
          )
          .toList();
    }
    if (access == null) {
      all.addAll(
        snippetSuggestions(
          prefix: prefix,
          language: language,
          snippets: {
            ...snippets,
            if (angularDetected) ...angularSnippetsFor(language),
            if (reactDetected) ...reactSnippetsFor(language),
          },
        ),
      );
    }
    all.sort((a, b) {
      final snippetOrder =
          (a.kind == CompletionKind.snippet ? 1 : 0) -
          (b.kind == CompletionKind.snippet ? 1 : 0);
      if (snippetOrder != 0) return snippetOrder;
      final aOwner = owner.isNotEmpty && a.owner == owner ? 0 : 1;
      final bOwner = owner.isNotEmpty && b.owner == owner ? 0 : 1;
      if (aOwner != bOwner) return aOwner.compareTo(bOwner);
      final docs =
          (a.documentation.isEmpty ? 1 : 0) - (b.documentation.isEmpty ? 1 : 0);
      return docs != 0 ? docs : a.name.compareTo(b.name);
    });
    final unique = <String>{};
    return all
        .where(
          (item) =>
              unique.add('${item.kind.name}:${item.owner}:${item.signature}'),
        )
        .take(limit)
        .toList();
  }

  void _updateActiveDocument(EditorController document, String language) {
    final sameDocument =
        _activeDocument == document && _activeLanguage == language;
    if (sameDocument && _activeRevision == document.revision) return;
    final range = sameDocument
        ? document.changedLinesSince(_activeRevision)
        : (first: 0, last: document.buffer.lineCount - 1);
    final old = sameDocument ? _activeLines : <_CompletionLine>[];
    final first = range.first.clamp(0, old.length);
    final next = old.take(first).toList();
    var context = first == 0 ? _ParseContext() : old[first - 1].after.copy();
    for (var line = first; line < document.buffer.lineCount; line++) {
      // Text beyond the reported range is unchanged. Stop once parser state agrees.
      if (line > range.last &&
          old.length == document.buffer.lineCount &&
          context.same(old[line - 1].after)) {
        next.addAll(old.skip(line));
        break;
      }
      final symbols = _parse(
        '<current>',
        document.buffer.getLine(line),
        language,
        context,
      );
      activeLinesParsed++;
      next.add(_CompletionLine(context.copy(), symbols));
    }
    _activeLines = next;
    _activeDocument = document;
    _activeRevision = document.revision;
    _activeLanguage = language;
    _activeSource = '';
    _activeSymbols = next.expand((line) => line.symbols).toList();
  }

  static List<CompletionSymbol>? dartArgumentSuggestions({
    required String source,
    required int offset,
    Iterable<CompletionSymbol> symbols = const [],
    int limit = 12,
  }) {
    final argument = dartArgumentContext(
      source.substring(0, offset.clamp(0, source.length)),
    );
    if (argument != null) {
      if (argument.parameter != null) {
        if (!flutterUiImport(source)) return null;
        final declarations = flutterNamedArguments[argument.call];
        if (declarations == null) return null;
        final parameter = dartNamedParameters(
          declarations,
        ).where((p) => p.name == argument.parameter).firstOrNull;
        if (parameter == null) return null;
        final type = parameter.declaration
            .replaceFirst('required ', '')
            .split(' ')
            .first
            .replaceAll('?', '');
        final values = flutterArgumentValues[type];
        if (values == null) return null;
        final material =
            type == 'Color' && flutterUiImport(source, materialOnly: true);
        return values
            .where(
              (v) =>
                  v
                      .replaceFirst('const ', '')
                      .toLowerCase()
                      .startsWith(argument.prefix.toLowerCase()) ||
                  v
                      .split('.')
                      .last
                      .toLowerCase()
                      .startsWith(argument.prefix.toLowerCase()),
            )
            .where((v) => !v.startsWith('Colors.') || material)
            .take(limit)
            .map(
              (v) => CompletionSymbol(
                name: v,
                signature: v,
                language: 'dart',
                kind: CompletionKind.constant,
                insertText: v,
                replacementLength: argument.prefix.length,
                documentation:
                    '$type value for ${argument.call}.${argument.parameter}${v.contains('(8)') || v.contains(': 8') ? '; adjust the example spacing' : ''}',
              ),
            )
            .toList();
      }
      final parameters = <String>[];
      for (final symbol in symbols) {
        if (symbol.language != 'dart' ||
            symbol.name != argument.call &&
                symbol.name != argument.call.split('.').last) {
          continue;
        }
        final start = symbol.signature.indexOf('{');
        final end = symbol.signature.lastIndexOf('}');
        if (start >= 0 && end > start) {
          parameters.add(symbol.signature.substring(start + 1, end));
        }
      }
      if (importsFlutter(source) &&
          flutterNamedArguments.containsKey(argument.call)) {
        parameters.add(flutterNamedArguments[argument.call]!);
      }
      if (parameters.isNotEmpty) {
        final seen = <String>{};
        return parameters
            .expand(dartNamedParameters)
            .where(
              (p) =>
                  p.name.startsWith(argument.prefix) &&
                  !argument.used.contains(p.name) &&
                  seen.add(p.name),
            )
            .map(
              (p) => CompletionSymbol(
                name: p.name,
                signature: p.declaration,
                language: 'dart',
                kind: CompletionKind.property,
                insertText: '${p.name}: ',
                documentation: 'Named argument of ${argument.call}',
                owner: argument.call,
              ),
            )
            .take(limit)
            .toList();
      }
    }
    return null;
  }

  static List<CompletionSymbol> snippetSuggestions({
    required String prefix,
    required String language,
    required Map<String, dynamic> snippets,
  }) {
    if (prefix.isEmpty) return const [];
    final lowerPrefix = prefix.toLowerCase();
    final result = <CompletionSymbol>[];
    for (final entry in snippets.entries) {
      final value = entry.value;
      if (value is! Map || value['body'] is! String) continue;
      final name = value['prefix'] as String? ?? entry.key;
      if (!name.toLowerCase().startsWith(lowerPrefix)) continue;
      result.add(
        CompletionSymbol(
          name: name,
          signature: '$name · snippet',
          language: language,
          kind: CompletionKind.snippet,
          documentation:
              value['description'] as String? ?? 'Insert code template',
          insertText: value['body'] as String,
        ),
      );
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  Future<void> refreshIfStale() async {
    if (DateTime.now().difference(_checkedAt) < const Duration(seconds: 10)) {
      return;
    }
    await refresh();
  }

  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() {
    _refreshing = null;
  });

  Future<void> _refresh() async {
    await _loadCache();
    _checkedAt = DateTime.now();
    angularDetected = await _detectAngular();
    reactDetected = await _detectReact();
    final paths = (await store.listFiles(''))
        .where((path) => _language(path) != null)
        .where((path) => !path.startsWith('.tamtoot/'))
        .where(
          (path) => !path
              .split('/')
              .any(
                {'node_modules', 'build', '.dart_tool', '.git', 'obj'}.contains,
              ),
        )
        .toSet();
    var changed = _files.keys.any((path) => !paths.contains(path));
    _files.removeWhere((path, _) => !paths.contains(path));
    for (final path in paths) {
      String source;
      try {
        source = await store.readText(path);
      } catch (_) {
        // A removed or unreadable file must not prevent indexing its siblings.
        changed = _files.remove(path) != null || changed;
        continue;
      }
      final hash = sha1.convert(utf8.encode(source)).toString();
      if (_files[path]?.hash == hash) continue;
      _files[path] = (
        hash: hash,
        symbols: _parse(path, source, _language(path)!),
      );
      changed = true;
    }
    if (changed) await _saveCache();
  }

  Future<bool> _detectAngular() async {
    for (final path in ['angular.json', 'package.json']) {
      try {
        if (!await store.exists(path)) continue;
        final text = await store.readText(path);
        if (text.length > 262144) continue;
        final config = jsonDecode(text);
        if (config is! Map) continue;
        if (path == 'angular.json' && config['projects'] is Map) return true;
        for (final key in ['dependencies', 'devDependencies']) {
          final dependencies = config[key];
          if (dependencies is Map && dependencies['@angular/core'] is String) {
            return true;
          }
        }
      } catch (_) {
        // Invalid/unreadable manifests do not prevent ordinary completion.
      }
    }
    return false;
  }

  Future<bool> _detectReact() async {
    try {
      if (!await store.exists('package.json')) return false;
      final text = await store.readText('package.json');
      if (text.length > 262144) return false;
      final config = jsonDecode(text);
      if (config is! Map) return false;
      for (final key in ['dependencies', 'devDependencies']) {
        final dependencies = config[key];
        if (dependencies is Map && dependencies['react'] is String) return true;
      }
    } catch (_) {
      // An invalid manifest must not break ordinary completion.
    }
    return false;
  }

  Future<void> _loadCache() => _loading ??= _readCache();

  Future<void> _readCache() async {
    if (!await store.exists(cachePath)) return;
    try {
      final json = jsonDecode(await store.readText(cachePath));
      if (json is! Map || json['version'] != 7 || json['files'] is! Map) return;
      for (final entry in (json['files'] as Map).entries) {
        final value = entry.value;
        if (value is! Map ||
            value['hash'] is! String ||
            value['symbols'] is! List) {
          continue;
        }
        _files[entry.key.toString()] = (
          hash: value['hash'] as String,
          symbols: [
            for (final item in value['symbols'] as List)
              if (item is Map)
                CompletionSymbol.fromJson(Map<String, dynamic>.from(item)),
          ],
        );
      }
    } catch (_) {
      _files.clear();
    }
  }

  Future<void> _saveCache() async {
    await store.validateRegularFilePath(cachePath);
    await store.writeText(
      cachePath,
      jsonEncode({
        'version': 7,
        'files': {
          for (final entry in _files.entries)
            entry.key: {
              'hash': entry.value.hash,
              'symbols': entry.value.symbols
                  .map((item) => item.toJson())
                  .toList(),
            },
        },
      }),
    );
  }

  String? _language(String path) {
    final lower = path.toLowerCase();
    for (final entry in _extensions.entries) {
      if (lower.endsWith(entry.key)) return entry.value;
    }
    return null;
  }

  List<CompletionSymbol> _parse(
    String path,
    String source,
    String language, [
    _ParseContext? context,
  ]) {
    if (language == 'php') return _parsePhp(path, source, context);
    final symbols = <CompletionSymbol>[];
    final lines = const LineSplitter().convert(source);
    var owner = context?.owner ?? '',
        depth = context?.depth ?? 0,
        ownerDepth = context?.ownerDepth ?? -1,
        blockComment = context?.blockComment ?? false;
    var dartPending = context?.dartPending ?? '';
    final comments = context?.comments ?? <String>[];
    for (final raw in lines) {
      var line = raw.trim();
      if (dartPending.isEmpty && line.startsWith('/*')) blockComment = true;
      if (dartPending.isEmpty && (blockComment || line.startsWith('//'))) {
        final cleaned = line
            .replaceFirst(RegExp(r'^/\*+'), '')
            .replaceFirst(RegExp(r'^//+'), '')
            .replaceFirst(RegExp(r'^\*'), '')
            .replaceFirst(RegExp(r'\*/$'), '')
            .trim();
        if (cleaned.isNotEmpty && dartPending.isEmpty) comments.add(cleaned);
        if (comments.length > 32) comments.removeAt(0);
        if (line.endsWith('*/')) blockComment = false;
        continue;
      }
      RegExpMatch? dartHeader;
      int dartEnd = -1;
      if (language == 'dart') {
        if (dartPending.isNotEmpty) {
          line = '$dartPending\n$line';
        }
        if (dartPending.isNotEmpty ||
            (owner.isEmpty ? depth == 0 : depth == ownerDepth + 1)) {
          dartHeader = dartDeclarationHeader(line, owner);
        }
        if (dartHeader != null) {
          dartEnd = dartDeclarationEnd(line, dartHeader.end - 1);
          if (dartEnd < 0 && line.length <= 16384) {
            dartPending = line;
            continue;
          }
        }
        dartPending = '';
      }
      final type = RegExp(
        r'\b(?:class|interface|extension|record(?:\s+struct)?|struct|enum|mixin|object)\s+([A-Za-z_$][\w$]*)',
      ).firstMatch(line);
      if (type != null) {
        owner = type.group(1)!;
        ownerDepth = depth;
      }
      final match = language == 'dart'
          ? null
          : language == 'typescript'
          ? RegExp(
              r'^(?:(?:export|default|public|private|protected|static|abstract|override|async|declare)\s+)*(?:function\s+)?([A-Za-z_$][\w$]*)(<[^()]+>)?\s*\(([^)]*)\)',
            ).firstMatch(line)
          : language == 'kotlin'
          ? RegExp(
              r'^(?:(?:public|private|protected|internal|override|open|abstract|final|inline|suspend|tailrec|operator|infix|external)\s+)*fun\s+(<[^()]+>\s*)?([A-Za-z_$][\w$]*)\s*\(([^)]*)\)',
            ).firstMatch(line)
          : language == 'javascript'
          ? RegExp(
              r'^(?:async\s+)?(?:function\s+)?([A-Za-z_$][\w$]*)(?:<[^()]+>)?\s*\(([^)]*)\)',
            ).firstMatch(line)
          : RegExp(
              r'^(?:(?:public|private|protected|internal|static|async|virtual|override|final|external|abstract)\s+)*(?:[\w<>,.?\[\]]+\s+)+([A-Za-z_$][\w$]*)(<[^()]+>)?\s*\(([^)]*)\)',
            ).firstMatch(line);
      if ((dartHeader != null && dartEnd >= 0 || match != null) &&
          !{'if', 'for', 'while', 'switch', 'catch'}.contains(
            dartHeader?.group(1) ?? match!.group(language == 'kotlin' ? 2 : 1),
          )) {
        final declarationName =
            dartHeader?.group(1) ?? match!.group(language == 'kotlin' ? 2 : 1)!;
        final method = declarationName.split('.').last;
        final typeParameters = language == 'javascript'
            ? ''
            : (dartHeader?.group(2) ??
                      match?.group(language == 'kotlin' ? 1 : 2) ??
                      '')
                  .trim();
        final parameters = dartHeader != null && dartEnd >= 0
            ? dartWithoutComments(
                line.substring(dartHeader.end, dartEnd),
              ).replaceAll(RegExp(r'\s+'), ' ').trim()
            : match!.group(language == 'javascript' ? 2 : 3)!.trim();
        symbols.add(
          CompletionSymbol(
            name: method,
            signature: '$declarationName$typeParameters($parameters)',
            language: language,
            owner: owner,
            documentation: comments.join(' '),
            path: path,
          ),
        );
        if (path == '<current>') {
          for (final parameter in _parameters(parameters, path, language)) {
            symbols.add(parameter);
          }
        }
      } else if (type == null) {
        final property = language == 'javascript'
            ? null
            : RegExp(
                r'^(?:(?:public|private|protected|internal|static|virtual|override|abstract|required|late|final)\s+)*([\w<>,.?\[\]]+)\s+(?:get\s+)?([A-Za-z_$][\w$]*)\s*(?:\{[^}]*\b(?:get|set|init)\b|=>)',
              ).firstMatch(line);
        if (property != null) {
          final name = property.group(2)!;
          symbols.add(
            CompletionSymbol(
              name: name,
              signature: '$name: ${property.group(1)!}',
              language: language,
              kind: CompletionKind.property,
              owner: owner,
              documentation: comments.join(' '),
              path: path,
            ),
          );
        } else {
          final declaration = _declaration(line, language);
          if (declaration != null) {
            final directMember = owner.isNotEmpty && depth == ownerDepth + 1;
            final kind = declaration.constant
                ? CompletionKind.constant
                : directMember
                ? CompletionKind.field
                : CompletionKind.variable;
            symbols.add(
              CompletionSymbol(
                name: declaration.name,
                signature: declaration.type.isEmpty
                    ? declaration.name
                    : '${declaration.name}: ${declaration.type}',
                language: language,
                kind: kind,
                owner: directMember ? owner : '',
                documentation: comments.join(' '),
                path: path,
              ),
            );
          }
        }
      }
      if (line.isNotEmpty) comments.clear();
      depth += '{'.allMatches(line).length - '}'.allMatches(line).length;
      if (owner.isNotEmpty &&
          depth <= ownerDepth &&
          type == null &&
          line == '}') {
        owner = '';
        ownerDepth = -1;
      }
    }
    if (context != null) {
      context.dartPending = dartPending;
      context.owner = owner;
      context.depth = depth;
      context.ownerDepth = ownerDepth;
      context.blockComment = blockComment;
    }
    return symbols;
  }

  ({String name, String type, bool constant})? _declaration(
    String line,
    String language,
  ) {
    if (language == 'typescript') {
      final match = RegExp(
        r'^(?:(?:export|public|private|protected|static|declare|readonly)\s+)*(?:(const|let|var)\s+)?([A-Za-z_$][\w$]*)(?:[!?])?(?:\s*:\s*([\w<>,.?\[\]|]+))?\s*(?:=|;|$)',
      ).firstMatch(line);
      if (match == null ||
          {
            'return',
            'throw',
            'break',
            'continue',
            'import',
          }.contains(match.group(2))) {
        return null;
      }
      if (match.group(1) == null &&
          match.group(3) == null &&
          !RegExp(r'[=;]').hasMatch(line)) {
        return null;
      }
      return (
        name: match.group(2)!,
        type: match.group(3) ?? '',
        constant: match.group(1) == 'const',
      );
    }
    if (language == 'kotlin') {
      final match = RegExp(
        r'^(?:(?:public|private|protected|internal|override|open|final|lateinit|const)\s+)*(val|var)\s+([A-Za-z_$][\w$]*)(?:\s*:\s*([\w<>,.?\[\]]+))?\s*(?:=|$)',
      ).firstMatch(line);
      if (match == null) return null;
      return (
        name: match.group(2)!,
        type: match.group(3) ?? '',
        constant: RegExp(r'\bconst\b').hasMatch(line),
      );
    }
    if (language == 'javascript') {
      final match = RegExp(
        r'^(const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?:=|;)',
      ).firstMatch(line);
      if (match == null) return null;
      return (
        name: match.group(2)!,
        type: '',
        constant: match.group(1) == 'const',
      );
    }
    final inferred = RegExp(
      r'^(?:(?:public|private|protected|internal|static|late)\s+)*(final|const|var)\s+(?:([\w<>,.?\[\]]+)\s+)?([A-Za-z_$][\w$]*)\s*(?:=|;)',
    ).firstMatch(line);
    if (inferred != null) {
      return (
        name: inferred.group(3)!,
        type: inferred.group(2) ?? '',
        constant: inferred.group(1) == 'const',
      );
    }
    final typed = RegExp(
      r'^(?:(?:public|private|protected|internal|static|late|required|readonly)\s+)*([\w<>,.?\[\]]+)\s+([A-Za-z_$][\w$]*)\s*(?:=|;)',
    ).firstMatch(line);
    if (typed == null || {'return', 'throw', 'new'}.contains(typed.group(1))) {
      return null;
    }
    return (
      name: typed.group(2)!,
      type: typed.group(1)!,
      constant: RegExp(r'\b(?:const|readonly)\b').hasMatch(line),
    );
  }

  List<CompletionSymbol> _parameters(
    String source,
    String path,
    String language,
  ) {
    final result = <CompletionSymbol>[];
    for (final raw in source.split(',')) {
      final parameter = raw
          .split('=')
          .first
          .trim()
          .replaceFirst(RegExp(r'^(?:required|final|ref|out|in|this)\s+'), '');
      if (language == 'kotlin' || language == 'typescript') {
        final match = RegExp(
          r'(?:[\w]+\s+)*([A-Za-z_$][\w$]*)\??\s*:\s*(.+)',
        ).firstMatch(parameter);
        if (match != null) {
          result.add(
            CompletionSymbol(
              name: match.group(1)!,
              signature: '${match.group(1)}: ${match.group(2)}',
              language: language,
              kind: CompletionKind.variable,
              path: path,
            ),
          );
        }
        continue;
      }
      final parts = parameter.split(RegExp(r'\s+'));
      if (parts.isEmpty || parts.last.isEmpty) continue;
      final name = parts.last.replaceAll(RegExp(r'[^A-Za-z0-9_$]'), '');
      if (!RegExp(r'^[A-Za-z_$][\w$]*$').hasMatch(name)) continue;
      result.add(
        CompletionSymbol(
          name: name,
          signature: parts.length > 1
              ? '$name: ${parts.sublist(0, parts.length - 1).join(' ')}'
              : name,
          language: language,
          kind: CompletionKind.variable,
          path: path,
        ),
      );
    }
    return result;
  }

  List<CompletionSymbol> _parsePhp(
    String path,
    String source, [
    _ParseContext? context,
  ]) {
    final symbols = <CompletionSymbol>[];
    var owner = context?.owner ?? '',
        depth = context?.depth ?? 0,
        ownerDepth = context?.ownerDepth ?? -1,
        blockComment = context?.blockComment ?? false;
    for (final raw in const LineSplitter().convert(source)) {
      final line = raw.trim();
      if (line.startsWith('/*')) blockComment = true;
      if (blockComment || line.startsWith('//') || line.startsWith('#')) {
        if (line.endsWith('*/')) blockComment = false;
        continue;
      }
      final type = RegExp(
        r'\b(?:class|interface|trait|enum)\s+([A-Za-z_]\w*)',
      ).firstMatch(line);
      if (type != null) {
        owner = type.group(1)!;
        ownerDepth = depth;
      }
      final method = RegExp(
        r'^(?:(?:public|private|protected|static|final|abstract)\s+)*function\s+&?\s*([A-Za-z_]\w*)\s*\(([^)]*)\)',
      ).firstMatch(line);
      if (method != null) {
        symbols.add(
          CompletionSymbol(
            name: method.group(1)!,
            signature: '${method.group(1)}(${method.group(2)})',
            language: 'php',
            owner: owner,
            path: path,
          ),
        );
        if (path == '<current>') {
          symbols.addAll(_parameters(method.group(2)!, path, 'php'));
        }
      } else if (type == null) {
        final variable = RegExp(
          r'^(?:(?:public|private|protected|static|readonly|var)\s+)*(?:([\w\\?|]+)\s+)?(\$[A-Za-z_]\w*)\s*(?:=|;)',
        ).firstMatch(line);
        if (variable != null) {
          final member = owner.isNotEmpty && depth == ownerDepth + 1;
          final name = member
              ? variable.group(2)!.substring(1)
              : variable.group(2)!;
          symbols.add(
            CompletionSymbol(
              name: name,
              signature: '$name: ${variable.group(1) ?? 'mixed'}',
              language: 'php',
              kind: member ? CompletionKind.field : CompletionKind.variable,
              owner: member ? owner : '',
              path: path,
            ),
          );
        }
      }
      depth += '{'.allMatches(raw).length - '}'.allMatches(raw).length;
      if (owner.isNotEmpty &&
          depth <= ownerDepth &&
          type == null &&
          line == '}') {
        owner = '';
        ownerDepth = -1;
      }
    }
    if (context != null) {
      context.owner = owner;
      context.depth = depth;
      context.ownerDepth = ownerDepth;
      context.blockComment = blockComment;
    }
    return symbols;
  }

  String _enclosingType(String source) {
    var owner = '', depth = 0, ownerDepth = -1;
    for (final raw in const LineSplitter().convert(source)) {
      final match = RegExp(
        r'\b(?:class|interface|extension|record(?:\s+struct)?|struct|enum|mixin|object)\s+([A-Za-z_$][\w$]*)',
      ).firstMatch(raw);
      if (match != null) {
        owner = match.group(1)!;
        ownerDepth = depth;
      }
      depth += '{'.allMatches(raw).length - '}'.allMatches(raw).length;
      if (owner.isNotEmpty && depth <= ownerDepth && match == null) owner = '';
    }
    return owner;
  }

  String _receiverType(String source, String receiver, String language) {
    final escaped = RegExp.escape(receiver);
    if (language == 'php') {
      final created = RegExp(
        escaped + r'\s*=\s*new\s+([A-Za-z_]\w*)',
      ).allMatches(source).lastOrNull;
      return created?.group(1) ?? receiver;
    }
    if (language == 'kotlin' || language == 'typescript') {
      final typed = RegExp(
        r'\b' + escaped + r'\s*:\s*([A-Za-z_$][\w$]*)',
      ).allMatches(source).lastOrNull;
      if (typed != null) return typed.group(1)!;
    }
    final typed = RegExp(
      r'([A-Za-z_$][\w$<>.?]*)\s+' + escaped + r'\b',
    ).allMatches(source).lastOrNull;
    if (typed != null &&
        !{
          'var',
          'val',
          'final',
          'const',
          'let',
          'return',
        }.contains(typed.group(1))) {
      return typed.group(1)!.replaceAll(RegExp(r'[<>?].*$'), '');
    }
    final created = RegExp(
      r'(?:final|var|val|const|let)\s+' +
          escaped +
          r'\s*=\s*(?:new\s+)?([A-Za-z_$][\w$]*)\s*\(',
    ).allMatches(source).lastOrNull;
    return created?.group(1) ?? '';
  }
}
