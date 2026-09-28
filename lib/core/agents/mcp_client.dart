import 'dart:convert';

import 'package:http/http.dart' as http;

import 'model_client.dart';
import 'mcp_stdio.dart';

class McpServerConfig {
  const McpServerConfig({
    required this.name,
    required this.type,
    this.url = '',
    this.command = '',
    this.arguments = const [],
    this.headers = const {},
    this.disabled = false,
    this.timeoutSeconds = 30,
  });

  final String name, type, url, command;
  final List<String> arguments;
  final Map<String, String> headers;
  final bool disabled;
  final int timeoutSeconds;

  factory McpServerConfig.parse(String name, dynamic source) {
    if (source is! Map) {
      throw FormatException('MCP server $name must be an object.');
    }
    final type = source['type'] is String
        ? source['type'] as String
        : source['command'] is String
        ? 'stdio'
        : 'streamableHttp';
    final rawArgs = source['args'] ?? const [];
    final rawHeaders = source['headers'] ?? const {};
    if (rawArgs is! List || rawArgs.any((value) => value is! String)) {
      throw FormatException('MCP server $name has invalid args.');
    }
    if (rawHeaders is! Map ||
        rawHeaders.entries.any(
          (entry) => entry.key is! String || entry.value is! String,
        )) {
      throw FormatException('MCP server $name has invalid headers.');
    }
    final timeout = source['timeoutSeconds'] ?? 30;
    if (timeout is! int || timeout < 1 || timeout > 600) {
      throw FormatException('MCP server $name has invalid timeoutSeconds.');
    }
    final config = McpServerConfig(
      name: name,
      type: type,
      url: source['url'] is String ? source['url'] as String : '',
      command: source['command'] is String ? source['command'] as String : '',
      arguments: rawArgs.cast<String>(),
      headers: rawHeaders.cast<String, String>(),
      disabled: source['disabled'] == true,
      timeoutSeconds: timeout,
    );
    config.validate();
    return config;
  }

  void validate() {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(name)) {
      throw const FormatException('Invalid MCP server name.');
    }
    if (type == 'stdio') {
      if (command.isEmpty || command.contains('\u0000')) {
        throw FormatException('MCP server $name requires a command.');
      }
      return;
    }
    if (type != 'streamableHttp') {
      throw FormatException('Unsupported MCP transport: $type');
    }
    final endpoint = Uri.tryParse(url);
    final local =
        endpoint != null &&
        {'localhost', '127.0.0.1', '::1', '[::1]'}.contains(endpoint.host);
    if (endpoint == null ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasFragment ||
        (endpoint.scheme != 'https' && !(endpoint.scheme == 'http' && local))) {
      throw FormatException('MCP server $name requires a safe HTTP endpoint.');
    }
    if (headers.keys.any((key) => key.contains('\n') || key.contains('\r')) ||
        headers.values.any(
          (value) => value.contains('\n') || value.contains('\r'),
        )) {
      throw FormatException('MCP server $name has an invalid header.');
    }
  }
}

class McpConfig {
  const McpConfig(this.servers);
  final Map<String, McpServerConfig> servers;

  factory McpConfig.parse(String source) {
    final data = jsonDecode(source);
    if (data is! Map || data['mcpServers'] is! Map) {
      throw const FormatException('mcp.json requires an mcpServers object.');
    }
    final servers = <String, McpServerConfig>{};
    for (final entry in (data['mcpServers'] as Map).entries) {
      if (entry.key is! String) {
        throw const FormatException('MCP server names must be strings.');
      }
      servers[entry.key as String] = McpServerConfig.parse(
        entry.key as String,
        entry.value,
      );
    }
    return McpConfig(servers);
  }
}

class McpTool {
  const McpTool({
    required this.name,
    this.description = '',
    this.inputSchema = const {},
  });
  final String name, description;
  final Map<String, dynamic> inputSchema;
}

class McpHttpClient {
  McpHttpClient(this.config, {http.Client? client})
    : _client = client ?? http.Client();
  final McpServerConfig config;
  final http.Client _client;
  String? _session;
  int _id = 0;

  Future<void> initialize() async {
    await _request('initialize', {
      'protocolVersion': '2025-06-18',
      'capabilities': {},
      'clientInfo': {'name': 'tamtoot', 'version': '0.1.0'},
    });
    await _request('notifications/initialized', const {}, notification: true);
  }

  Future<List<McpTool>> listTools() async {
    final result = await _request('tools/list', const {});
    final tools = result['tools'];
    if (tools is! List) {
      throw const ModelApiException('MCP returned an invalid tool list.');
    }
    return [
      for (final item in tools)
        if (item is Map && item['name'] is String)
          McpTool(
            name: item['name'] as String,
            description: item['description'] is String
                ? item['description'] as String
                : '',
            inputSchema: item['inputSchema'] is Map<String, dynamic>
                ? item['inputSchema'] as Map<String, dynamic>
                : const {},
          ),
    ];
  }

  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) => _request('tools/call', {'name': name, 'arguments': arguments});

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params, {
    bool notification = false,
  }) async {
    config.validate();
    if (config.type != 'streamableHttp') {
      throw const ModelApiException(
        'This client supports streamable HTTP MCP only.',
      );
    }
    final headers = {
      'content-type': 'application/json',
      'accept': 'application/json, text/event-stream',
      ...config.headers,
    };
    final session = _session;
    if (session != null) headers['mcp-session-id'] = session;
    final request = http.Request('POST', Uri.parse(config.url))
      ..followRedirects = false
      ..headers.addAll(headers)
      ..body = jsonEncode({
        'jsonrpc': '2.0',
        if (!notification) 'id': ++_id,
        'method': method,
        'params': params,
      });
    final response = await _client
        .send(request)
        .timeout(Duration(seconds: config.timeoutSeconds));
    _session ??= response.headers['mcp-session-id'];
    final bytes = await response.stream.toBytes();
    if (bytes.length > 4 * 1024 * 1024) {
      throw const ModelApiException('MCP response exceeds 4 MiB.');
    }
    final body = utf8.decode(bytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ModelApiException('MCP HTTP ${response.statusCode}.');
    }
    if (notification && body.trim().isEmpty) return const {};
    final payload =
        response.headers['content-type']?.contains('text/event-stream') == true
        ? body
              .split('\n')
              .where((line) => line.startsWith('data:'))
              .map((line) => line.substring(5).trim())
              .where((line) => line.isNotEmpty)
              .lastOrNull
        : body;
    if (payload == null || payload.isEmpty) return const {};
    final data = jsonDecode(payload);
    if (data is! Map<String, dynamic>) {
      throw const ModelApiException('MCP returned invalid JSON-RPC.');
    }
    if (data['error'] is Map) {
      final error = data['error'] as Map;
      throw ModelApiException(
        error['message'] is String
            ? error['message'] as String
            : 'MCP request failed.',
      );
    }
    final result = data['result'];
    if (result == null) return const {};
    if (result is! Map<String, dynamic>) {
      throw const ModelApiException('MCP result must be an object.');
    }
    return result;
  }

  void close() => _client.close();
}

class McpRegistry {
  McpRegistry(this.config);
  final McpConfig config;
  final Map<String, McpHttpClient> _clients = {};
  final Map<String, McpStdioTransport> _stdio = {};
  final Map<String, List<McpTool>> tools = {};

  Future<void> connect() async {
    for (final server in config.servers.values) {
      if (server.disabled) continue;
      if (server.type == 'stdio') {
        final transport = McpStdioTransport(
          server.command,
          server.arguments,
          server.timeoutSeconds,
        );
        try {
          await transport.request('initialize', {
            'protocolVersion': '2025-06-18',
            'capabilities': {},
            'clientInfo': {'name': 'tamtoot', 'version': '0.1.0'},
          });
          await transport.request(
            'notifications/initialized',
            const {},
            notification: true,
          );
          final result = await transport.request('tools/list', const {});
          tools[server.name] = _parseTools(result);
          _stdio[server.name] = transport;
        } catch (_) {
          transport.close();
          rethrow;
        }
        continue;
      }
      final client = McpHttpClient(server);
      try {
        await client.initialize();
        tools[server.name] = await client.listTools();
        _clients[server.name] = client;
      } catch (_) {
        client.close();
        rethrow;
      }
    }
  }

  String describe() => [
    for (final entry in tools.entries)
      for (final tool in entry.value)
        '${entry.key}/${tool.name}: ${tool.description}',
  ].join('\n');

  Future<Map<String, dynamic>> call(
    String server,
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final client = _clients[server];
    if (client != null) return client.callTool(tool, arguments);
    final stdio = _stdio[server];
    if (stdio != null) {
      return stdio.request('tools/call', {
        'name': tool,
        'arguments': arguments,
      });
    }
    throw ModelApiException('MCP server is not connected: $server');
  }

  List<McpTool> _parseTools(Map<String, dynamic> result) {
    final raw = result['tools'];
    if (raw is! List) {
      throw const ModelApiException('MCP returned an invalid tool list.');
    }
    return [
      for (final item in raw)
        if (item is Map && item['name'] is String)
          McpTool(
            name: item['name'] as String,
            description: item['description'] is String
                ? item['description'] as String
                : '',
            inputSchema: item['inputSchema'] is Map<String, dynamic>
                ? item['inputSchema'] as Map<String, dynamic>
                : const {},
          ),
    ];
  }

  void close() {
    for (final client in _clients.values) {
      client.close();
    }
    for (final client in _stdio.values) {
      client.close();
    }
    _clients.clear();
    _stdio.clear();
  }
}
