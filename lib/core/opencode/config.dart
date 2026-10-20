import 'dart:convert';
import 'dart:io';

import 'llm.dart';

/// Engine configuration, ported from opencode's provider resolution
/// (packages/core/src/config + provider registry). Persisted per project in
/// `.tamtoot/opencode.json`:
///
/// ```json
/// {
///   "model": "ollama/qwen3:14b",
///   "providers": {
///     "ollama": {"type": "ollama", "baseURL": "http://127.0.0.1:11434", "think": false},
///     "corp": {"type": "openai-compatible", "baseURL": "https://…/v1",
///              "apiKey": "…", "models": ["qwen3-coder"]}
///   }
/// }
/// ```
///
/// `think` defaults to `false` for Ollama — the configuration validated with
/// Qwen3 coding sessions (native tools, no reasoning field). Set it to `true`
/// to enable reasoning manually.

class OpencodeConfig {
  OpencodeConfig({this.selectedModel, Map<String, ProviderConfig>? providers})
    : providers = providers ?? _defaultProviders();

  /// `providerID/modelID`, e.g. `ollama/qwen3:14b`.
  String? selectedModel;
  final Map<String, ProviderConfig> providers;

  static Map<String, ProviderConfig> _defaultProviders() => {
    'ollama': ProviderConfig(
      id: 'ollama',
      type: 'ollama',
      baseURL: 'http://127.0.0.1:11434',
      think: false,
    ),
  };

  static File _file(String root) =>
      File('$root${Platform.pathSeparator}.tamtoot${Platform.pathSeparator}opencode.json');

  static Future<OpencodeConfig> load(String root) async {
    final file = _file(root);
    if (!file.existsSync()) return OpencodeConfig();
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return OpencodeConfig();
      final providers = <String, ProviderConfig>{};
      final rawProviders = data['providers'];
      if (rawProviders is Map) {
        for (final entry in rawProviders.entries) {
          if (entry.value is Map) {
            providers['${entry.key}'] = ProviderConfig.fromJson(
              '${entry.key}',
              Map<String, dynamic>.from(entry.value as Map),
            );
          }
        }
      }
      // The local Ollama provider always exists, mirroring opencode's
      // "Ollama works out of the box" behaviour.
      providers.putIfAbsent('ollama', () => _defaultProviders()['ollama']!);
      return OpencodeConfig(
        selectedModel: data['model'] as String?,
        providers: providers,
      );
    } catch (_) {
      return OpencodeConfig();
    }
  }

  Future<void> save(String root) async {
    final file = _file(root);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        if (selectedModel != null) 'model': selectedModel,
        'providers': {
          for (final entry in providers.entries)
            entry.key: {
              'type': entry.value.type,
              'baseURL': entry.value.baseURL,
              if (entry.value.apiKey != null) 'apiKey': entry.value.apiKey,
              if (entry.value.think != null) 'think': entry.value.think,
              if (entry.value.models.isNotEmpty) 'models': entry.value.models,
            },
        },
      }),
    );
  }

  /// Resolve the model to run: the configured selection, or the first
  /// discovered Ollama model, mirroring opencode's default-model fallback.
  Future<({ProviderConfig provider, String model})?> resolveModel() async {
    final selected = selectedModel;
    if (selected != null && selected.contains('/')) {
      final slash = selected.indexOf('/');
      final provider = providers[selected.substring(0, slash)];
      if (provider != null) {
        return (provider: provider, model: selected.substring(slash + 1));
      }
    }
    final discovered = await discoverOllamaModels(providers['ollama']);
    if (discovered.isNotEmpty) {
      return (provider: providers['ollama']!, model: discovered.first);
    }
    for (final provider in providers.values) {
      if (provider.models.isNotEmpty) {
        return (provider: provider, model: provider.models.first);
      }
    }
    return null;
  }

  /// Live model discovery for Ollama (`GET /api/tags`), ported from
  /// opencode's provider model listing.
  static Future<List<String>> discoverOllamaModels(ProviderConfig? provider) async {
    if (provider == null) return const [];
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final base = Uri.parse(provider.baseURL);
      final request = await client
          .getUrl(base.resolve('/api/tags'))
          .timeout(const Duration(seconds: 3));
      final response = await request.close().timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) return const [];
      final data = jsonDecode(await utf8.decoder.bind(response).join());
      final models = data is Map ? data['models'] : null;
      if (models is! List) return const [];
      return [
        for (final model in models)
          if (model is Map && model['name'] is String) model['name'] as String,
      ];
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }
}
