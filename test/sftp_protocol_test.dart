import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/sftp/sftp_client.dart';
import 'package:tamtoot/core/ssh/transport/ssh_codec.dart';
import 'package:tamtoot/core/ssh/transport/ssh_transport.dart';
import 'sftp_test_peer.dart';

void main() {
  test(
    'remote POSIX paths are separate from local paths and root remains root',
    () {
      expect(SftpClient.parent('/'), '/');
      expect(SftpClient.parent('/home/file'), '/home');
      expect(SftpClient.join('/', 'a\\b'), '/a\\b');
      expect(
        () => SftpClient.join('/home', '../escape'),
        throwsA(isA<SftpException>()),
      );
    },
  );

  test(
    'rename race restores changed original; competing destination is never overwritten',
    () async {
      final peer = SftpTestPeer();
      await peer.start();
      addTearDown(peer.ssh.close);
      final sftp = await SftpClient.connect(peer.ssh);
      addTearDown(sftp.close);
      final first = await sftp.snapshot('/home/text.txt');
      peer.beforeRename = (from, to) {
        if (from == first.path) peer.files[from] = List.filled(8, 42);
      };
      await expectLater(
        sftp.writeFile(first.path, [9], expected: first),
        throwsA(isA<SftpConflict>()),
      );
      expect(peer.files[first.path], List.filled(8, 42));
      peer.beforeRename = null;
      final second = await sftp.snapshot(first.path);
      peer.beforeRename = (from, to) {
        if (from.contains('.tamtoot-upload-') && to == first.path) {
          peer.files[to] = [77];
        }
      };
      Object? error;
      try {
        await sftp.writeFile(first.path, [9], expected: second);
      } catch (e) {
        error = e;
      }
      expect(error, isA<SftpConflict>());
      expect(peer.files[first.path], [77]);
      final recovery = (error as SftpConflict).recoveryPath!;
      expect(peer.files[recovery], List.filled(8, 42));
    },
  );
  test(
    'cancelling a stalled source releases the operation and never creates destination',
    () async {
      final peer = SftpTestPeer();
      await peer.start();
      addTearDown(peer.ssh.close);
      final sftp = await SftpClient.connect(peer.ssh);
      addTearDown(sftp.close);
      final source = StreamController<List<int>>();
      addTearDown(source.close);
      final cancel = SshCancellation();
      final writing = expectLater(
        sftp.upload(
          '/home/stalled',
          source.stream,
          length: 3,
          cancellation: cancel,
        ),
        throwsA(isA<SftpException>()),
      );
      await Future<void>.delayed(Duration.zero);
      cancel.cancel();
      await writing;
      expect(peer.files.containsKey('/home/stalled'), false);
    },
  );

  test(
    'fragmented framing, binary roundtrip, listing, version and extensions',
    () async {
      final peer = SftpTestPeer()..fragment = true;
      await peer.start();
      addTearDown(peer.ssh.close);
      final sftp = await SftpClient.connect(peer.ssh);
      addTearDown(sftp.close);
      expect(sftp.extensions['fsync@openssh.com'], '1');
      expect(await sftp.realpath('.'), '/home');
      expect(
        (await sftp.list('/home')).map((e) => e.name),
        containsAll(['text.txt', 'binary.bin']),
      );
      expect(await sftp.readFile('/home/binary.bin'), [0, 255, 7]);
      await sftp.writeFile('/home/new.bin', [1, 0, 255]);
      expect(await sftp.readFile('/home/new.bin'), [1, 0, 255]);
      expect(peer.requests, contains(200));
    },
  );
  test(
    'out-of-order IDs are associated correctly; eight pending requests are bounded',
    () async {
      final peer = SftpTestPeer();
      await peer.start();
      addTearDown(peer.ssh.close);
      final sftp = await SftpClient.connect(peer.ssh);
      addTearDown(sftp.close);
      peer.holdStats = true;
      final a = sftp.stat('/home/text.txt'), b = sftp.stat('/home/binary.bin');
      await Future<void>.delayed(Duration.zero);
      for (final reply in peer.held.reversed) {
        peer.send(reply);
      }
      peer.held.clear();
      expect((await a).size, 8);
      expect((await b).size, 3);
      final pending = List.generate(8, (_) => sftp.stat('/home/text.txt'));
      await expectLater(
        sftp.stat('/home/text.txt'),
        throwsA(isA<SftpException>()),
      );
      await Future<void>.delayed(Duration.zero);
      for (final reply in peer.held) {
        peer.send(reply);
      }
      expect((await Future.wait(pending)).length, 8);
    },
  );
  test(
    'same-size same-mtime conflict is detected by contents and never overwritten',
    () async {
      final peer = SftpTestPeer();
      await peer.start();
      addTearDown(peer.ssh.close);
      final sftp = await SftpClient.connect(peer.ssh);
      addTearDown(sftp.close);
      final original = await sftp.snapshot('/home/text.txt');
      peer.files['/home/text.txt'] = [1, 2, 3, 4, 5, 6, 7, 8];
      await expectLater(
        sftp.writeFile(original.path, [9], expected: original),
        throwsA(isA<SftpConflict>()),
      );
      expect(peer.files[original.path], [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(peer.requests.where((p) => p == 6), isEmpty);
    },
  );
  for (final kind in ['version', 'packet', 'id']) {
    test('invalid $kind fails all pending work', () async {
      final peer = SftpTestPeer()..malformedVersion = kind == 'version';
      await peer.start();
      addTearDown(peer.ssh.close);
      if (kind == 'version') {
        await expectLater(
          SftpClient.connect(peer.ssh),
          throwsA(isA<SftpException>()),
        );
        return;
      }
      final sftp = await SftpClient.connect(peer.ssh);
      addTearDown(sftp.close);
      peer.holdStats = true;
      final pending = expectLater(
        sftp.stat('/home/text.txt'),
        throwsA(isA<SftpException>()),
      );
      await Future<void>.delayed(Duration.zero);
      if (kind == 'packet') {
        peer.wire.emit(
          (SshWriter()
                ..byte(94)
                ..uint32(0)
                ..string([0x7f, 0xff, 0xff, 0xff]))
              .take(),
        );
      } else {
        peer.send(
          (SshWriter()
                ..byte(105)
                ..uint32(999)
                ..uint32(0))
              .take(),
        );
      }
      await pending;
      expect(sftp.closed, true);
    });
  }
  test(
    'cancel after upload success is inert; cancelled download never returns bytes',
    () async {
      final peer = SftpTestPeer();
      await peer.start();
      addTearDown(peer.ssh.close);
      final sftp = await SftpClient.connect(peer.ssh);
      addTearDown(sftp.close);
      final complete = SshCancellation();
      await sftp.writeFile('/home/success', [1], cancellation: complete);
      complete.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(sftp.closed, false);
      final cancel = SshCancellation();
      await expectLater(
        sftp.readFile(
          '/home/text.txt',
          cancellation: cancel,
          progress: (_, _) => cancel.cancel(),
        ),
        throwsA(isA<SftpException>()),
      );
      expect(sftp.closed, true);
    },
  );
}
