import 'dart:convert';

import 'package:http/http.dart' as http;

import 'model_client.dart';
import 'model_profile.dart';
import 'ollama_client.dart';

class ModelApiProbeResult {
  const ModelApiProbeResult({required this.message, this.models = const []});
  final String message;
  final List<String> models;
}

class ModelApiProbe {
  ModelApiProbe({http.Client? client, this.timeout = const Duration(seconds: 6)})
    : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  Future<ModelApiProbeResult> check(ModelProfile profile) async {
    profile.validate();
    final endpoint = profile.requestUri();
    if (profile.apiFormat == 'ollama') {
      final base = endpoint.replace(
        path: endpoint.path.replaceFirst(RegExp(r'/api/chat/?$'), ''),
      );
      final ollama = OllamaClient(client: _client, timeout: timeout);
      final models = await ollama.models(base.toString());
      final names = models.map((item) => item.name).toList();
      final selected = names.contains(profile.model);
      return ModelApiProbeResult(
        message: names.isEmpty
            ? 'Ollama is available, but no models are installed.'
            : selected
            ? 'Ollama is available and ${profile.model} is installed.'
            : 'Ollama is available. Choose one of the detected models.',
        models: names,
      );
    }

    final modelsUri = _modelsUri(endpoint);
    try {
      final response = await _client.get(modelsUri).timeout(timeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        return const ModelApiProbeResult(
          message: 'API is reachable and requires an access key. Compatibility will be checked when you run the model.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ModelApiException(
          'API check returned HTTP ${response.statusCode}. The selected server type may be incompatible.',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['data'] is! List) {
        throw const ModelApiException(
          'API is reachable but its model list is not OpenAI-compatible.',
        );
      }
      final models = <String>[
        for (final item in decoded['data'] as List)
          if (item is Map && item['id'] is String) item['id'] as String,
      ]..sort();
      final selected = models.contains(profile.model);
      return ModelApiProbeResult(
        message: models.isEmpty
            ? 'API is compatible, but it reported no models.'
            : selected
            ? 'API is compatible and ${profile.model} is available.'
            : 'API is compatible. Choose one of the detected models.',
        models: models,
      );
    } on ModelApiException {
      rethrow;
    } catch (_) {
      throw const ModelApiException(
        'API is unavailable. Start the local server and try again.',
      );
    }
  }

  Uri _modelsUri(Uri endpoint) {
    var path = endpoint.path;
    for (final suffix in [
      '/chat/completions',
      '/responses',
      '/messages',
    ]) {
      if (path.endsWith(suffix)) {
        path = '${path.substring(0, path.length - suffix.length)}/models';
        break;
      }
    }
    return endpoint.replace(path: path, query: null, fragment: null);
  }

  void close() => _client.close();
}
