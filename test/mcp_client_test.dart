import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tamtoot/core/agents/mcp_client.dart';

void main() {
  test('MCP config validates transports, endpoints and headers', () {
    final config = McpConfig.parse(
      jsonEncode({
        'mcpServers': {
          'files': {
            'type': 'streamableHttp',
            'url': 'http://localhost:3000/mcp',
            'disabled': false,
          },
          'local': {
            'command': 'mcp-server',
            'args': ['--stdio'],
          },
        },
      }),
    );
    expect(config.servers['files']!.type, 'streamableHttp');
    expect(config.servers['local']!.type, 'stdio');
    expect(
      () => McpConfig.parse(
        '{"mcpServers":{"bad":{"type":"streamableHttp","url":"http://example.com"}}}',
      ),
      throwsFormatException,
    );
    expect(
      () => McpConfig.parse(
        '{"mcpServers":{"bad":{"type":"streamableHttp","url":"https://example.com","headers":{"X":"a\\nb"}}}}',
      ),
      throwsFormatException,
    );
  });

  test(
    'Streamable HTTP initializes, keeps session, lists and calls tools',
    () async {
      final methods = <String>[];
      final client = McpHttpClient(
        const McpServerConfig(
          name: 'remote',
          type: 'streamableHttp',
          url: 'https://mcp.example.test/rpc',
          headers: {'Authorization': 'Bearer hidden'},
        ),
        client: MockClient((request) async {
          final data = jsonDecode(request.body);
          methods.add(data['method']);
          expect(request.headers['authorization'], 'Bearer hidden');
          if (methods.length > 1) {
            expect(request.headers['mcp-session-id'], 'session-1');
          }
          final method = data['method'];
          final result = switch (method) {
            'initialize' => {
              'protocolVersion': '2025-06-18',
              'capabilities': {},
            },
            'notifications/initialized' => null,
            'tools/list' => {
              'tools': [
                {
                  'name': 'lookup',
                  'description': 'Look up a value',
                  'inputSchema': {'type': 'object'},
                },
              ],
            },
            'tools/call' => {
              'content': [
                {'type': 'text', 'text': 'ok'},
              ],
            },
            _ => {},
          };
          if (method == 'notifications/initialized') {
            return http.Response(
              '',
              202,
              headers: {'mcp-session-id': 'session-1'},
            );
          }
          return http.Response(
            jsonEncode({'jsonrpc': '2.0', 'id': data['id'], 'result': result}),
            200,
            headers: {'mcp-session-id': 'session-1'},
          );
        }),
      );
      await client.initialize();
      final tools = await client.listTools();
      expect(tools.single.name, 'lookup');
      final result = await client.callTool('lookup', {'id': 7});
      expect((result['content'] as List).single['text'], 'ok');
      expect(methods, [
        'initialize',
        'notifications/initialized',
        'tools/list',
        'tools/call',
      ]);
    },
  );

  test('MCP accepts a JSON-RPC event from SSE response', () async {
    final client = McpHttpClient(
      const McpServerConfig(
        name: 'remote',
        type: 'streamableHttp',
        url: 'https://mcp.example.test/rpc',
      ),
      client: MockClient(
        (request) async => http.Response(
          'event: message\ndata: ${jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {'tools': []},
          })}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    expect(await client.listTools(), isEmpty);
  });

  test('STDIO MCP initializes, lists tools and calls one', () async {
    final registry = McpRegistry(
      McpConfig({
        'local': McpServerConfig(
          name: 'local',
          type: 'stdio',
          command: 'python3',
          arguments: const ['-u', 'test/fixtures/mcp_stdio_server.py'],
        ),
      }),
    );
    addTearDown(registry.close);
    await registry.connect();
    expect(registry.tools['local']!.single.name, 'echo');
    final result = await registry.call('local', 'echo', {'value': 7});
    expect((result['content'] as List).single['text'], '{"value":7}');
  });
}
