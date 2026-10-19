import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/languages/language_registry.dart';
import 'language_syntax_test.dart' show loadLanguage, scopeAt;

void main() {
  test('Unity project formats resolve across desktop path styles', () {
    final registry = LanguageRegistry();
    for (final id in bundledLanguageIds) {
      registry.register(loadLanguage(id));
    }
    for (final entry in {
      'Assets/Player.cs': 'csharp',
      r'C:\Game\Assets\Scenes\Level.unity': 'yaml',
      'Assets/Player.prefab': 'yaml',
      'Assets/Player.cs.meta': 'yaml',
      'Assets/Settings.asset': 'yaml',
      'Assets/Material.mat': 'yaml',
      'Assets/Runtime.asmdef': 'json',
      'Assets/Editor.asmref': 'json',
      'Assets/Controls.inputactions': 'json',
      'Assets/Graph.shadergraph': 'json',
      'Assets/Surface.shader': 'shader',
      'Assets/Shared.HLSL': 'shader',
      'Assets/Lighting.cginc': 'shader',
      'Assets/Particles.compute': 'shader',
      'native.cpp': 'cpp',
      'config.yaml': 'yaml',
    }.entries) {
      expect(registry.forPath(entry.key)?.id, entry.value, reason: entry.key);
    }
  });
  test('Unity types preserve C# string and comment boundaries', () {
    final cs = loadLanguage('csharp');
    expect(
      scopeAt(cs, 'class Player : MonoBehaviour {}', 'MonoBehaviour'),
      'type',
    );
    expect(
      scopeAt(
        cs,
        '[SerializeField] private Transform target;',
        'SerializeField',
      ),
      'annotation',
    );
    expect(
      scopeAt(cs, 'var text = "MonoBehaviour";', 'MonoBehaviour'),
      'string',
    );
    expect(scopeAt(cs, '// SerializeField', 'SerializeField'), 'comment');
    expect(
      cs.snippets['unity-coroutine']['body'],
      contains('System.Collections.IEnumerator'),
    );
    expect(
      cs.fileTemplates['unity-editor-window']['body'],
      contains('#if UNITY_EDITOR'),
    );
    expect(
      cs.fileTemplates['unity-component']['body'],
      contains('class {{name}} : MonoBehaviour'),
    );
  });
  test(
    'ShaderLab and HLSL handle compute semantics and multiline comments',
    () {
      final shader = loadLanguage('shader');
      expect(scopeAt(shader, 'Shader "Custom/Test"', 'Shader'), 'keyword');
      expect(
        scopeAt(
          shader,
          'RWStructuredBuffer<float4> output;',
          'RWStructuredBuffer',
        ),
        'type',
      );
      expect(scopeAt(shader, 'float4 color : SV_Target;', 'float4'), 'type');
      expect(
        scopeAt(shader, 'float4 color : SV_Target;', 'SV_Target'),
        'annotation',
      );
      expect(scopeAt(shader, '#pragma kernel CSMain', '#pragma'), 'directive');
      expect(scopeAt(shader, 'half value = 1.5h;', '1.5h'), 'number');
      expect(
        scopeAt(shader, 'Tags { "RenderType" = "Opaque" }', 'Opaque'),
        'string',
      );
      final comment = shader.tokenizeLine('/* float4');
      expect(
        shader.tokenizeLine('SV_Target', comment.state).tokens.single.scope,
        'comment',
      );
      expect(
        shader.tokenizeLine('*/ float4 color;', comment.state).state,
        isNull,
      );
      expect(shader.fileTemplates['compute']['body'], contains('id.x < count'));
    },
  );
  test('Unity assembly templates generate valid JSON with matching names', () {
    final json = loadLanguage('json');
    for (final key in ['unity-assembly', 'unity-editor-assembly']) {
      final body = (json.fileTemplates[key]['body'] as String).replaceAll(
        '{{name}}',
        'GameRuntime',
      );
      final data = jsonDecode(body) as Map<String, dynamic>;
      expect(data['name'], 'GameRuntime');
      if (key == 'unity-editor-assembly') {
        expect(data['includePlatforms'], ['Editor']);
      }
    }
  });
}
