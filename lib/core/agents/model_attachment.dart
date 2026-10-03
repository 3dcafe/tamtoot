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

  bool get isImage {
    if (!mimeType.startsWith('image/')) return false;
    // SVG is XML source for coding tasks; do not send it as a vision image.
    return !mimeType.contains('svg');
  }

  bool get isPlainText {
    if (mimeType.startsWith('text/')) return true;
    if (mimeType == 'image/svg+xml') return true;
    const textish = {
      'application/json',
      'application/xml',
      'application/javascript',
      'application/typescript',
      'application/x-javascript',
      'application/x-yaml',
      'application/yaml',
      'application/sql',
    };
    return textish.contains(mimeType);
  }

  /// Prefer inlining UTF-8 source into the prompt. STAR / OpenAI-compatible
  /// gateways often ignore custom `type:file` parts for CSS/HTML/etc.
  String? get asUtf8Text {
    if (isImage) return null;
    if (bytes.isEmpty || bytes.contains(0)) return null;
    if (!isPlainText && mimeType != 'application/octet-stream') {
      // Known binary office/pdf types stay as file parts.
      if (mimeType.startsWith('application/') &&
          !mimeType.contains('json') &&
          !mimeType.contains('xml') &&
          !mimeType.contains('javascript') &&
          !mimeType.contains('yaml') &&
          !mimeType.contains('sql') &&
          mimeType != 'application/octet-stream') {
        return null;
      }
    }
    try {
      final text = utf8.decode(bytes);
      // Reject mostly-binary noise that happened to decode.
      if (text.length > 32 && _controlRatio(text) > 0.3) return null;
      return text;
    } on FormatException {
      return null;
    }
  }

  static double _controlRatio(String text) {
    var bad = 0;
    for (final unit in text.codeUnits) {
      if (unit < 9 || (unit > 13 && unit < 32)) bad++;
    }
    return bad / text.length;
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
    if (lower.endsWith('.css') ||
        lower.endsWith('.scss') ||
        lower.endsWith('.sass') ||
        lower.endsWith('.less')) {
      return 'text/css';
    }
    if (lower.endsWith('.cshtml') ||
        lower.endsWith('.razor') ||
        lower.endsWith('.vbhtml')) {
      return 'text/html';
    }
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    if (lower.endsWith('.sql')) return 'application/sql';
    if (lower.endsWith('.vue') ||
        lower.endsWith('.svelte') ||
        lower.endsWith('.jsx') ||
        lower.endsWith('.tsx')) {
      return 'text/plain';
    }
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
        lower.endsWith('.sh') ||
        lower.endsWith('.bat') ||
        lower.endsWith('.ps1') ||
        lower.endsWith('.php') ||
        lower.endsWith('.rb') ||
        lower.endsWith('.r') ||
        lower.endsWith('.pl')) {
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
