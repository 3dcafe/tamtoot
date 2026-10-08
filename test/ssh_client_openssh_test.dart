import 'dart:convert';
import 'package:tamtoot/core/sftp/sftp_client.dart';
import 'package:tamtoot/core/terminal/terminal_screen.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/ssh/auth/ssh_private_key.dart';
import 'package:tamtoot/core/ssh/host_keys/ssh_host_keys.dart';
import 'package:tamtoot/core/ssh/ssh_client.dart';
import 'package:tamtoot/core/ssh/ssh_error.dart';
import 'package:tamtoot/core/ssh/transport/ssh_codec.dart';
import 'package:tamtoot/core/ssh/transport/ssh_transport.dart';
import 'package:tamtoot/platform/ssh_crypto/ssh_crypto_io.dart';
import 'package:tamtoot/platform/ssh_wire_io.dart';
import 'ssh_native_support.dart';
import 'ssh_openssh_interop_test.dart' show LocalSshServer, makeHostKey;
import 'support.dart';

void main() {
  if (!File('/usr/sbin/sshd').existsSync() ||
      !File('/usr/bin/ssh-keygen').existsSync()) {
    test(
      'OpenSSH server available',
      () {},
      skip: 'Independent OpenSSH test server unavailable',
    );
    return;
  }
  late NativeSshCrypto crypto;
  Directory? nativeDirectory;
  late Directory root, caseDirectory;
  late String hostKey;
  late LocalSshServer server;
  SshClient? client;
  setUpAll(() async {
    final native = await buildSshTestCrypto();
    crypto = native.crypto;
    nativeDirectory = native.directory;
    root = await Directory.systemTemp.createTemp('tamtoot-ssh-auth-tests-');
    hostKey = '${root.path}/host';
    await makeHostKey(hostKey);
  });
  tearDownAll(() async {
    await root.delete(recursive: true);
    await nativeDirectory?.delete(recursive: true);
  });
  setUp(() async {
    caseDirectory = await Directory(root.path).createTemp('case-');
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = reservation.port;
    await reservation.close();
    server = LocalSshServer(caseDirectory, port, hostKey);
    await server.start();
  });
  tearDown(() async {
    await client?.close();
    client = null;
    await server.stop();
    await caseDirectory.delete(recursive: true);
  });
  Future<String> key(
    String kind,
    bool encrypted, {
    bool authorize = true,
    int bits = 2048,
  }) async {
    final file = '${caseDirectory.path}/identity';
    final result = await Process.run('/usr/bin/ssh-keygen', [
      '-q',
      '-t',
      kind,
      if (kind == 'rsa') ...['-b', bits.toString()],
      '-a',
      '4',
      '-N',
      encrypted ? 'test-only-passphrase' : '',
      '-f',
      file,
    ]);
    if (result.exitCode != 0) {
      throw StateError('Test fixture generation failed.');
    }
    if (authorize) {
      await File(
        '${caseDirectory.path}/authorized_keys',
      ).writeAsString(await File('$file.pub').readAsString());
    }
    return File(file).readAsString();
  }

  Future<SshClient> connect() async {
    final transport = SshTransport(
      crypto: crypto,
      hostKeys: SshHostKeys(MemoryStore()),
      openWire: openSshWire,
    );
    final protocol = SshClient(transport);
    client = protocol;
    await transport.connect(
      '127.0.0.1',
      server.port,
      confirm: (_) async => SshHostKeyDecision.once,
    );
    return protocol;
  }

  Future<void> login(
    SshClient protocol,
    String pem, {
    bool encrypted = false,
  }) async {
    await protocol.login(
      Platform.environment['USER']!,
      preferKey: true,
      identity: () async {
        final parsed = OpenSshPrivateKey.parse(pem);
        try {
          return await parsed.unlock(
            crypto,
            passphrase: encrypted ? utf8.encode('test-only-passphrase') : null,
          );
        } finally {
          parsed.dispose();
        }
      },
    );
  }

  test(
    'real OpenSSH PTY: TERM, resize, Unicode input, Ctrl-C and shell exit',
    () async {
      final pem = await key('ed25519', false), protocol = await connect();
      await login(protocol, pem);
      final output = StringBuffer();
      final terminal = TerminalScreen(columns: 80, rows: 24);
      final channel = await protocol.openShell(
        columns: 80,
        rows: 24,
        onOutput: (o) {
          output.write(utf8.decode(o.data, allowMalformed: true));
          terminal.add(o.data);
        },
      );
      Future<void> waitFor(String value) async {
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (!output.toString().contains(value)) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('Expected PTY marker not received: $value');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      Future<void> send(String value) => channel.writeStdin(utf8.encode(value));
      await send(
        'stty -echo; export LC_ALL=en_US.UTF-8; printf "__TERM_%s__\\n" "\$TERM"; stty size\n',
      );
      await waitFor('__TERM_vt100__');
      await waitFor('24 80');
      terminal.resize(83, 25);
      await channel.resize(83, 25);
      await send('stty size\n');
      await waitFor('25 83');
      await send('read v; printf "__UTF_%s__\\n" "\$v"\n');
      await send('界e\u0301\n');
      await waitFor('__UTF_界e\u0301__');
      await send('sleep 30\n');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await channel.writeStdin([3]);
      await send('printf "__AFTER_INTERRUPT__\\n"\n');
      await waitFor('__AFTER_INTERRUPT__');
      await send('printf "\\033[31mRED\\033[0m\\n"; exit 0\n');
      expect((await channel.result).exitStatus, 0);
      expect(output.toString(), contains('RED'));
      expect(terminal.lines.length, 25);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'real OpenSSH PTY full-screen vi edits a fixture after resize',
    () async {
      final pem = await key('ed25519', false), protocol = await connect();
      await login(protocol, pem);
      final screen = TerminalScreen(columns: 80, rows: 24);
      var output = '';
      final channel = await protocol.openShell(
        columns: 80,
        rows: 24,
        onOutput: (o) {
          screen.add(o.data);
          output += utf8.decode(o.data, allowMalformed: true);
        },
      );
      final file = '${caseDirectory.path}/terminal-editor.txt';
      await channel.writeStdin(
        utf8.encode("stty -echo; vi -u NONE -i NONE -n '$file'\n"),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (!output.contains('[J') && !output.contains('[2J')) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError(
            'vi did not initialize the screen: ${output.replaceAll('\x1b', '<ESC>')}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      screen.resize(100, 30);
      await channel.resize(100, 30);
      await channel.writeStdin(utf8.encode('iNative PTY editor\x1b:wq\r'));
      final saved = DateTime.now().add(const Duration(seconds: 8));
      while (!await File(file).exists()) {
        if (DateTime.now().isAfter(saved)) {
          throw StateError('vi did not write the fixture');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await File(file).readAsString(), 'Native PTY editor\n');
      await channel.writeStdin(utf8.encode('exit 0\n'));
      expect((await channel.result).exitStatus, 0);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'real OpenSSH PTY process monitor accepts refresh, resize and quit',
    () async {
      final pem = await key('ed25519', false), protocol = await connect();
      await login(protocol, pem);
      final screen = TerminalScreen(columns: 100, rows: 30);
      var output = '';
      final channel = await protocol.openShell(
        columns: 100,
        rows: 30,
        onOutput: (o) {
          screen.add(o.data);
          output += utf8.decode(o.data, allowMalformed: true);
        },
      );
      await channel.writeStdin(utf8.encode('stty -echo; top -s 1\n'));
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (!output.contains('Processes:')) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Process monitor did not draw a screen');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      screen.resize(90, 25);
      await channel.resize(90, 25);
      await channel.writeStdin(utf8.encode('q'));
      await channel.writeStdin(utf8.encode('exit 0\n'));
      expect((await channel.result).exitStatus, 0);
      expect(screen.cursorY, inInclusiveRange(0, 24));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'native SFTP v3 listing, binary transfer, editing conflicts, recovery copy and symlinks',
    () async {
      final pem = await key('ed25519', false), protocol = await connect();
      await login(protocol, pem);
      final sftp = await SftpClient.connect(protocol);
      addTearDown(sftp.close);
      final folder = '${caseDirectory.path}/files';
      await sftp.mkdir(folder);
      expect((await sftp.stat(folder)).directory, true);
      expect(
        await sftp.realpath(folder),
        await Directory(folder).resolveSymbolicLinks(),
      );
      final bytes = Uint8List.fromList(
        List.generate(170000, (i) => (i * 17) % 256),
      );
      var progress = 0;
      final path = '$folder/данные.bin';
      await sftp.writeFile(
        path,
        bytes,
        progress: (done, total) {
          expect(done, greaterThanOrEqualTo(progress));
          progress = done;
        },
      );
      expect(progress, bytes.length);
      expect(await sftp.readFile(path), orderedEquals(bytes));
      expect((await sftp.list(folder)).single.name, 'данные.bin');
      final snapshot = await sftp.snapshot(path);
      final commit = await sftp.writeFile(path, [1, 2, 3], expected: snapshot);
      expect(await sftp.readFile(path), [1, 2, 3]);
      expect(await sftp.readFile(commit.backupPath!), orderedEquals(bytes));
      await expectLater(
        sftp.writeFile(path, [9], expected: snapshot),
        throwsA(isA<SftpConflict>()),
      );
      expect(await sftp.readFile(path), [1, 2, 3]);
      final link = Link('$folder/link');
      await link.create(path);
      expect((await sftp.stat(link.path)).symlink, true);
      expect(await sftp.readlink(link.path), path);
      await expectLater(
        sftp.snapshot(link.path),
        throwsA(isA<SftpException>()),
      );
      await sftp.remove(link.path);
      expect(await File(path).exists(), true);
      await sftp.rename(path, '$folder/renamed.bin');
      expect(await sftp.readFile('$folder/renamed.bin'), [1, 2, 3]);
      await expectLater(
        sftp.rename('$folder/renamed.bin', commit.backupPath!),
        throwsA(isA<SftpException>()),
      );
      final stats = await Future.wait([
        sftp.stat('$folder/renamed.bin'),
        sftp.stat(commit.backupPath!),
      ]);
      expect(stats[0].size, 3);
      await sftp.remove('$folder/renamed.bin');
      await sftp.remove(commit.backupPath!);
      await sftp.remove(folder, directory: true);
      expect(await sftp.tryStat(folder), null);
      final exec = await protocol.openExec('true');
      await exec.finishStdin();
      expect((await exec.result).succeeded, true);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'SFTP cancellation cannot become success or commit a partial file',
    () async {
      final pem = await key('ed25519', false), protocol = await connect();
      await login(protocol, pem);
      final sftp = await SftpClient.connect(protocol);
      addTearDown(sftp.close);
      final token = SshCancellation(),
          path = '${caseDirectory.path}/cancelled.bin';
      await expectLater(
        sftp.writeFile(
          path,
          Uint8List(1024 * 1024),
          cancellation: token,
          progress: (done, total) {
            if (done >= 32768) token.cancel();
          },
        ),
        throwsA(isA<SftpException>()),
      );
      expect(await File(path).exists(), false);
      expect(sftp.closed, true);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  for (final kind in ['ed25519', 'rsa']) {
    for (final encrypted in [false, true]) {
      test(
        'OpenSSH production sign-in $kind encrypted=$encrypted; stdout/stderr/exit',
        () async {
          final pem = await key(kind, encrypted), protocol = await connect();
          await login(protocol, pem, encrypted: encrypted);
          expect(protocol.state, SshClientState.ready);
          final channel = await protocol.openExec(
            "printf 'out'; printf 'err' >&2; exit 7",
          );
          await channel.finishStdin();
          final result = await channel.result;
          expect(utf8.decode(result.stdout), 'out');
          expect(utf8.decode(result.stderr), 'err');
          expect(result.exitStatus, 7);
          expect(result.succeeded, isFalse);
          final next = await protocol.openExec("printf 'next'");
          await next.finishStdin();
          expect(utf8.decode((await next.result).stdout), 'next');
        },
        timeout: const Timeout(Duration(seconds: 45)),
      );
    }
  }
  for (final bits in [3072, 4096]) {
    test(
      'OpenSSH RSA $bits-bit native signature',
      () async {
        final pem = await key('rsa', true, bits: bits),
            protocol = await connect();
        await login(protocol, pem, encrypted: true);
        final channel = await protocol.openExec('true');
        await channel.finishStdin();
        expect((await channel.result).succeeded, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }
  test(
    'RSA accepts RFC 8017 lcm exponent and rejects an incorrect CRT coefficient',
    () async {
      final pem = await key('rsa', false), protocol = await connect();
      final decoded = base64Decode(
        pem.split('\n').where((l) => !l.startsWith('-----')).join(),
      );
      final outer = SshReader(decoded)
        ..raw(15)
        ..string()
        ..string()
        ..string()
        ..uint32();
      final blob = Uint8List.fromList(outer.string());
      final inner = SshReader(outer.string())
        ..uint32()
        ..uint32()
        ..asciiText();
      List<int> number() {
        var value = inner.string();
        if (value[0] == 0) value = Uint8List.sublistView(value, 1);
        return value;
      }

      final n = number(), e = number();
      number();
      final iq = number(), p = number(), q = number();
      BigInt integer(List<int> bytes) => bytes.fold(
        BigInt.zero,
        (value, byte) => (value << 8) | BigInt.from(byte),
      );
      List<int> bytes(BigInt value) {
        final result = <int>[];
        while (value > BigInt.zero) {
          result.add((value & BigInt.from(255)).toInt());
          value >>= 8;
        }
        return result.reversed.toList();
      }

      final pm = integer(p) - BigInt.one, qm = integer(q) - BigInt.one;
      final d = bytes(integer(e).modInverse(pm ~/ pm.gcd(qm) * qm));
      final material =
          (SshWriter()
                ..string(n)
                ..string(e)
                ..string(d)
                ..string(p)
                ..string(q)
                ..string(iq))
              .take();
      final invalid =
          (SshWriter()
                ..string(n)
                ..string(e)
                ..string(d)
                ..string(p)
                ..string(q)
                ..string([1]))
              .take();
      try {
        expect(
          () => crypto.createSigner('ssh-rsa', invalid),
          throwsA(isA<SshException>()),
        );
        await protocol.login(
          Platform.environment['USER']!,
          preferKey: true,
          identity: () async => SshIdentity(
            'ssh-rsa',
            blob,
            crypto.createSigner('ssh-rsa', material),
          ),
        );
        final channel = await protocol.openExec('true');
        await channel.finishStdin();
        expect((await channel.result).succeeded, isTrue);
      } finally {
        decoded.fillRange(0, decoded.length, 0);
        material.fillRange(0, material.length, 0);
        invalid.fillRange(0, invalid.length, 0);
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
  test(
    'native client preserves large stdin/output across server rekey',
    () async {
      final pem = await key('ed25519', true), protocol = await connect();
      await login(protocol, pem, encrypted: true);
      var rekeys = 0;
      final subscription = protocol.transport.states.listen((s) {
        if (s == SshTransportState.rekeying) rekeys++;
      });
      try {
        final channel = await protocol.openExec('/bin/cat');
        final input = Uint8List.fromList(
          List.generate(512 * 1024, (i) => i % 251),
        );
        await channel.writeStdin(input);
        await channel.finishStdin();
        final result = await channel.result;
        expect(result.stdout, orderedEquals(input));
        expect(result.stderr, isEmpty);
        expect(result.exitStatus, 0);
        expect(rekeys, greaterThan(0));
      } finally {
        await subscription.cancel();
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
  test(
    'wrong key has bounded retries and no command becomes available',
    () async {
      final pem = await key('ed25519', false, authorize: false);
      await File('${caseDirectory.path}/authorized_keys').writeAsString('');
      final protocol = await connect();
      for (var attempt = 0; attempt < 6; attempt++) {
        await expectLater(
          login(protocol, pem),
          throwsA(isA<SshAuthenticationRejected>()),
        );
        expect(protocol.state, SshClientState.idle);
      }
      await expectLater(login(protocol, pem), throwsA(isA<SshException>()));
      expect(protocol.state, SshClientState.closed);
      await expectLater(
        protocol.openExec('true'),
        throwsA(isA<SshException>()),
      );
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
  test('wrong passphrase fails without authentication', () async {
    final pem = await key('ed25519', true), protocol = await connect();
    await expectLater(
      protocol.login(
        Platform.environment['USER']!,
        preferKey: true,
        identity: () async {
          final parsed = OpenSshPrivateKey.parse(pem);
          try {
            return await parsed.unlock(
              crypto,
              passphrase: utf8.encode('wrong-test-passphrase'),
            );
          } finally {
            parsed.dispose();
          }
        },
      ),
      throwsA(isA<SshException>()),
    );
    expect(protocol.state, SshClientState.closed);
  });
  test('command timeout is failure, not a late successful exit', () async {
    final pem = await key('ed25519', false), protocol = await connect();
    await login(protocol, pem);
    final channel = await protocol.openExec(
      '/bin/sleep 1',
      timeout: const Duration(milliseconds: 200),
    );
    await channel.finishStdin();
    await expectLater(
      channel.result,
      throwsA(
        isA<SshException>().having(
          (e) => e.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
  });
  test(
    'output limit rejects the command without reporting truncated success',
    () async {
      final pem = await key('ed25519', false), protocol = await connect();
      await login(protocol, pem);
      final channel = await protocol.openExec(
        '/usr/bin/head -c 2200000 /dev/zero',
      );
      await channel.finishStdin();
      await expectLater(
        channel.result,
        throwsA(
          isA<SshException>().having(
            (e) => e.message,
            'message',
            contains('2 MiB'),
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
