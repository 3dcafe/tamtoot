import 'dart:convert';
import 'dart:typed_data';
import '../ssh_error.dart';

class SshWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  SshWriter byte(int value) {
    _bytes.addByte(value);
    return this;
  }

  SshWriter uint32(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw const SshException('Invalid SSH integer.');
    }
    _bytes.add((ByteData(4)..setUint32(0, value)).buffer.asUint8List());
    return this;
  }

  SshWriter raw(List<int> value) {
    _bytes.add(value);
    return this;
  }

  SshWriter string(List<int> value) {
    uint32(value.length);
    raw(value);
    return this;
  }

  SshWriter text(String value) => string(utf8.encode(value));
  SshWriter names(List<String> value) => text(value.join(','));
  SshWriter mpint(List<int> bigEndian) {
    var first = 0;
    while (first < bigEndian.length && bigEndian[first] == 0) {
      first++;
    }
    if (first == bigEndian.length) return string([]);
    return string([
      if (bigEndian[first] >= 128) 0,
      ...bigEndian.sublist(first),
    ]);
  }

  Uint8List take() => _bytes.takeBytes();
}

class SshReader {
  SshReader(List<int> bytes)
    : bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final Uint8List bytes;
  int offset = 0;
  int get remaining => bytes.length - offset;
  Uint8List raw(int length) {
    if (length < 0 || length > remaining) {
      throw const SshException('Malformed SSH message.');
    }
    final value = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return value;
  }

  int byte() => raw(1)[0];
  bool boolean() {
    final b = byte();
    if (b > 1) throw const SshException('Malformed SSH boolean.');
    return b == 1;
  }

  int uint32() => ByteData.sublistView(raw(4)).getUint32(0);
  Uint8List string({int limit = 65536}) {
    final length = uint32();
    if (length > limit) {
      throw const SshException('SSH field exceeds its limit.');
    }
    return raw(length);
  }

  String asciiText({int limit = 65536}) {
    try {
      return ascii.decode(string(limit: limit));
    } on FormatException {
      throw const SshException('SSH identifier is not ASCII.');
    }
  }

  List<String> names() {
    final text = asciiText(limit: 16384);
    if (text.isEmpty) return [];
    final names = text.split(',');
    if (names.length > 128 ||
        names.any(
          (name) =>
              name.isEmpty ||
              name.length > 128 ||
              !RegExp(r'^[!-~]+$').hasMatch(name),
        )) {
      throw const SshException('Malformed SSH algorithm list.');
    }
    return names;
  }

  void end() {
    if (remaining != 0) {
      throw const SshException('Unexpected SSH message data.');
    }
  }
}
