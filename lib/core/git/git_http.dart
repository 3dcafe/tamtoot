import 'dart:convert';
import 'dart:typed_data';

import 'git_service.dart';
import 'pkt_line.dart';

final class GitHttpResponse {
  GitHttpResponse({
    required this.statusCode,
    required this.body,
    this.contentType,
  });
  final int statusCode;
  final Uint8List body;
  final String? contentType;
}

/// Minimal HTTP surface used by the Smart HTTP client.
abstract interface class GitHttpTransport {
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    List<int>? body,
  });
}

abstract interface class GitTransferProgressProvider {
  set onTransferProgress(void Function(GitProgress)? callback);
}

/// Logs only request endpoints and status, never headers or payloads.
class DiagnosticGitTransport implements GitHttpTransport {
  DiagnosticGitTransport(this.delegate, this.log);
  final GitHttpTransport delegate;
  final void Function(String) log;

  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final endpoint = url.replace(userInfo: '', query: '', fragment: '');
    log('$method $endpoint');
    final timer = Stopwatch()..start();
    try {
      final response = await delegate.send(
        method: method,
        url: url,
        headers: headers,
        body: body,
      );
      log(
        'HTTP ${response.statusCode}; ${response.body.length} bytes; ${timer.elapsedMilliseconds} ms',
      );
      return response;
    } catch (error) {
      log(
        'Request failed: ${error.runtimeType}; ${timer.elapsedMilliseconds} ms',
      );
      rethrow;
    }
  }
}

Map<String, String> gitAuthHeaders(GitCredentials? credentials) {
  if (credentials == null || credentials.isEmpty) return const {};
  final user = credentials.token != null && credentials.token!.isNotEmpty
      ? (credentials.username ?? 'git')
      : (credentials.username ?? '');
  final pass = credentials.token != null && credentials.token!.isNotEmpty
      ? credentials.token!
      : (credentials.password ?? '');
  final token = base64Encode(utf8.encode('$user:$pass'));
  return {'Authorization': 'Basic $token'};
}

Uri gitServiceUrl(Uri remote, String service) {
  final path = remote.path.endsWith('.git')
      ? remote.path
      : '${remote.path}.git';
  // info/refs
  return remote.replace(
    path: '$path/info/refs',
    queryParameters: {'service': service},
  );
}

Uri gitRpcUrl(Uri remote, String service) {
  final path = remote.path.endsWith('.git')
      ? remote.path
      : '${remote.path}.git';
  return remote.replace(path: '$path/$service', query: null);
}

final class GitRemoteRef {
  GitRemoteRef(this.name, this.hash);
  final String name;
  final String hash;
}

final class GitRefDiscovery {
  GitRefDiscovery({
    required this.refs,
    required this.capabilities,
    this.headTarget,
  });
  final List<GitRemoteRef> refs;
  final Set<String> capabilities;
  final String? headTarget;

  String? hashFor(String name) {
    for (final ref in refs) {
      if (ref.name == name) return ref.hash;
    }
    return null;
  }

  String? get defaultBranch {
    if (headTarget != null) return headTarget;
    for (final candidate in ['refs/heads/main', 'refs/heads/master']) {
      if (hashFor(candidate) != null) return candidate;
    }
    final head = refs.where((r) => r.name.startsWith('refs/heads/'));
    return head.isEmpty ? null : head.first.name;
  }
}

Future<GitRefDiscovery> discoverRefs(
  GitHttpTransport http,
  Uri remote,
  String service, {
  GitCredentials? credentials,
}) async {
  final url = gitServiceUrl(remote, service);
  final response = await http.send(
    method: 'GET',
    url: url,
    headers: {
      'Accept': 'application/x-$service-advertisement',
      ...gitAuthHeaders(credentials),
    },
  );
  if (response.statusCode != 200) {
    final hint = switch (response.statusCode) {
      401 =>
        ' Authentication failed. Check the HTTPS username, access token and repository access.',
      403 =>
        ' Access forbidden. Check token permissions and repository access '
            '(GitLab: read_repository for cloning, write_repository for pushing).',
      404 =>
        ' Repository not found (or private without access). '
            'Check the repository URL and token permissions.',
      _ => '',
    };
    throw GitException(
      'Ref discovery failed (${response.statusCode}) for $url.$hint',
    );
  }
  return parseRefAdvertisement(response.body, service);
}

GitRefDiscovery parseRefAdvertisement(List<int> body, String service) {
  final reader = PktLineReader(body);
  final first = reader.nextText();
  if (first == null || !first.startsWith('# service=$service')) {
    // Dumb HTTP or odd servers may omit service header — still parse refs.
  } else {
    reader.next(); // flush after header
  }

  final refs = <GitRemoteRef>[];
  final capabilities = <String>{};
  String? headTarget;

  while (true) {
    final line = reader.nextText();
    if (line == null || line.isEmpty) break;
    final nul = line.indexOf('\x00');
    final main = nul >= 0 ? line.substring(0, nul) : line;
    if (nul >= 0 && capabilities.isEmpty) {
      capabilities.addAll(
        line.substring(nul + 1).split(' ').where((c) => c.isNotEmpty),
      );
    }
    final space = main.indexOf(' ');
    if (space <= 0) continue;
    final hash = main.substring(0, space);
    final name = main.substring(space + 1);
    if (name == 'HEAD') {
      // symref=HEAD:refs/heads/main may be in caps
      for (final cap in capabilities) {
        if (cap.startsWith('symref=HEAD:')) {
          headTarget = cap.substring('symref=HEAD:'.length);
        }
      }
      refs.add(GitRemoteRef('HEAD', hash));
    } else {
      refs.add(GitRemoteRef(name, hash));
    }
  }

  headTarget ??= () {
    for (final head in refs.where((r) => r.name == 'HEAD')) {
      for (final other in refs) {
        if (other.name.startsWith('refs/') && other.hash == head.hash) {
          return other.name;
        }
      }
    }
    return null;
  }();

  return GitRefDiscovery(
    refs: refs,
    capabilities: capabilities,
    headTarget: headTarget,
  );
}

/// Build upload-pack want/have request for a full clone of [wantHash].
Uint8List buildUploadPackRequest({
  required String wantHash,
  required Set<String> serverCapabilities,
  List<String> haveHashes = const [],
}) {
  // Keep negotiation simple: side-band + ofs-delta only.
  // `no-done` / multi_ack without a full have/ack loop confuses some hosts.
  final caps = <String>[
    if (serverCapabilities.contains('side-band-64k')) 'side-band-64k',
    if (serverCapabilities.contains('ofs-delta')) 'ofs-delta',
    'agent=tamtoot/0.1',
  ];

  final out = BytesBuilder(copy: false);
  out.add(PktLine.encodeText('want $wantHash ${caps.join(' ')}'));
  out.add(PktLine.encodeFlush());
  for (final have in haveHashes) {
    out.add(PktLine.encodeText('have $have'));
  }
  out.add(PktLine.encodeText('done'));
  return out.toBytes();
}

/// Extract raw pack bytes from an upload-pack response (side-band aware).
Uint8List extractPackFromUploadResponse(List<int> body) {
  final reader = PktLineReader(body);
  final pack = BytesBuilder(copy: false);
  while (true) {
    final pkt = reader.next();
    if (pkt == null) break;
    if (pkt.isEmpty) continue;
    // ACK/NAK lines are text without sideband before pack starts.
    if (pkt.length >= 3 && pkt[0] == 0x4e && pkt[1] == 0x41 && pkt[2] == 0x4b) {
      continue; // NAK
    }
    if (pkt.length >= 3 && pkt[0] == 0x41 && pkt[1] == 0x43 && pkt[2] == 0x4b) {
      continue; // ACK
    }
    final band = pkt[0];
    if (band == 1) {
      pack.add(pkt.sublist(1));
    } else if (band == 2) {
      // progress
    } else if (band == 3) {
      throw GitException(utf8.decode(pkt.sublist(1)));
    } else if (pkt.length >= 4 &&
        pkt[0] == 0x50 &&
        pkt[1] == 0x41 &&
        pkt[2] == 0x43 &&
        pkt[3] == 0x4b) {
      pack.add(pkt);
      while (true) {
        final more = reader.next();
        if (more == null || more.isEmpty) break;
        pack.add(more);
      }
      break;
    }
  }
  final bytes = pack.toBytes();
  final start = _indexOfPackMagic(bytes);
  if (start < 0 || bytes.length - start < 32) {
    throw GitException('upload-pack returned no pack data');
  }
  return Uint8List.sublistView(bytes, start);
}

int _indexOfPackMagic(List<int> bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x41 &&
        bytes[i + 2] == 0x43 &&
        bytes[i + 3] == 0x4b) {
      return i;
    }
  }
  return -1;
}

Uint8List buildReceivePackRequest({
  required String oldHash,
  required String newHash,
  required String refName,
  required Set<String> serverCapabilities,
  required List<int> packfile,
}) {
  final caps = <String>[
    if (serverCapabilities.contains('report-status')) 'report-status',
    if (serverCapabilities.contains('side-band-64k')) 'side-band-64k',
    if (serverCapabilities.contains('ofs-delta')) 'ofs-delta',
    'agent=tamtoot/0.1',
  ];
  final out = BytesBuilder(copy: false);
  final cmd = '$oldHash $newHash $refName\x00${caps.join(' ')}';
  out.add(PktLine.encode(utf8.encode(cmd)));
  out.add(PktLine.encodeFlush());
  out.add(packfile);
  return out.toBytes();
}

/// A 200 response alone does not confirm a push. Check unpack and ref status,
/// including report-status packets carried inside side-band channel 1.
void verifyReceivePackResponse(List<int> body, String refName) {
  final reader = PktLineReader(body);
  final report = BytesBuilder();
  final lines = <String>[];
  while (reader.hasMore) {
    final packet = reader.next();
    if (packet == null || packet.isEmpty) continue;
    if (packet[0] == 1) {
      report.add(packet.sublist(1));
    } else if (packet[0] == 2) {
      continue;
    } else if (packet[0] == 3) {
      throw GitException('Remote reported a fatal push error');
    } else {
      lines.add(utf8.decode(packet).trim());
    }
  }
  final nested = PktLineReader(report.toBytes());
  while (nested.hasMore) {
    final line = nested.nextText();
    if (line != null && line.isNotEmpty) lines.add(line.trim());
  }
  if (!lines.contains('unpack ok') ||
      !lines.contains('ok $refName') ||
      lines.any((line) => line.startsWith('ng ') || line.startsWith('ERR '))) {
    throw GitException(
      'Server rejected the update or returned an incomplete status report',
    );
  }
}
