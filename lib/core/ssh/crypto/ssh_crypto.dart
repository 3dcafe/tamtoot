import 'dart:typed_data';

abstract interface class SshCipher {
  Uint8List apply(List<int> bytes);
  void dispose();
}

abstract interface class SshKeyExchange {
  Uint8List get publicKey;
  Uint8List sharedSecret(List<int> peer);
  void dispose();
}

abstract interface class SshCrypto {
  Uint8List randomBytes(int length);
  Uint8List sha256(List<int> bytes);
  Uint8List sha512(List<int> bytes);
  SshKeyExchange createExchange();
  SshCipher createCipher(List<int> key, List<int> iv);
}

bool sshBytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var different = 0;
  for (var i = 0; i < a.length; i++) {
    different |= a[i] ^ b[i];
  }
  return different == 0;
}

Uint8List sshHmacSha256(SshCrypto crypto, List<int> key, List<int> data) {
  final normalized = key.length > 64
      ? crypto.sha256(key)
      : Uint8List.fromList(key);
  final inner = Uint8List(64 + data.length), outer = Uint8List(96);
  for (var i = 0; i < 64; i++) {
    final k = i < normalized.length ? normalized[i] : 0;
    inner[i] = k ^ 0x36;
    outer[i] = k ^ 0x5c;
  }
  inner.setRange(64, inner.length, data);
  final digest = crypto.sha256(inner);
  outer.setRange(64, 96, digest);
  try {
    return crypto.sha256(outer);
  } finally {
    normalized.fillRange(0, normalized.length, 0);
    inner.fillRange(0, inner.length, 0);
    outer.fillRange(0, outer.length, 0);
    digest.fillRange(0, digest.length, 0);
  }
}

/// Verification only: BigInt operands here are public, never private scalars.
/// RFC 8032 canonical encodings plus prime-order public key / R validation.
bool sshVerifyEd25519(
  SshCrypto crypto,
  List<int> publicKey,
  List<int> message,
  List<int> signature,
) {
  if (publicKey.length != 32 ||
      signature.length != 64 ||
      message.length > 1024 * 1024) {
    return false;
  }
  try {
    final a = _EdPoint.decode(publicKey),
        r = _EdPoint.decode(signature.sublist(0, 32));
    final s = _littleInteger(signature.sublist(32));
    if (s >= _order ||
        a.isIdentity ||
        !a.multiply(_order).isIdentity ||
        !r.multiply(_order).isIdentity) {
      return false;
    }
    final digest = crypto.sha512([
      ...signature.sublist(0, 32),
      ...publicKey,
      ...message,
    ]);
    final h = _littleInteger(digest) % _order;
    return _base.multiply(s).equals(r.add(a.multiply(h)));
  } on FormatException {
    return false;
  }
}

final _prime = (BigInt.one << 255) - BigInt.from(19);
final _order =
    (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');
final _d =
    (-BigInt.from(121665) * BigInt.from(121666).modInverse(_prime)) % _prime;
final _rootMinusOne = BigInt.two.modPow((_prime - BigInt.one) >> 2, _prime);
final _base = _EdPoint.decode([0x58, ...List.filled(31, 0x66)]);
BigInt _littleInteger(List<int> bytes) {
  var result = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    result = (result << 8) | BigInt.from(bytes[i]);
  }
  return result;
}

class _EdPoint {
  _EdPoint(this.x, this.y, this.z, this.t);
  final BigInt x, y, z, t;
  static final identity = _EdPoint(
    BigInt.zero,
    BigInt.one,
    BigInt.one,
    BigInt.zero,
  );
  bool get isIdentity =>
      x % _prime == BigInt.zero && (y - z) % _prime == BigInt.zero;
  bool equals(_EdPoint other) =>
      (x * other.z - other.x * z) % _prime == BigInt.zero &&
      (y * other.z - other.y * z) % _prime == BigInt.zero;
  factory _EdPoint.decode(List<int> encoded) {
    final bytes = List<int>.from(encoded);
    final sign = bytes[31] >> 7;
    bytes[31] &= 127;
    final y = _littleInteger(bytes);
    if (y >= _prime) throw const FormatException();
    final y2 = y * y % _prime;
    final denominator = (_d * y2 + BigInt.one) % _prime;
    if (denominator == BigInt.zero) throw const FormatException();
    final x2 = (y2 - BigInt.one) * denominator.modInverse(_prime) % _prime;
    var x = x2.modPow((_prime + BigInt.from(3)) >> 3, _prime);
    if (x * x % _prime != x2) x = x * _rootMinusOne % _prime;
    if (x * x % _prime != x2 || (x == BigInt.zero && sign == 1)) {
      throw const FormatException();
    }
    if ((x.isOdd ? 1 : 0) != sign) x = _prime - x;
    return _EdPoint(x, y, BigInt.one, x * y % _prime);
  }
  _EdPoint add(_EdPoint b) {
    final aa = (y - x) * (b.y - b.x) % _prime;
    final bb = (y + x) * (b.y + b.x) % _prime;
    final cc = BigInt.two * _d * t * b.t % _prime;
    final dd = BigInt.two * z * b.z % _prime;
    final e = bb - aa, f = dd - cc, g = dd + cc, h = bb + aa;
    return _EdPoint(
      e * f % _prime,
      g * h % _prime,
      f * g % _prime,
      e * h % _prime,
    );
  }

  _EdPoint multiply(BigInt scalar) {
    var result = identity, power = this;
    for (var i = 0; i < 256; i++) {
      if (((scalar >> i) & BigInt.one) != BigInt.zero) {
        result = result.add(power);
      }
      power = power.add(power);
    }
    return result;
  }
}
