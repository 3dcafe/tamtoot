import '../core/persistence/schema.dart';

const bundledLanguageIds = [
  'dart',
  'csharp',
  'html',
  'javascript',
  'typescript',
  'xml',
  'razor',
  'css',
  'markdown',
  'conf',
];

class SyntaxToken {
  const SyntaxToken(this.start, this.end, this.scope);
  final int start, end;
  final String scope;
}

class SyntaxRule {
  SyntaxRule(
    String pattern,
    this.scope, {
    String? end,
    String? escape,
    this.nested = false,
    this.endCapture,
    this.contentRules = const [],
  }) : expression = RegExp(pattern),
       end = end == null ? null : RegExp(end),
       escape = escape == null ? null : RegExp(escape);
  final RegExp expression;
  final String scope;
  final RegExp? end, escape;
  final bool nested;
  final int? endCapture;
  final List<SyntaxRule> contentRules;
}

class SyntaxState {
  const SyntaxState(this.rule, this.end, [this.depth = 1, this.parent]);
  final SyntaxRule rule;
  final int depth;
  final SyntaxState? parent;
  final RegExp end;
}

class SyntaxLine {
  const SyntaxLine(this.tokens, this.state);
  final List<SyntaxToken> tokens;
  final SyntaxState? state;
}

/// Normalized domain model; no knowledge of JSON or editor rendering.
class LanguageDefinition {
  const LanguageDefinition({
    required this.id,
    required this.name,
    required this.version,
    required this.extensions,
    required this.rules,
    this.filenames = const [],
    this.fileTemplates = const {},
    this.comments = const {},
    this.brackets = const [],
    this.autoClosingPairs = const [],
    this.snippets = const {},
    this.indentation = const {},
    this.icons = const {},
    this.adapters = const [],
  });
  final String id, name, version;
  final List<String> extensions, filenames, adapters;
  final List<SyntaxRule> rules;
  final Map<String, dynamic> comments, snippets, indentation, icons;
  final Map<String, dynamic> fileTemplates;
  final List<dynamic> brackets, autoClosingPairs;
  List<SyntaxToken> tokenize(String line) => tokenizeLine(line).tokens;

  SyntaxLine tokenizeLine(String line, [SyntaxState? state]) {
    final tokens = <SyntaxToken>[];
    var position = 0;
    void add(int start, int end, String scope) {
      if (end <= start) return;
      if (tokens.isNotEmpty &&
          tokens.last.end == start &&
          tokens.last.scope == scope) {
        final previous = tokens.removeLast();
        tokens.add(SyntaxToken(previous.start, end, scope));
      } else {
        tokens.add(SyntaxToken(start, end, scope));
      }
    }

    SyntaxState? enter(SyntaxRule rule, Match match, [SyntaxState? parent]) {
      final captured = rule.endCapture == null
          ? null
          : match.group(rule.endCapture!);
      final end = captured == null || captured.isEmpty
          ? rule.end
          : RegExp(RegExp.escape(captured));
      return end == null ? parent : SyntaxState(rule, end, 1, parent);
    }

    while (position < line.length) {
      if (state != null) {
        final current = state;
        final rule = current.rule;
        var start = position;
        var switched = false;
        var depth = current.depth;
        while (position < line.length) {
          final escape = rule.escape?.matchAsPrefix(line, position);
          if (escape != null && escape.end > position) {
            position = escape.end;
            continue;
          }
          final end = current.end.matchAsPrefix(line, position);
          if (end != null && end.end > position) {
            position = end.end;
            if (--depth == 0) {
              state = current.parent;
              switched = true;
              break;
            }
            continue;
          }
          final nested = rule.nested
              ? rule.expression.matchAsPrefix(line, position)
              : null;
          if (nested != null && nested.end > position) {
            depth++;
            position = nested.end;
            continue;
          }
          SyntaxRule? child;
          Match? childMatch;
          for (final candidate in rule.contentRules) {
            final match = candidate.expression.matchAsPrefix(line, position);
            if (match != null && match.end > position) {
              child = candidate;
              childMatch = match;
              break;
            }
          }
          if (child != null) {
            add(start, position, rule.scope);
            add(position, childMatch!.end, child.scope);
            position = childMatch.end;
            start = position;
            state = enter(child, childMatch, current);
            if (state != current) {
              switched = true;
              break;
            }
            continue;
          }
          position++;
        }
        add(start, position, rule.scope);
        if (!switched) {
          state = SyntaxState(current.rule, current.end, depth, current.parent);
        }
        continue;
      }
      RegExpMatch? earliest;
      var chosen = -1;
      for (var i = 0; i < rules.length; i++) {
        // Keep offsets in the full line: anchors and word boundaries must not
        // reset after a previous token (e.g. @class, identifiers and directives).
        final match = rules[i].expression
            .allMatches(line, position)
            .where((m) => m.end > m.start)
            .firstOrNull;
        if (match != null &&
            (earliest == null || match.start < earliest.start)) {
          earliest = match;
          chosen = i;
        }
      }
      if (earliest == null) break;
      final rule = rules[chosen];
      add(earliest.start, earliest.end, rule.scope);
      position = earliest.end;
      state = enter(rule, earliest);
    }
    return SyntaxLine(tokens, state);
  }
}

/// v1 DTO validation and normalization stays at the package boundary.
class LanguagePackageLoader {
  LanguageDefinition load(String manifest, String syntax, {String? snippets}) {
    final m = decodeVersioned(manifest, 'Language manifest');
    final s = decodeVersioned(syntax, 'Syntax');
    final rawRules = s['rules'];
    if (rawRules is! List) {
      throw const SchemaException('syntax.rules must be an array');
    }
    SyntaxRule parseRule(dynamic raw, int depth) {
      if (depth > 8) throw const SchemaException('Syntax nesting too deep');
      if (raw is! Map<String, dynamic>) {
        throw const SchemaException('Invalid syntax rule');
      }
      try {
        final begin = raw['begin'];
        if (begin != null && (begin is! String || raw.containsKey('pattern'))) {
          throw const SchemaException(
            'Use either pattern or begin for a syntax rule',
          );
        }
        final capture = raw['endCapture'];
        if (capture != null && (capture is! int || capture < 1)) {
          throw const SchemaException(
            'endCapture must be a positive group number',
          );
        }
        if (begin != null && raw['end'] == null && capture == null) {
          throw const SchemaException('begin requires end or endCapture');
        }
        if (begin == null &&
            (raw['end'] != null ||
                capture != null ||
                raw['escape'] != null ||
                raw['nested'] != null ||
                raw['contentRules'] != null)) {
          throw const SchemaException('Region options require begin');
        }
        if (raw['nested'] != null && raw['nested'] is! bool) {
          throw const SchemaException('nested must be boolean');
        }
        final children = raw['contentRules'] ?? [];
        if (children is! List) {
          throw const SchemaException('contentRules must be an array');
        }
        final rule = SyntaxRule(
          requiredString(raw, begin == null ? 'pattern' : 'begin'),
          requiredString(raw, 'scope'),
          end: raw['end'] == null ? null : requiredString(raw, 'end'),
          escape: raw['escape'] == null ? null : requiredString(raw, 'escape'),
          nested: raw['nested'] == true,
          endCapture: capture as int?,
          contentRules: [
            for (final child in children) parseRule(child, depth + 1),
          ],
        );
        if (rule.expression.hasMatch('') ||
            rule.end?.hasMatch('') == true ||
            rule.escape?.hasMatch('') == true) {
          throw const SchemaException('Syntax patterns must consume text');
        }
        // Validate capture existence even when begin cannot match a sample.
        if (capture != null) {
          final probe = RegExp(
            '(?:${rule.expression.pattern})|',
          ).firstMatch('')!;
          if (capture > probe.groupCount) {
            throw const SchemaException('Invalid endCapture group');
          }
        }
        return rule;
      } on FormatException catch (e) {
        throw SchemaException('Invalid token regex: ${e.message}');
      }
    }

    final rules = [for (final raw in rawRules) parseRule(raw, 0)];
    Map<String, dynamic> object(String key) {
      final raw = m[key] ?? <String, dynamic>{};
      if (raw is! Map<String, dynamic>) throw SchemaException('Invalid $key');
      return raw;
    }

    List<dynamic> pairs(String key) {
      final raw = m[key] ?? [];
      if (raw is! List) throw SchemaException('Invalid $key');
      for (final pair in raw) {
        if (pair is! Map<String, dynamic>) {
          throw SchemaException('Invalid $key pair');
        }
        requiredString(pair, 'open');
        requiredString(pair, 'close');
      }
      return raw;
    }

    final snippetData = snippets == null
        ? <String, dynamic>{}
        : decodeVersioned(snippets, 'Snippets');
    if (snippetData['snippets'] != null &&
        snippetData['snippets'] is! Map<String, dynamic>) {
      throw const SchemaException('Invalid snippets');
    }
    final templates = object('fileTemplates');
    for (final template in templates.values) {
      if (template is! Map<String, dynamic>) {
        throw const SchemaException('Invalid file template');
      }
      requiredString(template, 'name');
      requiredString(template, 'extension');
      if (template['body'] is! String) {
        throw const SchemaException('Invalid template body');
      }
    }
    return LanguageDefinition(
      id: requiredString(m, 'id'),
      name: requiredString(m, 'name'),
      version: requiredString(m, 'packageVersion'),
      extensions: stringList(m['extensions'], 'extensions'),
      filenames: stringList(m['filenames'] ?? [], 'filenames'),
      rules: rules,
      fileTemplates: templates,
      comments: object('comments'),
      brackets: pairs('brackets'),
      autoClosingPairs: pairs('autoClosingPairs'),
      indentation: object('indentation'),
      icons: object('icons'),
      adapters: stringList(m['adapters'] ?? [], 'adapters'),
      snippets: snippetData['snippets'] as Map<String, dynamic>? ?? {},
    );
  }
}

class LanguageRegistry {
  final Map<String, LanguageDefinition> _languages = {};
  Iterable<LanguageDefinition> get all => _languages.values;
  void register(LanguageDefinition language) =>
      _languages[language.id] = language;
  LanguageDefinition? forPath(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    final lower = name.toLowerCase();
    for (final language in _languages.values) {
      if (language.filenames.contains(name) ||
          language.extensions.any(
            (extension) => lower.endsWith(extension.toLowerCase()),
          )) {
        return language;
      }
    }
    return null;
  }
}

/// Generic provider boundary; a future LSP adapter implements this contract.
abstract interface class LanguageServiceProvider {
  Set<String> get capabilities;
  Future<Object?> request(
    String operation,
    Uri document,
    int revision,
    Map<String, Object?> parameters,
  );
  Stream<List<LanguageDiagnostic>> get diagnostics;
}

class LanguageDiagnostic {
  const LanguageDiagnostic(
    this.document,
    this.revision,
    this.start,
    this.end,
    this.message,
    this.severity,
  );
  final Uri document;
  final int revision, start, end;
  final String message, severity;
}
