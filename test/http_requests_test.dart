import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/requests/http_request.dart';
import 'package:tamtoot/core/requests/request_executor.dart';
import 'package:tamtoot/core/requests/request_storage.dart';
import 'package:tamtoot/platform/git_service_io.dart';

class _Transport implements RequestHttpTransport {
  final sent = <ResolvedHttpRequest>[];

  @override
  Future<HttpTransportResponse> send(ResolvedHttpRequest request) async {
    sent.add(request);
    if (request.uri.path.endsWith('/fail')) {
      return const HttpTransportResponse(
        statusCode: 500,
        headers: {},
        body: [],
      );
    }
    return const HttpTransportResponse(
      statusCode: 200,
      headers: {'content-type': 'application/json'},
      body: [123, 34, 111, 107, 34, 58, 116, 114, 117, 101, 125],
    );
  }

  @override
  void close() {}
}

void main() {
  test('request files, Markdown, folders and environments round-trip', () async {
    final directory = await Directory.systemTemp.createTemp('tamtoot-requests-');
    addTearDown(() => directory.delete(recursive: true));
    final storage = RequestStorage(FileGitRepositoryStore(directory));
    const request = HttpRequestFile(
      name: 'Create user',
      method: 'POST',
      url: '{{baseUrl}}/users',
      headers: [RequestKeyValue(key: 'X-Team', value: '{{team}}')],
      body: RequestBody(type: 'json', value: {'name': 'Sam'}),
      auth: RequestAuth(mode: 'inherit'),
    );

    final created = await storage.create('users/admin', request);
    expect(created.path, 'users/admin/create-user.json');
    expect((await storage.read(created.path)).method, 'POST');
    expect((await storage.list()).single.name, 'Create user');

    await storage.saveMarkdown(created.path, 'README.md', '# Create user');
    expect(await storage.readMarkdown(created.path, 'README.md'), '# Create user');
    await expectLater(
      storage.saveMarkdown(created.path, '../secret.md', 'bad'),
      throwsFormatException,
    );

    await storage.saveProjectEnvironment(
      const RequestEnvironment(
        variables: {'baseUrl': 'https://api.example.com'},
        authType: 'bearer',
        authToken: '{{token}}',
      ),
    );
    await storage.saveLocalEnvironment(
      const RequestEnvironment(variables: {'token': 'secret'}),
    );
    final environment = await storage.loadEnvironment();
    expect(environment.project.authToken, '{{token}}');
    expect(environment.local.variables['token'], 'secret');

    final moved = await storage.move(created.path, 'shared');
    expect(moved.path, 'shared/create-user.json');
    final renamed = await storage.rename(moved.path, 'Create account');
    expect(renamed.path, 'shared/create-account.json');
    await storage.delete(renamed.path);
    expect(await storage.list(), isEmpty);
  });

  test('variables, authorization, body and query resolve before sending', () async {
    final transport = _Transport();
    final executor = RequestExecutor(transport: transport);
    const request = HttpRequestFile(
      name: 'Lookup',
      method: 'POST',
      url: '{{baseUrl}}/items',
      query: [RequestKeyValue(key: 'q', value: '{{term}}')],
      headers: [RequestKeyValue(key: 'X-Project', value: '{{project}}')],
      body: RequestBody(type: 'json', value: {'term': '{{term}}'}),
    );
    const context = RequestExecutionContext(
      projectVariables: {
        'baseUrl': 'https://example.com',
        'project': 'tamtoot',
        'token': 'shared-placeholder',
      },
      secretVariables: {'token': 'local-token'},
      runtimeVariables: {'term': 'dart'},
      projectAuth: RequestEnvironment(
        authType: 'bearer',
        authToken: '{{token}}',
      ),
    );

    final result = await executor.execute('lookup', request, context);
    expect(result.success, isTrue);
    final sent = transport.sent.single;
    expect(sent.uri.queryParameters['q'], 'dart');
    expect(sent.headers['Authorization'], 'Bearer local-token');
    expect(sent.headers['X-Project'], 'tamtoot');
    expect(jsonDecode(utf8.decode(sent.body)), {'term': 'dart'});
  });

  test('batch preserves order, limits concurrency mode and stops sequentially', () async {
    final transport = _Transport();
    final executor = RequestExecutor(transport: transport);
    final requests = [
      (id: 'one', request: const HttpRequestFile(name: 'One', url: 'https://example.com/one')),
      (id: 'fail', request: const HttpRequestFile(name: 'Fail', url: 'https://example.com/fail')),
      (id: 'three', request: const HttpRequestFile(name: 'Three', url: 'https://example.com/three')),
    ];
    final stopped = await executor.executeMany(
      requests,
      const RequestExecutionContext(),
      const BatchExecutionOptions(stopOnError: true),
    );
    expect(stopped.results.map((item) => item.id), ['one', 'fail']);

    transport.sent.clear();
    final parallel = await executor.executeMany(
      requests,
      const RequestExecutionContext(),
      const BatchExecutionOptions(parallel: true, maxConcurrency: 5),
    );
    expect(parallel.results.map((item) => item.id), ['one', 'fail', 'three']);
    expect((await executor.executeMany([], const RequestExecutionContext())).results, isEmpty);
  });

  test('invalid schema and unresolved variables produce safe errors', () async {
    expect(
      () => HttpRequestFile.parse('{"version":2}'),
      throwsFormatException,
    );
    final executor = RequestExecutor(transport: _Transport());
    final result = await executor.execute(
      'missing',
      const HttpRequestFile(name: 'Missing', url: 'https://example.com/{{absent}}'),
      const RequestExecutionContext(secretVariables: {'token': 'do-not-print'}),
    );
    expect(result.success, isFalse);
    expect(result.error, contains('Missing variables'));
    expect(result.error, isNot(contains('do-not-print')));
  });
}
