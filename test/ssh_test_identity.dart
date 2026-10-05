// TEST ONLY: variable-time signing with the public RFC 8032 test seed.
// Never import this helper from production code or use it for user keys.
import 'dart:typed_data';
import 'package:tamtoot/core/ssh/crypto/ssh_crypto.dart';

Uint8List _littleBytes(BigInt number, int length) => Uint8List.fromList(
  List.generate(
    length,
    (i) => ((number >> (8 * i)) & BigInt.from(255)).toInt(),
  ),
);

class SshTestIdentity {
  SshTestIdentity(this.crypto);
  final SshCrypto crypto;
  static final seed = Uint8List.fromList(
    List.generate(
      32,
      (i) => int.parse(
        '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
            .substring(i * 2, i * 2 + 2),
        radix: 16,
      ),
    ),
  );
  Uint8List get publicKey {
    final digest = crypto.sha512(seed);
    digest[0] &= 248;
    digest[31] = (digest[31] & 63) | 64;
    return _base.multiply(_littleInteger(digest.sublist(0, 32))).encode();
  }

  Uint8List sign(List<int> message) {
    final digest = crypto.sha512(seed), prefix = digest.sublist(32);
    digest[0] &= 248;
    digest[31] = (digest[31] & 63) | 64;
    final scalar = _littleInteger(digest.sublist(0, 32));
    final r = _littleInteger(crypto.sha512([...prefix, ...message])) % _order;
    final encoded = _base.multiply(r).encode();
    final h =
        _littleInteger(crypto.sha512([...encoded, ...publicKey, ...message])) %
        _order;
    return Uint8List.fromList([
      ...encoded,
      ..._littleBytes((r + h * scalar) % _order, 32),
    ]);
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
  Uint8List encode() {
    final inverse = z.modInverse(_prime);
    final result = _littleBytes(y * inverse % _prime, 32);
    result[31] |= ((x * inverse % _prime).isOdd ? 128 : 0);
    return result;
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
