// Integration verification only: production code never invokes system Git.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/git/git_http.dart';
import 'package:tamtoot/core/git/git_service.dart';
import 'package:tamtoot/core/git/git_store.dart';
import 'package:tamtoot/core/git/http_git_service.dart';
import 'package:tamtoot/core/git/pkt_line.dart';
import 'package:tamtoot/platform/git_service_io.dart';
import 'package:tamtoot/platform/git_shared.dart';

class NativeReceivePack implements GitHttpTransport {
  NativeReceivePack(this.repository);
  final String repository;
  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final process = await Process.start('git', [
      'receive-pack',
      '--stateless-rpc',
      if (method == 'GET') '--advertise-refs',
      repository,
    ]);
    final out = process.stdout.fold<List<int>>([], (a, b) => a..addAll(b));
    final err = process.stderr.transform(utf8.decoder).join();
    if (body != null) process.stdin.add(body);
    await process.stdin.close();
    final exit = await process.exitCode;
    final output = await out;
    expect(exit, 0, reason: await err);
    return GitHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList([
        if (method == 'GET') ...[
          ...PktLine.encodeText('# service=git-receive-pack'),
          ...PktLine.encodeFlush(),
        ],
        ...output,
      ]),
    );
  }
}

void main() {
  bool hasGit;
  try {
    hasGit = Process.runSync('git', ['--version']).exitCode == 0;
  } catch (_) {
    hasGit = false;
  }
  test(
    'native Git accepts Dart commits, index and multiple-commit push',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'tamtoot-git-interop-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final work = await Directory('${temp.path}/work').create();
      final remote = '${temp.path}/remote.git';
      Future<String> native(List<String> args, {String? at}) async {
        final result = await Process.run('git', args, workingDirectory: at);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return result.stdout as String;
      }

      await native(['init', '--initial-branch=main'], at: work.path);
      await native(['init', '--bare', '--initial-branch=main', remote]);
      final store = FileGitRepositoryStore(work);
      final db = GitObjectDatabase(store, archiveInflateAt, archiveDeflate);
      await db.writeConfig(
        remote: Uri.parse('https://example.com/repo.git'),
        branch: 'main',
      );
      final service = HttpGitService(
        transport: NativeReceivePack(remote),
        openStore: (_) => store,
        inflateAt: archiveInflateAt,
        deflate: archiveDeflate,
      );
      await service.setIdentity(work.uri, 'Test Author', 'test@example.com');
      final special = 'folder/тест #1%.txt';
      await store.writeText(special, 'first');
      (await service.add(work.uri, paths: [special])).ensureOk();
      (await service.commit(work.uri, 'Initial')).ensureOk();
      expect(await native(['status', '--porcelain'], at: work.path), isEmpty);
      (await service.push(work.uri, setUpstream: true)).ensureOk();
      for (final content in ['second', 'third']) {
        await store.writeText(special, content);
        (await service.add(work.uri, paths: [special])).ensureOk();
        (await service.commit(work.uri, content)).ensureOk();
      }
      await store.writeText('unselected.txt', 'local only');
      (await service.push(work.uri)).ensureOk();
      await native(['fsck', '--strict'], at: remote);
      expect(
        (await native(['rev-list', '--count', 'main'], at: remote)).trim(),
        '3',
      );
      expect(await native(['show', 'main:$special'], at: remote), 'third');
      expect(
        (await native(['status', '--porcelain'], at: work.path)).trim(),
        '?? unselected.txt',
      );
      // Do not overwrite another client's staging.
      await native(['add', 'unselected.txt'], at: work.path);
      final indexBefore = await store.readBytes('.git/index');
      await expectLater(
        service.add(work.uri, paths: [special]),
        throwsA(isA<GitException>()),
      );
      expect(await store.readBytes('.git/index'), indexBefore);
    },
    skip: !hasGit
        ? 'System Git is needed only for this interoperability test'
        : false,
  );
}
