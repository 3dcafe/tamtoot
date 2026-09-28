import 'dart:convert';

import 'package:http/http.dart' as http;

import 'model_client.dart';

class OllamaModel {
  const OllamaModel({required this.name, this.contextWindow});

  final String name;
  final int? contextWindow;
}

class OllamaClient {
  OllamaClient({http.Client? client, this.timeout = const Duration(seconds: 5)})
    : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  Uri _base(String source) {
    final uri = Uri.tryParse(source.trim());
    final host = uri?.host ?? '';
    final parts = host.split('.').map(int.tryParse).toList();
    final local =
        {'localhost', '127.0.0.1', '::1', '[::1]'}.contains(host) ||
        (parts.length == 4 &&
            parts.every((part) => part != null) &&
            (parts[0] == 10 ||
                (parts[0] == 192 && parts[1] == 168) ||
                (parts[0] == 172 && parts[1]! >= 16 && parts[1]! <= 31)));
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && local))) {
      throw const ModelApiException(
        'Ollama Base URL must be HTTPS, or HTTP on localhost.',
      );
    }
    return uri;
  }

  Future<List<OllamaModel>> models(String baseUrl) async {
    try {
      final base = _base(baseUrl);
      final response = await _client
          .get(
            base.replace(
              path: '${base.path.replaceFirst(RegExp(r'/$'), '')}/api/tags',
            ),
          )
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw ModelApiException('Ollama returned HTTP ${response.statusCode}.');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['models'] is! List) {
        throw const ModelApiException('Ollama returned an invalid model list.');
      }
      final result = <OllamaModel>[];
      for (final item in decoded['models'] as List) {
        if (item is Map && item['name'] is String) {
          result.add(OllamaModel(name: item['name'] as String));
        }
      }
      result.sort((a, b) => a.name.compareTo(b.name));
      return result;
    } on ModelApiException {
      rethrow;
    } catch (_) {
      throw const ModelApiException(
        'Ollama is unavailable. Start it and check the Base URL.',
      );
    }
  }

  Future<int?> contextWindow(String baseUrl, String model) async {
    try {
      final base = _base(baseUrl);
      final response = await _client
          .post(
            base.replace(
              path: '${base.path.replaceFirst(RegExp(r'/$'), '')}/api/show',
            ),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'model': model}),
          )
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body);
      if (data is! Map) return null;
      final modelInfo = data['model_info'];
      if (modelInfo is! Map) return null;
      final values = modelInfo.entries
          .where((entry) => entry.key.toString().endsWith('.context_length'))
          .map((entry) => entry.value)
          .whereType<num>()
          .map((value) => value.toInt())
          .toList();
      return values.isEmpty ? null : values.reduce((a, b) => a > b ? a : b);
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}
