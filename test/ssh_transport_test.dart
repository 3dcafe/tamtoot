import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/ssh/crypto/ssh_crypto.dart';
import 'package:tamtoot/core/ssh/host_keys/ssh_host_keys.dart';
import 'package:tamtoot/core/ssh/ssh_error.dart';
import 'package:tamtoot/core/ssh/transport/ssh_codec.dart';
import 'package:tamtoot/core/ssh/transport/ssh_packet.dart';
import 'package:tamtoot/core/ssh/transport/ssh_transport.dart';
import 'package:tamtoot/core/ssh/transport/ssh_wire.dart';
import 'package:tamtoot/platform/ssh_crypto/ssh_crypto_io.dart';
import 'ssh_native_support.dart';
import 'support.dart';

Uint8List hexBytes(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);
String toHex(List<int> value) =>
    value.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class PacketWire implements SshWire {
  PacketWire(List<int> input) : input = Uint8List.fromList(input);
  final Uint8List input;
  int offset = 0;
  bool closed = false;
  final writes = <Uint8List>[];
  @override
  Future<Uint8List> read(int length) async {
    if (closed || offset + length > input.length)
      throw const SshException('Test wire ended');
    final bytes = Uint8List.fromList(input.sublist(offset, offset + length));
    offset += length;
    return bytes;
  }

  @override
  Future<void> write(List<int> bytes) async {
    writes.add(Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  late NativeSshCrypto crypto;
  Directory? directory;
  setUpAll(() async {
    final native = await buildSshTestCrypto();
    crypto = native.crypto;
    directory = native.directory;
  });
  tearDownAll(() async {
    await directory?.delete(recursive: true);
  });
  test('native SHA and HMAC match published test vectors', () {
    expect(
      toHex(crypto.sha256(utf8.encode('abc'))),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      toHex(crypto.sha512(utf8.encode('abc'))),
      'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f',
    );
    expect(
      toHex(
        sshHmacSha256(crypto, List.filled(20, 0x0b), ascii.encode('Hi There')),
      ),
      'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
    );
    expect(crypto.randomBytes(32), isNot(orderedEquals(List.filled(32, 0))));
  });
  test(
    'X25519 RFC 7748 known shared secret, symmetric ephemeral exchange and low-order rejection',
    () {
      final allocate = crypto.library
          .lookupFunction<
            Pointer<Uint8> Function(UintPtr),
            Pointer<Uint8> Function(int)
          >('tamtoot_ssh_alloc');
      final free = crypto.library
          .lookupFunction<
            Void Function(Pointer<Uint8>, UintPtr),
            void Function(Pointer<Uint8>, int)
          >('tamtoot_ssh_free');
      final x = crypto.library
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>),
            int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)
          >('tamtoot_ssh_x25519');
      final memory = allocate(96);
      try {
        memory
            .asTypedList(32)
            .setAll(
              0,
              hexBytes(
                '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a',
              ),
            );
        (memory + 32)
            .asTypedList(32)
            .setAll(
              0,
              hexBytes(
                'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f',
              ),
            );
        expect(x(memory, memory + 32, memory + 64), 1);
        expect(
          toHex((memory + 64).asTypedList(32)),
          '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742',
        );
      } finally {
        free(memory, 96);
      }
      final a = crypto.createExchange(), b = crypto.createExchange();
      try {
        expect(a.sharedSecret(b.publicKey), b.sharedSecret(a.publicKey));
        expect(
          () => a.sharedSecret(List.filled(32, 0)),
          throwsA(isA<SshException>()),
        );
      } finally {
        a.dispose();
        b.dispose();
      }
      expect(
        () => a.sharedSecret(List.filled(32, 9)),
        throwsA(isA<SshException>()),
      );
    },
  );
  test('AES-256 CTR NIST vector survives partial blocks', () {
    final cipher = crypto.createCipher(
      hexBytes(
        '603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4',
      ),
      hexBytes('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff'),
    );
    final plaintext = hexBytes(
      '6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710',
    );
    try {
      final output = [
        ...cipher.apply(plaintext.sublist(0, 1)),
        ...cipher.apply(plaintext.sublist(1, 16)),
        ...cipher.apply(plaintext.sublist(16, 33)),
        ...cipher.apply(plaintext.sublist(33)),
      ];
      expect(
        toHex(output),
        '601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c52b0930daa23de94ce87017ba2d84988ddfc9c58db67aada613c2dd08457941a6',
      );
    } finally {
      cipher.dispose();
    }
  });
  test(
    'Ed25519 RFC 8032 vector rejects tampered messages, identity keys and noncanonical S',
    () {
      final key = hexBytes(
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
      );
      final signature = hexBytes(
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      );
      expect(sshVerifyEd25519(crypto, key, [], signature), isTrue);
      expect(sshVerifyEd25519(crypto, key, [1], signature), isFalse);
      expect(
        sshVerifyEd25519(crypto, [1, ...List.filled(31, 0)], [], signature),
        isFalse,
      );
      signature[63] |= 128;
      expect(sshVerifyEd25519(crypto, key, [], signature), isFalse);
      expect(
        sshVerifyEd25519(crypto, List.filled(32, 255), [], signature),
        isFalse,
      );
    },
  );
  test(
    'packet stream accepts concatenated plaintext and encrypted packets; MAC is checked before decryption',
    () async {
      final out = SshPacketCodec(crypto), input = SshPacketCodec(crypto);
      final wire = PacketWire([
        ...out.encode([2, 3]),
        ...out.encode([4, 5]),
      ]);
      expect(await input.read(wire), [2, 3]);
      expect(await input.read(wire), [4, 5]);
      final key = List.filled(32, 7),
          iv = List.filled(16, 8),
          mac = List.filled(32, 9);
      out.activate(crypto.createCipher(key, iv), mac);
      input.activate(crypto.createCipher(key, iv), mac);
      final packet = out.encode([94, ...List.generate(512, (i) => i % 256)]);
      final corrupted = Uint8List.fromList(packet)..[10] ^= 1;
      await expectLater(
        input.read(PacketWire(corrupted)),
        throwsA(isA<SshException>()),
      );
      expect(input.sequence, 0); // Failed MAC must not advance sequence or CTR.
      expect((await input.read(PacketWire(packet))).length, 513);
      expect(input.sequence, 1);
      out.dispose();
      input.dispose();
    },
  );
  test(
    'oversized length, short payload and malformed padding are rejected',
    () async {
      final codec = SshPacketCodec(crypto);
      await expectLater(
        codec.read(PacketWire((SshWriter()..uint32(0xffffffff)).take())),
        throwsA(isA<SshException>()),
      );
      await expectLater(
        codec.read(PacketWire([0, 0, 0, 12, 3, ...List.filled(11, 0)])),
        throwsA(isA<SshException>()),
      );
      await expectLater(
        codec.read(PacketWire([0, 0, 0, 12, 12, ...List.filled(11, 0)])),
        throwsA(isA<SshException>()),
      );
      codec.dispose();
    },
  );
  test(
    'known hosts normalize endpoints; changed keys always request trust and allow multiple keys',
    () async {
      final store = MemoryStore(), hosts = SshHostKeys(MemoryStore());
      final repository = SshHostKeys(store);
      SshHostKey key(int n) => SshHostKey(
        (SshWriter()
              ..text('ssh-ed25519')
              ..string(List.filled(32, n)))
            .take(),
        crypto,
      );
      var prompts = 0;
      await repository.verify('SERVER.Example.', 22, key(1), crypto, (
        challenge,
      ) async {
        prompts++;
        expect(challenge.changed, isFalse);
        return SshHostKeyDecision.save;
      });
      await repository.verify('server.example', 22, key(1), crypto, (_) async {
        fail('already trusted');
      });
      await repository.verify('server.example', 22, key(2), crypto, (
        challenge,
      ) async {
        prompts++;
        expect(challenge.previousFingerprints, [key(1).fingerprint]);
        return SshHostKeyDecision.once;
      });
      expect(repository.hosts.single.keys.length, 1);
      await expectLater(
        repository.verify(
          'server.example',
          22,
          key(2),
          crypto,
          (_) async => SshHostKeyDecision.reject,
        ),
        throwsA(isA<SshException>()),
      );
      await repository.verify(
        'server.example',
        22,
        key(2),
        crypto,
        (_) async => SshHostKeyDecision.save,
      );
      expect(repository.hosts.single.keys.length, 2);
      final restored = SshHostKeys(store);
      await restored.restore();
      expect(restored.hosts.single.keys.length, 2);
      await restored.verify(
        'server.example',
        22,
        key(3),
        crypto,
        (_) async => SshHostKeyDecision.replace,
      );
      expect(restored.hosts.single.keys.length, 1);
      await restored.forget('SERVER.EXAMPLE.', 22, key(3).blob);
      expect(restored.hosts, isEmpty);
      expect(prompts, 2);
      expect(hosts.hosts, isEmpty);
      expect(
        normalizeSshHost('[2001:db8::1]'),
        normalizeSshHost('2001:0db8:0:0:0:0:0:1'),
      );
      expect(
        normalizeSshHost('::ffff:192.0.2.1'),
        normalizeSshHost('0:0:0:0:0:ffff:c000:201'),
      );
    },
  );
  test(
    'transport refuses application payloads before trust, closes malformed handshake and supports cancellation',
    () async {
      final wire = PacketWire(ascii.encode('SSH-1.5-old\r\n'));
      final transport = SshTransport(
        crypto: crypto,
        hostKeys: SshHostKeys(MemoryStore()),
        openWire: (_, _, _) async => wire,
      );
      await expectLater(transport.send([50]), throwsA(isA<SshException>()));
      await expectLater(
        transport.connect(
          'localhost',
          22,
          confirm: (_) async => SshHostKeyDecision.save,
        ),
        throwsA(isA<SshException>()),
      );
      expect(wire.closed, isTrue);
      expect(transport.state, SshTransportState.closed);
      final cancelled = SshTransport(
        crypto: crypto,
        hostKeys: SshHostKeys(MemoryStore()),
        openWire: (_, _, _) async => throw StateError('must not connect'),
      );
      await cancelled.close();
      await expectLater(
        cancelled.connect(
          'localhost',
          22,
          confirm: (_) async => SshHostKeyDecision.once,
        ),
        throwsA(isA<SshException>()),
      );
    },
  );
}
