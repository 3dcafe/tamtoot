import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Dart's Windows TLS roots differ from the Windows certificate store. Include
/// roots trusted by Windows, including certificates installed by an HTTPS proxy.
Future<SecurityContext> windowsGitSecurityContext() async {
  final context = SecurityContext(withTrustedRoots: true);
  // Portable Windows installations may have an incomplete or outdated ROOT
  // store. Ship public Mozilla roots rather than relying on Windows updates.
  final publicRoots = await rootBundle.load('assets/certificates/cacert.pem');
  context.setTrustedCertificatesBytes(
    publicRoots.buffer.asUint8List(
      publicRoots.offsetInBytes,
      publicRoots.lengthInBytes,
    ),
  );
  final roots = await const MethodChannel(
    'dev.tamtoot/tls_roots',
  ).invokeListMethod<Uint8List>('readRoots');
  for (final root in roots ?? <Uint8List>[]) {
    // CryptoAPI returns DER; Dart's Windows TLS backend accepts PEM/PKCS12.
    final encoded = base64Encode(root);
    final pem = StringBuffer('-----BEGIN CERTIFICATE-----\n');
    for (var offset = 0; offset < encoded.length; offset += 64) {
      final end = offset + 64 < encoded.length ? offset + 64 : encoded.length;
      pem.writeln(encoded.substring(offset, end));
    }
    pem.writeln('-----END CERTIFICATE-----');
    context.setTrustedCertificatesBytes(utf8.encode(pem.toString()));
  }
  return context;
}

class GitIoClient extends http.BaseClient {
  Future<http.Client>? _client;
  bool _closed = false;

  Future<http.Client> _open() async {
    final context = Platform.isWindows
        ? await windowsGitSecurityContext()
        : SecurityContext.defaultContext;
    final client = IOClient(HttpClient(context: context));
    if (_closed) {
      client.close();
      throw http.ClientException('Git HTTP client is closed');
    }
    return client;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('Git HTTP client is closed');
    try {
      return await (await (_client ??= _open())).send(request);
    } on HandshakeException catch (error) {
      throw http.ClientException(
        'HTTPS certificate verification failed for ${request.url.host}. '
        'Check the system date and trusted root certificates. If an antivirus '
        'or proxy inspects HTTPS, its root certificate must be trusted by '
        'the operating system. This failure occurs before token authentication. '
        'TLS details: ${error.osError?.message ?? error.message}',
      );
    }
  }

  @override
  void close() {
    _closed = true;
    _client?.then((client) => client.close(), onError: (Object _) {});
  }
}
