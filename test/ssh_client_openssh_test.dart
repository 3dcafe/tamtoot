import 'dart:convert';
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
