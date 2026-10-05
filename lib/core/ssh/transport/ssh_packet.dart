import 'dart:typed_data';
import '../crypto/ssh_crypto.dart';
import '../ssh_error.dart';
import 'ssh_codec.dart';
import 'ssh_wire.dart';

/// Stateful, directional codec. EtM authenticates length+ciphertext before decrypting.
class SshPacketCodec {
  SshPacketCodec(this.crypto);
  final SshCrypto crypto;
  static const maxPacket = 256 * 1024;
  int sequence = 0, packets = 0, transferred = 0;
  SshCipher? _cipher;
  Uint8List? _macKey;
  bool get encrypted => _cipher != null;
  bool get needsRekey => transferred >= 16 * 1024 * 1024 || packets >= 65536;
  void activate(SshCipher cipher, List<int> macKey) {
    _cipher?.dispose();
    _macKey?.fillRange(0, _macKey!.length, 0);
    _cipher = cipher;
    _macKey = Uint8List.fromList(macKey);
    // strict KEX: reset after *each direction's* NEWKEYS.
    sequence = 0;
    packets = 0;
    transferred = 0;
  }

  Uint8List encode(List<int> payload) {
    if (payload.isEmpty || payload.length > maxPacket - 256) {
      throw const SshException('SSH payload exceeds its limit.');
    }
    final block = encrypted ? 16 : 8;
    var padding = block - ((payload.length + (encrypted ? 1 : 5)) % block);
    if (padding < 4) padding += block;
    final body =
        (SshWriter()
              ..byte(padding)
              ..raw(payload)
              ..raw(crypto.randomBytes(padding)))
            .take();
    final protected = _cipher?.apply(body) ?? body;
    final packet =
        (SshWriter()
              ..uint32(protected.length)
              ..raw(protected))
            .take();
    final mac = encrypted
        ? sshHmacSha256(
            crypto,
            _macKey!,
            (SshWriter()
                  ..uint32(sequence)
                  ..raw(packet))
                .take(),
          )
        : <int>[];
    body.fillRange(0, body.length, 0);
    _advance(packet.length);
    return Uint8List.fromList([...packet, ...mac]);
  }

  Future<Uint8List> read(SshWire wire, {bool allowIdle = false}) async {
    final header = allowIdle
        ? Uint8List.fromList([
            ...(await wire.read(1)),
            ...(await wire.read(3).timeout(const Duration(seconds: 30))),
          ])
        : await wire.read(4);
    final length = ByteData.sublistView(header).getUint32(0);
    if (length < 6 ||
        length > maxPacket ||
        (encrypted ? length % 16 != 0 : (length + 4) % 8 != 0)) {
      throw const SshException('Invalid SSH packet length or alignment.');
    }
    final protected = await wire
        .read(length)
        .timeout(const Duration(seconds: 30));
    if (encrypted) {
      final mac = await wire.read(32).timeout(const Duration(seconds: 30));
      final expected = sshHmacSha256(
        crypto,
        _macKey!,
        (SshWriter()
              ..uint32(sequence)
              ..raw(header)
              ..raw(protected))
            .take(),
      );
      if (!sshBytesEqual(mac, expected)) {
        throw const SshException('SSH packet integrity check failed.');
      }
    }
    final body = _cipher?.apply(protected) ?? protected;
    final padding = body[0];
    if (padding < 4 || padding + 2 > body.length) {
      throw const SshException('Invalid SSH packet padding.');
    }
    final payload = Uint8List.fromList(body.sublist(1, body.length - padding));
    body.fillRange(0, body.length, 0);
    _advance(length + 4);
    return payload;
  }

  void _advance(int length) {
    if (sequence >= 0xffffffff) {
      throw const SshException(
        'SSH packet sequence exhausted. Rekey required.',
      );
    }
    sequence++;
    packets++;
    transferred += length;
  }

  void dispose() {
    _cipher?.dispose();
    _cipher = null;
    _macKey?.fillRange(0, _macKey!.length, 0);
    _macKey = null;
  }
}
