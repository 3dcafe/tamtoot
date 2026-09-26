import '../core/persistence/schema.dart';

class SyntaxToken {
  const SyntaxToken(this.start, this.end, this.scope);
  final int start, end;
  final String scope;
}

class SyntaxRule {
  SyntaxRule(String pattern, this.scope) : expression = RegExp(pattern);
  final RegExp expression;
  final String scope;
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
  final List<dynamic> brackets, autoClosingPairs;
  List<SyntaxToken> tokenize(String line) {
    // Combined expression gives first-rule priority (comments/strings before keywords).
    final result = <SyntaxToken>[];
    if (rules.isEmpty) return result;
    var position = 0;
    while (position < line.length) {
      RegExpMatch? earliest;
      SyntaxRule? chosen;
      for (final rule in rules) {
        final match = rule.expression.firstMatch(line.substring(position));
        if (match != null &&
            match.end > match.start &&
            (earliest == null || match.start < earliest.start)) {
          earliest = match;
          chosen = rule;
        }
      }
      if (earliest == null) break;
      result.add(
        SyntaxToken(
          position + earliest.start,
          position + earliest.end,
          chosen!.scope,
        ),
      );
      position += earliest.end;
    }
    return result;
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
    final rules = <SyntaxRule>[];
    for (final raw in rawRules) {
      if (raw is! Map<String, dynamic>) {
        throw const SchemaException('Invalid syntax rule');
      }
      try {
        rules.add(
          SyntaxRule(
            requiredString(raw, 'pattern'),
            requiredString(raw, 'scope'),
          ),
        );
      } on FormatException catch (e) {
        throw SchemaException('Invalid token regex: ${e.message}');
      }
    }
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
    return LanguageDefinition(
      id: requiredString(m, 'id'),
      name: requiredString(m, 'name'),
      version: requiredString(m, 'packageVersion'),
      extensions: stringList(m['extensions'], 'extensions'),
      filenames: stringList(m['filenames'] ?? [], 'filenames'),
      rules: rules,
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
  Iterable<LanguageDefinition> get languages => _languages.values;
  void register(LanguageDefinition language) =>
      _languages[language.id] = language;
  LanguageDefinition? forPath(String path) {
    final name = path.split('/').last;
    for (final language in languages) {
      if (language.filenames.contains(name) ||
          language.extensions.any(name.endsWith)) {
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
