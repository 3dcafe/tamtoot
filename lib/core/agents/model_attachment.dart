import 'dart:convert';
import 'dart:typed_data';

/// Multimodal attachment for OpenAI-compatible chat APIs
/// (STAR / ai.starimg.ru / OpenAI vision & file parts).
class ModelAttachment {
  const ModelAttachment({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;

  static const maxCount = 4;
  static const maxBytesEach = 8 * 1024 * 1024;
  static const maxBytesTotal = 12 * 1024 * 1024;

  String get dataUri => 'data:$mimeType;base64,${base64Encode(bytes)}';

  bool get isImage => mimeType.startsWith('image/');

  bool get isPlainText {
    if (mimeType.startsWith('text/')) return true;
    const textish = {
      'application/json',
      'application/xml',
      'application/javascript',
      'application/typescript',
      'application/x-yaml',
      'application/yaml',
    };
    return textish.contains(mimeType);
  }

  String? get asUtf8Text {
    if (!isPlainText) return null;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  static String mimeForName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.csv')) return 'text/csv';
    if (lower.endsWith('.md')) return 'text/markdown';
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.xml')) return 'application/xml';
    if (lower.endsWith('.html') || lower.endsWith('.htm')) return 'text/html';
    if (lower.endsWith('.doc')) return 'application/msword';
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (lower.endsWith('.xls')) return 'application/vnd.ms-excel';
    if (lower.endsWith('.xlsx')) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (lower.endsWith('.dart') ||
        lower.endsWith('.py') ||
        lower.endsWith('.js') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.java') ||
        lower.endsWith('.kt') ||
        lower.endsWith('.swift') ||
        lower.endsWith('.cs') ||
        lower.endsWith('.go') ||
        lower.endsWith('.rs') ||
        lower.endsWith('.c') ||
        lower.endsWith('.cpp') ||
        lower.endsWith('.h') ||
        lower.endsWith('.yaml') ||
        lower.endsWith('.yml') ||
        lower.endsWith('.toml') ||
        lower.endsWith('.ini') ||
        lower.endsWith('.cfg') ||
        lower.endsWith('.sh')) {
      return 'text/plain';
    }
    return 'application/octet-stream';
  }

  static void validateAll(List<ModelAttachment> attachments) {
    if (attachments.length > maxCount) {
      throw FormatException('Attach at most $maxCount files.');
    }
    var total = 0;
    for (final item in attachments) {
      if (item.name.trim().isEmpty) {
        throw const FormatException('Attachment name is required.');
      }
      if (item.bytes.isEmpty) {
        throw FormatException('Attachment "${item.name}" is empty.');
      }
      if (item.bytes.length > maxBytesEach) {
        throw FormatException(
          'Attachment "${item.name}" exceeds ${maxBytesEach ~/ (1024 * 1024)} MiB.',
        );
      }
      total += item.bytes.length;
    }
    if (total > maxBytesTotal) {
      throw FormatException(
        'Attachments exceed ${maxBytesTotal ~/ (1024 * 1024)} MiB in total.',
      );
    }
  }
}
