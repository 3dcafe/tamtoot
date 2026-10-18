import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/languages/language_registry.dart';
import 'language_syntax_test.dart' show loadLanguage, scopeAt;

void main() {
  test(
    'Dockerfile variants and YAML configuration paths resolve automatically',
    () {
      final registry = LanguageRegistry();
      for (final id in bundledLanguageIds) {
        registry.register(loadLanguage(id));
      }
      for (final path in [
        'Dockerfile',
        'Dockerfile.dev',
        'dockerfile.prod',
        'Containerfile',
        'build.dockerfile',
        r'C:\repo\Dockerfile',
      ]) {
        expect(registry.forPath(path)?.id, 'dockerfile', reason: path);
      }
      for (final path in [
        'compose.yaml',
        'docker-compose.yml',
        'pubspec.yaml',
        '.github/workflows/build.yml',
        'CONFIG.YAML',
      ]) {
        expect(registry.forPath(path)?.id, 'yaml', reason: path);
      }
      expect(registry.forPath('Dockerfile.md')?.id, 'markdown');
    },
  );
  test('Docker highlights instructions, flags, variables and JSON strings', () {
    final language = loadLanguage('dockerfile');
    expect(scopeAt(language, 'FROM alpine AS build', 'FROM'), 'keyword');
    expect(scopeAt(language, 'run echo hello', 'run'), 'keyword');
    expect(
      scopeAt(language, r'RUN echo "hello ${USER}"', r'${USER}'),
      'interpolation',
    );
    expect(
      scopeAt(language, 'COPY --from=build /app /app', '--from=build'),
      'attribute',
    );
    expect(
      scopeAt(language, r'ENV HOME=${APP_HOME}', r'${APP_HOME}'),
      'interpolation',
    );
    expect(
      scopeAt(language, 'CMD ["echo", "hello # world"]', 'hello # world'),
      'string',
    );
    expect(
      scopeAt(language, '# syntax=docker/dockerfile:1', '# syntax'),
      'comment',
    );
    expect(
      scopeAt(language, 'RUN echo hello # literal', '# literal'),
      isNot('comment'),
    );
  });
  test(
    'YAML highlights Compose keys, scalars, comments, anchors and documents',
    () {
      final language = loadLanguage('yaml');
      expect(scopeAt(language, 'services:', 'services'), 'property');
      expect(scopeAt(language, 'имя: значение', 'имя'), 'property');
      expect(scopeAt(language, r'value: "a\"b" # note', '# note'), 'comment');
      expect(scopeAt(language, '  replicas: 3', 'replicas'), 'property');
      expect(scopeAt(language, '  replicas: 3', '3'), 'number');
      expect(scopeAt(language, '  enabled: true', 'true'), 'constant');
      expect(
        scopeAt(language, '  value: "hello # world" # note', 'hello # world'),
        'string',
      );
      expect(
        scopeAt(language, '  value: "hello # world" # note', '# note'),
        'comment',
      );
      expect(
        scopeAt(language, '  url: https://example.com/#section', '#section'),
        isNot('comment'),
      );
      expect(
        scopeAt(language, 'defaults: &defaults', '&defaults'),
        'annotation',
      );
      expect(scopeAt(language, 'config: *defaults', '*defaults'), 'annotation');
      expect(scopeAt(language, '---', '---'), 'directive');
      expect(scopeAt(language, 'script: |-', '|-'), 'operator');
      expect(
        scopeAt(language, '"quoted key": value', '"quoted key"'),
        'property',
      );
    },
  );
}
