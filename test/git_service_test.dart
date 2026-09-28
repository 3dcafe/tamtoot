import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/git/git_delta.dart';
import 'package:tamtoot/core/git/git_http.dart';
import 'package:tamtoot/core/git/git_objects.dart';
import 'package:tamtoot/core/git/git_service.dart';
import 'package:tamtoot/core/git/pkt_line.dart';
import 'package:tamtoot/platform/git_service.dart';

void main() {
  group('parseGitStatusPorcelain', () {
    test('parses modified, untracked and renames', () {
      const raw = '''
 M lib/main.dart
?? new_file.txt
R  old.txt -> renamed.txt
''';
      final entries = parseGitStatusPorcelain(raw);
      expect(entries, hasLength(3));
      expect(entries[0].path, 'lib/main.dart');
      expect(entries[1].isUntracked, isTrue);
      expect(entries[2].renameFrom, 'old.txt');
    });
  });

  group('pkt-line', () {
    test('round-trips text and flush', () {
      final encoded = PktLine.encodeText('want abc');
      final reader = PktLineReader([...encoded, ...PktLine.encodeFlush()]);
      expect(reader.nextText(), 'want abc');
      expect(reader.nextText(), '');
    });
  });

  group('objects', () {
    test('hashes blob like git', () {
      // echo -n 'hello' | git hash-object --stdin
      final hash = hashObject(GitObjectType.blob, utf8.encode('hello'));
      expect(hash, 'b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0');
    });

    test('tree round-trip', () {
      final blobHash = hashObject(GitObjectType.blob, utf8.encode('x'));
      final encoded = encodeTree([TreeEntry('100644', 'a.txt', blobHash)]);
      final parsed = parseTree(encoded);
      expect(parsed, hasLength(1));
      expect(parsed.single.name, 'a.txt');
      expect(parsed.single.hash, blobHash);
    });
  });

  group('delta', () {
    test('applies literal insert delta', () {
      // Minimal delta: base size 0, target size 3, insert "abc"
      final delta = Uint8List.fromList([
        0x00, // base size 0
        0x03, // target size 3
        0x03, // insert 3 bytes
        ...'abc'.codeUnits,
      ]);
      final out = applyGitDelta(const [], delta);
      expect(utf8.decode(out), 'abc');
    });
  });

  group('ref advertisement', () {
    test('parses service header and refs', () {
      final body = BytesBuilder()
        ..add(PktLine.encodeText('# service=git-upload-pack'))
        ..add(PktLine.encodeFlush())
        ..add(
          PktLine.encode(
            utf8.encode(
              '0123456789abcdef0123456789abcdef01234567 HEAD\x00'
              'symref=HEAD:refs/heads/main side-band-64k ofs-delta\n',
            ),
          ),
        )
        ..add(
          PktLine.encodeText(
            '0123456789abcdef0123456789abcdef01234567 refs/heads/main',
          ),
        )
        ..add(PktLine.encodeFlush());
      final discovery = parseRefAdvertisement(
        body.toBytes(),
        'git-upload-pack',
      );
      expect(discovery.defaultBranch, 'refs/heads/main');
      expect(discovery.capabilities.contains('side-band-64k'), isTrue);
      expect(
        discovery.hashFor('refs/heads/main'),
        '0123456789abcdef0123456789abcdef01234567',
      );
    });
  });

  group('gitRemoteWithCredentials', () {
    test('embeds token for HTTPS remotes', () {
      final withAuth = gitRemoteWithCredentials(
        Uri.parse('https://example.com/team/project.git'),
        const GitCredentials(token: 'secret-token'),
      );
      expect(withAuth.userInfo, 'git:secret-token');
    });

    test('rejects non-http remotes', () {
      expect(
        () => gitRemoteWithCredentials(
          Uri.parse('ssh://git@example.com/team/project.git'),
          const GitCredentials(token: 'x'),
        ),
        throwsArgumentError,
      );
    });
  });

  group('PlatformGitService', () {
    test('reports HTTP client version', () async {
      final git = createGitService();
      if (!git.available) return;
      final result = await git.version();
      expect(result.ok, isTrue);
      expect(result.stdout, contains('tamtoot-http-git'));
    });
  });
}
