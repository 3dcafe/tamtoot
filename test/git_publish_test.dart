import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/git/git_http.dart';
import 'package:tamtoot/core/git/git_service.dart';
import 'package:tamtoot/core/git/github_api.dart';
import 'package:tamtoot/core/git/http_git_service.dart';
import 'package:tamtoot/core/git/pkt_line.dart';
import 'package:tamtoot/platform/git_shared.dart';

import 'explorer_test.dart' show RepositoryMemory;

class _GithubTransport implements GitHttpTransport {
  _GithubTransport();

  final login = 'alice';
  final calls = <({String method, Uri url, String? body})>[];

  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    calls.add((
      method: method,
      url: url,
      body: body == null ? null : utf8.decode(body),
    ));
    if (url.path == '/user' && method == 'GET') {
      return GitHttpResponse(
        statusCode: 200,
        body: Uint8List.fromList(utf8.encode(jsonEncode({'login': login}))),
      );
    }
    if (url.path.endsWith('/repos') && method == 'POST') {
      final payload = jsonDecode(utf8.decode(body!)) as Map<String, dynamic>;
      final name = payload['name'] as String;
      final owner = url.path.contains('/orgs/')
          ? url.pathSegments[1]
          : login;
      return GitHttpResponse(
        statusCode: 201,
        body: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'name': name,
              'full_name': '$owner/$name',
              'clone_url': 'https://github.com/$owner/$name.git',
              'html_url': 'https://github.com/$owner/$name',
              'private': payload['private'] == true,
            }),
          ),
        ),
      );
    }
    throw StateError('Unexpected $method $url');
  }
}

class _EmptyPushTransport implements GitHttpTransport {
  List<int>? sent;

  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    if (method == 'GET') {
      return GitHttpResponse(
        statusCode: 200,
        body: Uint8List.fromList([
          ...PktLine.encodeText('# service=git-receive-pack'),
          ...PktLine.encodeFlush(),
          ...PktLine.encodeText(
            '0000000000000000000000000000000000000000 capabilities^{}\x00'
            'report-status side-band-64k delete-refs ofs-delta',
          ),
          ...PktLine.encodeFlush(),
        ]),
      );
    }
    sent = body;
    final report = [
      ...PktLine.encodeText('unpack ok'),
      ...PktLine.encodeText('ok refs/heads/main'),
      ...PktLine.encodeFlush(),
    ];
    return GitHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList([
        ...PktLine.encode([1, ...report.sublist(0, 7)]),
        ...PktLine.encode([1, ...report.sublist(7)]),
        ...PktLine.encodeFlush(),
      ]),
    );
  }
}

void main() {
  final root = Uri.parse('memory:///project/');

  test('init creates an empty repository on main', () async {
    final store = RepositoryMemory();
    final git = HttpGitService(
      transport: _GithubTransport(),
      openStore: (_) => store,
      inflateAt: archiveInflateAt,
      deflate: archiveDeflate,
    );
    expect(await git.isRepository(root), isFalse);
    (await git.init(root)).ensureOk();
    expect(await git.isRepository(root), isTrue);
    expect(await store.readText('.git/HEAD'), 'ref: refs/heads/main\n');
    expect((await git.init(root)).ok, isFalse);
    await git.setIdentity(root, 'Author', 'a@example.com');
    await store.writeText('README.md', '# hi\n');
    (await git.add(root, paths: ['README.md'])).ensureOk();
    final commit = await git.commit(root, 'Initial commit');
    commit.ensureOk();
    expect(commit.stdout.length, 40);
  });

  test('createGithubRepository uses user or org endpoint', () async {
    final userTransport = _GithubTransport();
    final created = await createGithubRepository(
      userTransport,
      name: 'demo',
      credentials: const GitCredentials(username: 'git', token: 'secret'),
      private: true,
    );
    expect(created.fullName, 'alice/demo');
    expect(created.cloneUrl.toString(), 'https://github.com/alice/demo.git');
    expect(userTransport.calls.map((c) => c.url.path), [
      '/user',
      '/user/repos',
    ]);

    final orgTransport = _GithubTransport();
    final orgRepo = await createGithubRepository(
      orgTransport,
      name: 'acme/demo',
      credentials: const GitCredentials(token: 'secret'),
    );
    expect(orgRepo.fullName, 'acme/demo');
    expect(
      orgTransport.calls.any((c) => c.url.path == '/orgs/acme/repos'),
      isTrue,
    );
  });

  test('init + empty remote push publishes first commit', () async {
    final store = RepositoryMemory();
    final http = _EmptyPushTransport();
    final git = HttpGitService(
      transport: http,
      openStore: (_) => store,
      inflateAt: archiveInflateAt,
      deflate: archiveDeflate,
    );
    (await git.init(root)).ensureOk();
    (await git.setRemoteUrl(
      root,
      Uri.parse('https://github.com/alice/demo.git'),
    )).ensureOk();
    await git.setIdentity(root, 'Author', 'a@example.com');
    await store.writeText('app.dart', 'void main() {}');
    (await git.add(root, paths: ['app.dart'])).ensureOk();
    final commit = await git.commit(root, 'Initial commit');
    commit.ensureOk();
    final pushed = await git.push(
      root,
      credentials: const GitCredentials(token: 'secret'),
      setUpstream: true,
    );
    pushed.ensureOk();
    expect(http.sent, isNotNull);
    expect(await store.readText('.git/config'), contains('remote = origin'));
    expect(await store.exists('.git/refs/remotes/origin/main'), isTrue);
  });
}
