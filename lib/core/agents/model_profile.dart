import 'dart:convert';

const defaultSystemPrompt =
    'You are a coding assistant. Follow the project instructions and explain your changes clearly.';
const defaultUserTemplate =
    'Task:\n{{task}}\n\nFile: {{file_path}}\n{{file}}\n\nSelected code:\n{{selection}}';

class ModelProfile {
  ModelProfile({
    required this.id,
    required this.name,
    required this.provider,
    required this.model,
    this.systemPrompt = defaultSystemPrompt,
    this.userTemplate = defaultUserTemplate,
    this.parameters = const {},
    this.apiFormat = 'chat-completions',
    this.endpoint = '',
  });
  final String id, name, provider, model, systemPrompt, userTemplate;
  final Map<String, dynamic> parameters;
  final String apiFormat, endpoint;
  static const apiFormats = {
    'ollama': 'Ollama Chat',
    'chat-completions': 'Chat Completions (compatible APIs)',
    'responses': 'OpenAI Responses',
    'anthropic': 'Anthropic Messages',
  };

  Uri requestUri() {
    final uri = Uri.tryParse(endpoint);
    final local = uri != null && _isPrivateHost(uri.host);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && local))) {
      throw const FormatException(
        'Enter a full HTTPS API endpoint without credentials or query parameters. HTTP is allowed only for localhost.',
      );
    }
    return uri;
  }

  static bool _isPrivateHost(String host) {
    if ({'localhost', '127.0.0.1', '::1', '[::1]'}.contains(host)) return true;
    final parts = host.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    return parts[0] == 10 ||
        (parts[0] == 192 && parts[1] == 168) ||
        (parts[0] == 172 && parts[1]! >= 16 && parts[1]! <= 31);
  }

  static final idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
  static final variables = RegExp(r'\{\{\s*([a-zA-Z_]+)\s*\}\}');
  static const allowedVariables = {'task', 'file_path', 'file', 'selection'};

  void validate() {
    if (!apiFormats.containsKey(apiFormat)) {
      throw const FormatException('Unsupported API format.');
    }
    if (endpoint.isNotEmpty) requestUri();
    if (!idPattern.hasMatch(id)) {
      throw const FormatException(
        'Profile ID: use lowercase letters, numbers, - or _ (1–64 characters).',
      );
    }
    if ([name, provider, model].any((v) => v.trim().isEmpty)) {
      throw const FormatException('Name, provider and model are required.');
    }
    for (final prompt in [systemPrompt, userTemplate]) {
      for (final match in variables.allMatches(prompt)) {
        if (!allowedVariables.contains(match[1])) {
          throw FormatException('Unknown template variable: ${match[1]}');
        }
      }
    }
    const reserved = {
      'model',
      'messages',
      'input',
      'system',
      'prompt',
      'api_key',
      'apikey',
      'authorization',
      'token',
      'access_token',
      'password',
      'headers',
      'instructions',
      'stream',
      'stream_options',
      'background',
      'tools',
      'tool_choice',
      'functions',
      'function_call',
      'previous_response_id',
      'conversation',
      'options',
    };
    void check(dynamic value) {
      if (value is Map) {
        for (final entry in value.entries) {
          if (reserved.contains(entry.key.toString().toLowerCase())) {
            throw FormatException(
              'Reserved or credential parameter: ${entry.key}',
            );
          }
          check(entry.value);
        }
      } else if (value is List) {
        value.forEach(check);
      }
    }

    check(parameters);
    jsonEncode(parameters);
  }

  String encode() {
    validate();
    return const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'id': id,
      'name': name,
      'provider': provider,
      'model': model,
      'systemPrompt': systemPrompt,
      'userTemplate': userTemplate,
      'parameters': parameters,
      'apiFormat': apiFormat,
      'endpoint': endpoint,
    });
  }

  factory ModelProfile.parse(String source) {
    final data = jsonDecode(source);
    if (data is! Map<String, dynamic> || data['schemaVersion'] != 1) {
      throw const FormatException('Unsupported model profile schema.');
    }
    String string(String key) {
      final value = data[key];
      if (value is! String) throw FormatException('Invalid $key');
      return value;
    }

    if (data['parameters'] is! Map<String, dynamic>) {
      throw const FormatException('Parameters must be a JSON object.');
    }
    final profile = ModelProfile(
      id: string('id'),
      name: string('name'),
      provider: string('provider'),
      model: string('model'),
      systemPrompt: string('systemPrompt'),
      userTemplate: string('userTemplate'),
      parameters: data['parameters'] as Map<String, dynamic>,
      apiFormat: data.containsKey('apiFormat')
          ? string('apiFormat')
          : 'chat-completions',
      endpoint: data.containsKey('endpoint') ? string('endpoint') : '',
    );
    profile.validate();
    return profile;
  }

  /// Provider-neutral preview; no request is sent and no credential is included.
  Map<String, dynamic> preview({
    required String task,
    String instructions = '',
    String filePath = '',
    String file = '',
    String selection = '',
  }) {
    validate();
    final values = {
      'task': task,
      'file_path': filePath,
      'file': file,
      'selection': selection,
    };
    String expand(String source) =>
        source.replaceAllMapped(variables, (m) => values[m[1]]!);
    return {
      'provider': provider,
      'model': model,
      'parameters': parameters,
      'apiFormat': apiFormat,
      'endpoint': endpoint,
      'systemPrompt': [
        expand(systemPrompt),
        instructions,
      ].where((s) => s.trim().isNotEmpty).join('\n\n'),
      'userPrompt': expand(userTemplate),
    };
  }
}
