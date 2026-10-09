import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'model_attachment.dart';

/// Run-local aliases: originals never leave this object via an outbound prompt.
/// This is host masking, not a general secret scanner or anonymizer.
class AgentPrivacy {
  AgentPrivacy()
    : _nonce = List.generate(
        2,
        (_) => Random.secure().nextInt(0x100000000).toRadixString(16),
      ).join();

  final String _nonce;
  final _aliases = <String, String>{};
  final _originals = <String, String>{};
  static final _url = RegExp(
    r'\b(?:https?|wss?|ftp|ssh|git)://([^\s/<>"\x27?#]+)',
    caseSensitive: false,
  );
  static final _domain = RegExp(
    r'(?<![\w-])(?:[a-z0-9\u0080-\uffff](?:[a-z0-9\u0080-\uffff-]*[a-z0-9\u0080-\uffff])?\.)+(?:[a-z\u0080-\uffff]{2,63}|xn--[a-z0-9-]+)(?![\w-])',
    caseSensitive: false,
  );
  static final _ipv4 = RegExp(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])');
  static final _ipv6 = RegExp(r'\[[0-9a-f:]+\]', caseSensitive: false);
  static const _fileSuffixes = {
    'dart',
    'md',
    'txt',
    'json',
    'yaml',
    'yml',
    'xml',
    'html',
    'htm',
    'css',
    'scss',
    'js',
    'mjs',
    'cjs',
    'ts',
    'tsx',
    'jsx',
    'py',
    'pyi',
    'pyw',
    'kt',
    'kts',
    'java',
    'class',
    'jar',
    'cs',
    'csproj',
    'sln',
    'c',
    'h',
    'cpp',
    'hpp',
    'swift',
    'm',
    'mm',
    'rs',
    'go',
    'rb',
    'sh',
    'toml',
    'lock',
    'ini',
    'cfg',
    'conf',
    'properties',
    'gradle',
    'sql',
    'png',
    'jpg',
    'jpeg',
    'gif',
    'svg',
    'webp',
    'pdf',
    'zip',
    'log',
  };

  String _alias(String original) => _aliases.putIfAbsent(original, () {
    final alias = 'private-$_nonce-${_aliases.length + 1}.invalid';
    _originals[alias] = original;
    return alias;
  });

  String mask(String text) {
    var result = text.replaceAllMapped(_url, (match) {
      final authority = match.group(1)!;
      if (_originals.containsKey(authority)) return match.group(0)!;
      return '${match.group(0)!.substring(0, match.group(0)!.length - authority.length)}${_alias(authority)}';
    });
    result = result.replaceAllMapped(_domain, (match) {
      final value = match.group(0)!;
      if (_originals.containsKey(value) ||
          _fileSuffixes.contains(value.split('.').last.toLowerCase())) {
        return value;
      }
      return _alias(value);
    });
    result = result.replaceAllMapped(_ipv4, (match) => _alias(match.group(0)!));
    return result.replaceAllMapped(_ipv6, (match) => _alias(match.group(0)!));
  }

  String restore(String text) {
    // Match whole aliases so alias 1 cannot change the prefix of alias 10.
    final pattern = RegExp('private-${RegExp.escape(_nonce)}-\\d+\\.invalid');
    return text.replaceAllMapped(
      pattern,
      (m) => _originals[m.group(0)] ?? m.group(0)!,
    );
  }

  dynamic maskValue(dynamic value) => _map(value, mask);
  dynamic restoreValue(dynamic value) => _map(value, restore);
  dynamic _map(dynamic value, String Function(String) transform) {
    if (value is String) return transform(value);
    if (value is List) return value.map((v) => _map(v, transform)).toList();
    if (value is Map<String, dynamic>) {
      return value.map((key, v) => MapEntry(key, _map(v, transform)));
    }
    return value;
  }

  List<ModelAttachment> prepareAttachments(List<ModelAttachment> attachments) {
    return [for (final item in attachments) _prepareAttachment(item)];
  }

  ModelAttachment _prepareAttachment(ModelAttachment item) {
    final text = item.asUtf8Text;
    if (text == null) {
      throw const FormatException(
        'Enhanced privacy supports text attachments only. Remove images, PDFs and binary files before sending.',
      );
    }
    return ModelAttachment(
      name: mask(item.name),
      mimeType: 'text/plain',
      bytes: Uint8List.fromList(utf8.encode(mask(text))),
    );
  }
}
