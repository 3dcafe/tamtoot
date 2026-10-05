import 'dart:convert';
import 'dart:typed_data';
import '../crypto/ssh_crypto.dart';
import '../ssh_error.dart';
import '../transport/ssh_codec.dart';

Uint8List _positive(SshReader reader, {int limit = 513}) {
  var bytes = reader.string(limit: limit);
  if (bytes.isEmpty || bytes[0] >= 128) {
    throw const SshException('Invalid private-key integer.');
  }
  if (bytes[0] == 0) {
    if (bytes.length == 1 || bytes[1] < 128) {
      throw const SshException('Noncanonical private-key integer.');
    }
    bytes = Uint8List.sublistView(bytes, 1);
  }
  return bytes;
}

class SshIdentity {
  SshIdentity(this.algorithm, List<int> blob, this.signer)
    : publicBlob = Uint8List.fromList(blob);
  final String algorithm;
  final Uint8List publicBlob;
  final SshSigner signer;
  void dispose() => signer.dispose();
}

/// Bounded OpenSSH container. Always dispose to clear its private byte buffer.
class OpenSshPrivateKey {
  OpenSshPrivateKey._(
    this.algorithm,
    this.publicBlob,
    this._private,
    this.salt,
    this.rounds,
    this.encrypted,
  );
  final String algorithm;
  final Uint8List publicBlob, salt;
  final Uint8List _private;
  final int rounds;
  final bool encrypted;
  bool _closed = false;
  static OpenSshPrivateKey parse(String pem) {
    const begin = '-----BEGIN OPENSSH PRIVATE KEY-----',
        end = '-----END OPENSSH PRIVATE KEY-----';
    final text = pem.trim();
    if (text.length > 65536 || !text.startsWith(begin) || !text.endsWith(end)) {
      throw const SshException(
        'Expected an OpenSSH Ed25519 or RSA private key, up to 64 KiB.',
      );
    }
    Uint8List? bytes;
    try {
      bytes = base64Decode(
        text
            .substring(begin.length, text.length - end.length)
            .replaceAll(RegExp(r'\s'), ''),
      );
      final reader = SshReader(bytes);
      if (!sshBytesEqual(reader.raw(15), ascii.encode('openssh-key-v1\x00'))) {
        throw const SshException('Invalid OpenSSH private-key container.');
      }
      final cipher = reader.asciiText(limit: 128),
          kdf = reader.asciiText(limit: 128),
          options = reader.string(limit: 128);
      final encrypted = cipher != 'none';
      var rounds = 0;
      var salt = Uint8List(0);
      if (encrypted) {
        if (cipher != 'aes256-ctr' || kdf != 'bcrypt') {
          throw const SshException(
            'Encrypted keys require aes256-ctr and bcrypt.',
          );
        }
        final derivation = SshReader(options);
        salt = Uint8List.fromList(derivation.string(limit: 64));
        rounds = derivation.uint32();
        derivation.end();
        if (salt.length < 8 || rounds < 1 || rounds > 128) {
          throw const SshException(
            'Private-key bcrypt parameters exceed the supported limits (1–128 rounds).',
          );
        }
      } else if (kdf != 'none' || options.isNotEmpty) {
        throw const SshException('Invalid unencrypted private-key parameters.');
      }
      if (reader.uint32() != 1) {
        throw const SshException(
          'Only single-key OpenSSH containers are supported.',
        );
      }
      final blob = Uint8List.fromList(reader.string(limit: 2048));
      final public = SshReader(blob);
      final algorithm = public.asciiText(limit: 128);
      if (algorithm == 'ssh-ed25519') {
        if (public.string(limit: 32).length != 32) {
          throw const SshException('Invalid Ed25519 public key.');
        }
      } else if (algorithm == 'ssh-rsa') {
        final e = _positive(public, limit: 5), n = _positive(public);
        if (e.length > 4 ||
            n.length < 256 ||
            n.length > 512 ||
            (n.length == 256 && n[0] < 128)) {
          throw const SshException(
            'RSA keys must be 2048–4096 bits with a 32-bit public exponent.',
          );
        }
      } else {
        throw const SshException(
          'Only Ed25519 and RSA private keys are supported.',
        );
      }
      public.end();
      final private = Uint8List.fromList(reader.string());
      reader.end();
      final block = encrypted ? 16 : 8;
      if (private.isEmpty || private.length % block != 0) {
        private.fillRange(0, private.length, 0);
        throw const SshException('Invalid private-key block length.');
      }
      return OpenSshPrivateKey._(
        algorithm,
        blob,
        private,
        salt,
        rounds,
        encrypted,
      );
    } on FormatException {
      throw const SshException('Invalid OpenSSH private-key base64.');
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
    }
  }

  Uint8List _material(List<int> clear) {
    final reader = SshReader(clear);
    if (reader.uint32() != reader.uint32()) {
      throw const SshException('Wrong passphrase or malformed private key.');
    }
    if (reader.asciiText(limit: 128) != algorithm) {
      throw const SshException(
        'Private-key algorithm does not match its public key.',
      );
    }
    final public = SshReader(publicBlob)..asciiText(limit: 128);
    Uint8List material;
    if (algorithm == 'ssh-ed25519') {
      final pub = reader.string(limit: 32), key = reader.string(limit: 64);
      if (pub.length != 32 ||
          key.length != 64 ||
          !sshBytesEqual(pub, key.sublist(32)) ||
          !sshBytesEqual(pub, public.string(limit: 32))) {
        throw const SshException(
          'Ed25519 private and public key fields do not match.',
        );
      }
      material = Uint8List.fromList(key);
    } else {
      final n = _positive(reader),
          e = _positive(reader, limit: 5),
          d = _positive(reader),
          iq = _positive(reader),
          p = _positive(reader),
          q = _positive(reader);
      if (!sshBytesEqual(e, _positive(public, limit: 5)) ||
          !sshBytesEqual(n, _positive(public))) {
        throw const SshException(
          'RSA private and public key fields do not match.',
        );
      }
      material =
          (SshWriter()
                ..string(n)
                ..string(e)
                ..string(d)
                ..string(p)
                ..string(q)
                ..string(iq))
              .take();
    }
    try {
      reader.string(limit: 4096); // Comment remains undisplayed.
      if (reader.remaining > (encrypted ? 16 : 8)) {
        throw const SshException('Invalid private-key padding.');
      }
      var padding = 1;
      while (reader.remaining > 0) {
        if (reader.byte() != padding++) {
          throw const SshException(
            'Wrong passphrase or invalid private-key padding.',
          );
        }
      }
      return material;
    } catch (_) {
      material.fillRange(0, material.length, 0);
      rethrow;
    }
  }

  void validateStructure() {
    if (_closed) throw const SshException('Private key is closed.');
    if (!encrypted) {
      final material = _material(_private);
      material.fillRange(0, material.length, 0);
    }
  }

  Future<SshIdentity> unlock(
    SshSigningCrypto crypto, {
    List<int>? passphrase,
  }) async {
    if (_closed) throw const SshException('Private key is closed.');
    Uint8List? clear, derived, material;
    try {
      if (encrypted) {
        if (passphrase == null || passphrase.isEmpty) {
          throw const SshException(
            'A passphrase is required for this private key.',
          );
        }
        derived = await crypto.bcryptPbkdf(passphrase, salt, rounds, 48);
        if (_closed) throw const SshException('Private-key unlock cancelled.');
        final cipher = crypto.createCipher(
          derived.sublist(0, 32),
          derived.sublist(32),
        );
        try {
          clear = cipher.apply(_private);
        } finally {
          cipher.dispose();
        }
      } else {
        clear = Uint8List.fromList(_private);
      }
      material = _material(clear);
      final signer = crypto.createSigner(algorithm, material);
      return SshIdentity(algorithm, publicBlob, signer);
    } finally {
      clear?.fillRange(0, clear.length, 0);
      derived?.fillRange(0, derived.length, 0);
      material?.fillRange(0, material.length, 0);
    }
  }

  void dispose() {
    _closed = true;
    _private.fillRange(0, _private.length, 0);
  }
}

void validateOpenSshPrivateKey(String pem) {
  OpenSshPrivateKey? key;
  try {
    key = OpenSshPrivateKey.parse(pem);
    key.validateStructure();
  } on SshException catch (e) {
    throw FormatException(e.message);
  } finally {
    key?.dispose();
  }
}
