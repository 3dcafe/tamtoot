import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../git/git_store.dart';

class CompletionSymbol {
  const CompletionSymbol({
    required this.name,
    required this.signature,
    required this.language,
    this.owner = '',
    this.documentation = '',
    this.path = '',
  });

  final String name, signature, language, owner, documentation, path;

  Map<String, dynamic> toJson() => {
    'name': name,
    'signature': signature,
    'language': language,
    'owner': owner,
    'documentation': documentation,
    'path': path,
  };

  factory CompletionSymbol.fromJson(Map<String, dynamic> json) =>
      CompletionSymbol(
        name: json['name'] as String,
        signature: json['signature'] as String,
        language: json['language'] as String,
        owner: json['owner'] as String? ?? '',
        documentation: json['documentation'] as String? ?? '',
        path: json['path'] as String? ?? '',
      );
}

class ProjectCompletionIndex {
  ProjectCompletionIndex(this.store);

  static const cachePath = '.tamtoot/cache/completions-v1.json';
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
    if (access == null) return const [];
    unawaited(refreshIfStale().catchError((_) {}));
    final receiver = access.group(1)!, prefix = access.group(2) ?? '';
    final owner = _receiverType(before, receiver, language);
    if (_activeSource != source || _activeLanguage != language) {
      _activeSource = source;
      _activeLanguage = language;
      _activeSymbols = _parse('<current>', source, language);
    }
    final lowerPrefix = prefix.toLowerCase();
    final all =
        [..._files.values.expand((file) => file.symbols), ..._activeSymbols]
            .where((symbol) => symbol.language == language)
            .where(
              (symbol) =>
                  prefix.isEmpty ||
                  symbol.name.toLowerCase().startsWith(lowerPrefix),
            )
            .toList();
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
        .where((item) => unique.add('${item.owner}:${item.signature}'))
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
                {
                  'node_modules',
                  'build',
                  '.dart_tool',
                  '.git',
                  'obj',
                }.contains,
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
      if (json is! Map || json['version'] != 1 || json['files'] is! Map) return;
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
        'version': 1,
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
