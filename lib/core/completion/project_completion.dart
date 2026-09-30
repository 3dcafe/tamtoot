import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../git/git_store.dart';

enum CompletionKind { method, variable, field, property, constant }

class CompletionSymbol {
  const CompletionSymbol({
    required this.name,
    required this.signature,
    required this.language,
    this.kind = CompletionKind.method,
    this.owner = '',
    this.documentation = '',
    this.path = '',
  });

  final String name, signature, language, owner, documentation, path;
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
      );
}

class ProjectCompletionIndex {
  ProjectCompletionIndex(this.store);

  static const cachePath = '.tamtoot/cache/completions-v2.json';
  static const _extensions = {
    '.dart': 'dart',
    '.cs': 'csharp',
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
  }) {
    final before = source.substring(0, offset.clamp(0, source.length));
    final access = RegExp(
      r'([A-Za-z_$][\w$]*)\.([A-Za-z_$][\w$]*)?$',
    ).firstMatch(before);
    final word = access == null
        ? RegExp(r'([A-Za-z_$][\w$]*)$').firstMatch(before)
        : null;
    if (access == null && word == null) return const [];
    unawaited(refreshIfStale().catchError((_) {}));
    final receiver = access?.group(1) ?? '';
    final prefix = access == null ? word!.group(1)! : (access.group(2) ?? '');
    final owner = receiver == 'this'
        ? _enclosingType(before)
        : _receiverType(before, receiver, language);
    if (_activeSource != source || _activeLanguage != language) {
      _activeSource = source;
      _activeLanguage = language;
      _activeSymbols = _parse('<current>', source, language);
    }
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
    all.sort((a, b) {
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

  Future<void> _loadCache() => _loading ??= _readCache();

  Future<void> _readCache() async {
    if (!await store.exists(cachePath)) return;
    try {
      final json = jsonDecode(await store.readText(cachePath));
      if (json is! Map || json['version'] != 2 || json['files'] is! Map) return;
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
        'version': 2,
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

  List<CompletionSymbol> _parse(String path, String source, String language) {
    final symbols = <CompletionSymbol>[];
    final lines = const LineSplitter().convert(source);
    var owner = '', depth = 0, ownerDepth = -1, blockComment = false;
    final comments = <String>[];
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('/*')) blockComment = true;
      if (blockComment || line.startsWith('//')) {
        final cleaned = line
            .replaceFirst(RegExp(r'^/\*+'), '')
            .replaceFirst(RegExp(r'^//+'), '')
            .replaceFirst(RegExp(r'^\*'), '')
            .replaceFirst(RegExp(r'\*/$'), '')
            .trim();
        if (cleaned.isNotEmpty) comments.add(cleaned);
        if (line.endsWith('*/')) blockComment = false;
        continue;
      }
      final type = RegExp(
        r'\b(?:class|interface|extension)\s+([A-Za-z_$][\w$]*)',
      ).firstMatch(line);
      if (type != null) {
        owner = type.group(1)!;
        ownerDepth = depth;
      }
      final match = language == 'javascript'
          ? RegExp(
              r'^(?:async\s+)?(?:function\s+)?([A-Za-z_$][\w$]*)\s*\(([^)]*)\)',
            ).firstMatch(line)
          : RegExp(
              r'^(?:(?:public|private|protected|internal|static|async|virtual|override|final|external|abstract)\s+)*(?:[\w<>,.?\[\]]+\s+)+([A-Za-z_$][\w$]*)\s*\(([^)]*)\)',
            ).firstMatch(line);
      if (match != null &&
          !{'if', 'for', 'while', 'switch', 'catch'}.contains(match.group(1))) {
        final method = match.group(1)!;
        symbols.add(
          CompletionSymbol(
            name: method,
            signature: '$method(${match.group(2)!.trim()})',
            language: language,
            owner: owner,
            documentation: comments.join(' '),
            path: path,
          ),
        );
        if (path == '<current>') {
          for (final parameter in _parameters(
            match.group(2)!,
            path,
            language,
          )) {
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
      depth += '{'.allMatches(raw).length - '}'.allMatches(raw).length;
      if (owner.isNotEmpty &&
          depth <= ownerDepth &&
          type == null &&
          line == '}') {
        owner = '';
        ownerDepth = -1;
      }
    }
    return symbols;
  }

  ({String name, String type, bool constant})? _declaration(
    String line,
    String language,
  ) {
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

  String _enclosingType(String source) {
    var owner = '', depth = 0, ownerDepth = -1;
    for (final raw in const LineSplitter().convert(source)) {
      final match = RegExp(
        r'\b(?:class|interface|extension)\s+([A-Za-z_$][\w$]*)',
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
    final typed = RegExp(
      r'([A-Za-z_$][\w$<>.?]*)\s+' + escaped + r'\b',
    ).allMatches(source).lastOrNull;
    if (typed != null &&
        !{'var', 'final', 'const', 'let', 'return'}.contains(typed.group(1))) {
      return typed.group(1)!.replaceAll(RegExp(r'[<>?].*$'), '');
    }
    final created = RegExp(
      r'(?:final|var|const|let)\s+' +
          escaped +
          r'\s*=\s*(?:new\s+)?([A-Za-z_$][\w$]*)\s*\(',
    ).allMatches(source).lastOrNull;
    return created?.group(1) ?? '';
  }
}
