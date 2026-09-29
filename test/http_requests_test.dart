import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.chunks);
  final List<List<int>> chunks;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(Stream.fromIterable(chunks), 200);
}

class _ConcurrencyTransport implements RequestHttpTransport {
  int active = 0;
  int maximum = 0;

  @override
  Future<HttpTransportResponse> send(ResolvedHttpRequest request) async {
    active++;
    if (active > maximum) maximum = active;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    active--;
    return const HttpTransportResponse(statusCode: 200, headers: {}, body: []);
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
      attachments: [
        RequestAttachment(type: 'markdown', path: 'README.md'),
      ],
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
    expect(
      await storage.readMarkdown(moved.path, 'README.md'),
      '# Create user',
    );
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

  test('parallel execution never exceeds the hard concurrency limit', () async {
    final transport = _ConcurrencyTransport();
    final executor = RequestExecutor(transport: transport);
    final requests = List.generate(
      20,
      (index) => (
        id: '$index',
        request: HttpRequestFile(
          name: 'Request $index',
          url: 'https://example.com/$index',
        ),
      ),
    );
    final result = await executor.executeMany(
      requests,
      const RequestExecutionContext(),
      const BatchExecutionOptions(parallel: true, maxConcurrency: 100),
    );
    expect(result.results, hasLength(20));
    expect(transport.maximum, 5);
  });

  test('form encoding and authorization overrides are deterministic', () {
    final executor = RequestExecutor(transport: _Transport());
    const context = RequestExecutionContext(
      secretVariables: {'token': 'inherited-secret'},
      projectAuth: RequestEnvironment(
        authType: 'bearer',
        authToken: '{{token}}',
      ),
    );
    final form = executor.resolve(
      'form',
      const HttpRequestFile(
        name: 'Form',
        method: 'POST',
        url: 'https://example.com',
        body: RequestBody(
          type: 'form',
          value: {'space': 'a b', 'symbol': 'a&b'},
        ),
        auth: RequestAuth(mode: 'none'),
      ),
      context,
    );
    expect(utf8.decode(form.body), 'space=a+b&symbol=a%26b');
    expect(form.headers, isNot(contains('Authorization')));
    expect(
      form.headers['Content-Type'],
      'application/x-www-form-urlencoded',
    );

    final explicit = executor.resolve(
      'explicit',
      const HttpRequestFile(
        name: 'Explicit',
        url: 'https://example.com',
        headers: [
          RequestKeyValue(key: 'Authorization', value: 'Custom value'),
        ],
      ),
      context,
    );
    expect(explicit.headers['Authorization'], 'Custom value');
  });

  test('streaming transport stops before retaining an oversized response', () async {
    final client = _StreamingClient([
      Uint8List(3 * 1024 * 1024),
      Uint8List(2 * 1024 * 1024),
    ]);
    final transport = PackageRequestHttpTransport(client: client);
    await expectLater(
      transport.send(
        ResolvedHttpRequest(
          id: 'large',
          name: 'Large',
          method: 'GET',
          uri: Uri.parse('https://example.com'),
          headers: const {},
          body: const [],
        ),
      ),
      throwsStateError,
    );
    transport.close();
  });

  test('malformed files are isolated and move conflicts preserve sources', () async {
    final directory = await Directory.systemTemp.createTemp('tamtoot-broken-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileGitRepositoryStore(directory);
    final storage = RequestStorage(store);
    await store.writeText('.tamtoot/requests/broken.json', '{broken');
    await storage.create(
      'source',
      const HttpRequestFile(
        name: 'Health',
        url: 'https://example.com/health',
        attachments: [
          RequestAttachment(type: 'markdown', path: 'health.md'),
        ],
      ),
    );
    await storage.saveMarkdown('source/health.json', 'health.md', '# Health');
    await storage.create(
      'target',
      const HttpRequestFile(name: 'Existing', url: 'https://example.com'),
    );
    await storage.saveMarkdown(
      'target/existing.json',
      'health.md',
      '# Existing',
    );

    final entries = await storage.list();
    expect(entries.where((entry) => !entry.valid).single.path, 'broken.json');
    await expectLater(
      storage.move('source/health.json', 'target'),
      throwsStateError,
    );
    expect((await storage.read('source/health.json')).name, 'Health');
    expect(
      await storage.readMarkdown('source/health.json', 'health.md'),
      '# Health',
    );
  });

  test('native storage rejects a symlinked requests directory', () async {
    final directory = await Directory.systemTemp.createTemp('tamtoot-links-');
    addTearDown(() => directory.delete(recursive: true));
    final outside = await Directory('${directory.path}/outside').create();
    await Directory('${directory.path}/project/.tamtoot').create(recursive: true);
    await Link('${directory.path}/project/.tamtoot/requests').create(outside.path);
    final storage = RequestStorage(
      FileGitRepositoryStore(Directory('${directory.path}/project')),
    );
    await expectLater(
      storage.create(
        '',
        const HttpRequestFile(name: 'Escape'),
      ),
      throwsA(isA<Exception>()),
    );
    expect(await outside.list().toList(), isEmpty);
  }, skip: Platform.isWindows);

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
    expect(
      () => const HttpRequestFile(
        name: 'Escape',
        attachments: [
          RequestAttachment(type: 'markdown', path: '../outside.md'),
        ],
      ).encode(),
      throwsFormatException,
    );
    expect(
      () => const RequestEnvironment(authType: 'basic').encode(),
      throwsFormatException,
    );
    expect(
      () => executor.resolve(
        'credentials',
        const HttpRequestFile(
          name: 'Credentials',
          url: 'https://user:password@example.com',
        ),
        const RequestExecutionContext(),
      ),
      throwsFormatException,
    );
    expect(
      () => executor.resolve(
        'header',
        const HttpRequestFile(
          name: 'Header',
          url: 'https://example.com',
          headers: [RequestKeyValue(key: 'X-Test', value: '{{value}}')],
        ),
        const RequestExecutionContext(
          runtimeVariables: {'value': 'ok\r\nInjected: true'},
        ),
      ),
      throwsFormatException,
    );
  });
}
