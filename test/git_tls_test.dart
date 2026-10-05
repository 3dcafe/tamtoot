import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:tamtoot/platform/git_http_client_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These tests exercise real loopback TLS rather than widget HTTP mocks.
  HttpOverrides.global = null;
  const channel = MethodChannel('dev.tamtoot/tls_roots');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<HttpServer> server() async {
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/tls/localhost-cert.pem')
      ..usePrivateKey('test/fixtures/tls/localhost-key.pem');
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen((request) {
      request.response.write('trusted');
      request.response.close();
    }, onError: (Object _) {});
    addTearDown(() => server.close(force: true));
    return server;
  }

  test('Windows trusted roots allow a valid HTTPS chain', () async {
    final certificate = await File('test/fixtures/tls/ca.der').readAsBytes();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'readRoots');
      return [certificate];
    });
    final client = IOClient(
      HttpClient(context: await windowsGitSecurityContext()),
    );
    addTearDown(client.close);
    final endpoint = await server();
    final response = await client.get(
      Uri.parse('https://localhost:${endpoint.port}'),
    );
    expect(response.body, 'trusted');
    // Trusted CA does not disable hostname verification.
    await expectLater(
      client.get(Uri.parse('https://127.0.0.1:${endpoint.port}')),
      throwsA(isA<HandshakeException>()),
    );
  });

  test(
    'Git rejects an untrusted certificate with a useful error',
    () async {
      final endpoint = await server();
      final client = GitIoClient();
      addTearDown(client.close);
      await expectLater(
        client.get(Uri.parse('https://localhost:${endpoint.port}')),
        throwsA(
          isA<http.ClientException>().having(
            (error) => error.message,
            'message',
            contains('before token authentication'),
          ),
        ),
      );
    },
    skip: Platform.isWindows
        ? 'Requires the native channel; covered by the injected-root test'
        : false,
  );

  test(
    'Root store failures propagate without bypassing verification',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'tls_roots');
      });
      await expectLater(
        windowsGitSecurityContext(),
        throwsA(isA<PlatformException>()),
      );
    },
  );
}
