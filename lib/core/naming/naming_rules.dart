import '../settings/settings.dart';

enum NameStyle {
  any('No check'),
  camel('camelCase'),
  pascal('PascalCase'),
  snake('snake_case'),
  upperSnake('UPPER_SNAKE_CASE'),
  camelOrPascal('camelCase / PascalCase'),
  camelOrUpperSnake('camelCase / UPPER_SNAKE_CASE');

  const NameStyle(this.label);
  final String label;
  bool accepts(String name) {
    name = name
        .replaceFirst(RegExp(r'^[@\$_]+'), '')
        .replaceFirst(RegExp(r'_+$'), '');
    if (name.isEmpty || !RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(name)) {
      return true;
    }
    final camel = RegExp(r'^[a-z][A-Za-z0-9]*$').hasMatch(name);
    final pascal = RegExp(r'^[A-Z][A-Za-z0-9]*$').hasMatch(name);
    final snake = RegExp(r'^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$').hasMatch(name);
    final upper = RegExp(r'^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*$').hasMatch(name);
    return switch (this) {
      any => true,
      NameStyle.camel => camel,
      NameStyle.pascal => pascal,
      NameStyle.snake => snake,
      upperSnake => upper,
      camelOrPascal => camel || pascal,
      camelOrUpperSnake => camel || upper,
    };
  }
}

enum NameKind { type, function, variable, property, constant }

class NamingProfile {
  const NamingProfile({this.enabled = true, required this.rules});
  final bool enabled;
  final Map<NameKind, NameStyle> rules;
  static const languages = {
    'dart': 'Dart / Flutter',
    'csharp': 'C#',
    'python': 'Python',
    'java': 'Java',
    'kotlin': 'Kotlin',
    'php': 'PHP',
    'javascript': 'JavaScript',
    'typescript': 'TypeScript',
  };
  static NamingProfile defaults(String language) {
    final python = language == 'python', cs = language == 'csharp';
    final js = language == 'javascript' || language == 'typescript';
    return NamingProfile(
      rules: {
        NameKind.type: NameStyle.pascal,
        NameKind.function: python
            ? NameStyle.snake
            : cs
            ? NameStyle.pascal
            : js
            ? NameStyle.camelOrPascal
            : NameStyle.camel,
        NameKind.variable: python ? NameStyle.snake : NameStyle.camel,
        NameKind.property: python
            ? NameStyle.snake
            : cs
            ? NameStyle.pascal
            : NameStyle.camel,
        NameKind.constant: cs
            ? NameStyle.pascal
            : language == 'dart'
            ? NameStyle.camel
            : js
            ? NameStyle.camelOrUpperSnake
            : NameStyle.upperSnake,
      },
    );
  }

  factory NamingProfile.forProject(
    SettingsService settings,
    Uri? root,
    String language,
  ) {
    final defaults = NamingProfile.defaults(language);
    if (root == null) {
      return NamingProfile(enabled: false, rules: defaults.rules);
    }
    final projects = settings.get('projectNaming') as Map;
    final project = projects[root.toString()];
    final languages = project is Map ? project['languages'] : null;
    final overrides = languages is Map ? languages[language] : null;
    return NamingProfile(
      enabled: project is! Map || project['enabled'] != false,
      rules: {
        for (final kind in NameKind.values)
          kind: overrides is Map
              ? NameStyle.values
                        .where((s) => s.name == overrides[kind.name])
                        .firstOrNull ??
                    defaults.rules[kind]!
              : defaults.rules[kind]!,
      },
    );
  }
  String get key =>
      '$enabled:${NameKind.values.map((k) => rules[k]!.name).join(',')}';
}
