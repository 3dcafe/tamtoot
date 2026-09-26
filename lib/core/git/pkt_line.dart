import 'dart:convert';
import 'dart:typed_data';

/// Git pkt-line framing (https://git-scm.com/docs/protocol-common#_pkt_line_format).
final class PktLine {
  static const flush = <int>[]; // represented as 0000
  static final _hex = '0123456789abcdef'.codeUnits;

  static List<int> encode(List<int> data) {
    final length = data.length + 4;
    if (length > 0xffff) {
      throw ArgumentError('pkt-line too long: $length');
    }
    final out = BytesBuilder(copy: false);
    out.addByte(_hex[(length >> 12) & 0xf]);
    out.addByte(_hex[(length >> 8) & 0xf]);
    out.addByte(_hex[(length >> 4) & 0xf]);
    out.addByte(_hex[length & 0xf]);
    out.add(data);
    return out.toBytes();
  }

  static List<int> encodeText(String text, {bool newline = true}) {
    final payload = newline ? '$text\n' : text;
    return encode(utf8.encode(payload));
  }

  static List<int> encodeFlush() => utf8.encode('0000');

  static List<int> encodeDelim() => utf8.encode('0001');
}

/// Streaming pkt-line reader over a byte buffer.
final class PktLineReader {
  PktLineReader(List<int> bytes) : _data = Uint8List.fromList(bytes);

  final Uint8List _data;
  int _offset = 0;

  bool get hasMore => _offset < _data.length;

  /// Returns payload bytes, empty list for flush (0000), or null at EOF.
  List<int>? next() {
    if (_offset + 4 > _data.length) return null;
    final len = int.parse(
      String.fromCharCodes(_data.sublist(_offset, _offset + 4)),
      radix: 16,
    );
    _offset += 4;
    if (len == 0) return const [];
    if (len == 1 || len == 2) {
      // delimiter / response-end; treat as empty marker
      return const [];
    }
    if (len < 4 || _offset + (len - 4) > _data.length) {
      throw FormatException('Invalid pkt-line length $len at $_offset');
    }
    final payload = _data.sublist(_offset, _offset + len - 4);
    _offset += len - 4;
    return payload;
  }

  String? nextText() {
    final payload = next();
    if (payload == null) return null;
    if (payload.isEmpty) return '';
    var text = utf8.decode(payload);
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    return text;
  }
}
