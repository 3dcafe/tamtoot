import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/ssh/crypto/ssh_crypto.dart';
import 'package:tamtoot/core/ssh/ssh_error.dart';
import 'package:tamtoot/platform/ssh_crypto/ssh_crypto_io.dart';
import 'ssh_native_support.dart';

Uint8List hex(String value) => Uint8List.fromList(
  List.generate(
    value.length ~/ 2,
    (i) => int.parse(value.substring(2 * i, 2 * i + 2), radix: 16),
  ),
);
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
  final seed = hex(
        '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
      ),
      public = hex(
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
      );
  test(
    'native Ed25519 signing matches RFC 8032; supports deferred disposal during worker job',
    () async {
      final signer = crypto.createSigner('ssh-ed25519', [...seed, ...public]);
      final signing = signer.sign([], 'ssh-ed25519');
      signer.dispose();
      final signature = await signing;
      expect(
        signature,
        orderedEquals(
          hex(
            'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
          ),
        ),
      );
      expect(sshVerifyEd25519(crypto, public, [], signature), isTrue);
      await expectLater(
        signer.sign([], 'ssh-ed25519'),
        throwsA(isA<SshException>()),
      );
    },
  );
  test(
    'native signer rejects mismatched seed/public key and unsupported algorithms',
    () async {
      final altered = Uint8List.fromList(public)..[0] ^= 1;
      expect(
        () => crypto.createSigner('ssh-ed25519', [...seed, ...altered]),
        throwsA(isA<SshException>()),
      );
      final signer = crypto.createSigner('ssh-ed25519', [...seed, ...public]);
      try {
        await expectLater(
          signer.sign([], 'ssh-rsa'),
          throwsA(isA<SshException>()),
        );
        await expectLater(
          signer.sign([], 'rsa-sha2-512'),
          throwsA(isA<SshException>()),
        );
      } finally {
        signer.dispose();
      }
    },
  );
  // OpenBSD-derived vectors: https://github.com/pyca/bcrypt/blob/main/tests/test_bcrypt.py
  test(
    'bcrypt_pbkdf matches the public password/salt four-round vector',
    () async {
      final derived = await crypto.bcryptPbkdf(
        [112, 97, 115, 115, 119, 111, 114, 100],
        [115, 97, 108, 116],
        4,
        32,
      );
      expect(
        derived,
        orderedEquals(
          hex(
            '5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9',
          ),
        ),
      );
    },
  );
}
