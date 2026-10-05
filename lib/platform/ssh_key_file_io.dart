import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

Future<String> readSshKeyFile(Uri uri) async {
  if (Platform.isAndroid && uri.scheme == 'content') {
    return await const MethodChannel(
          'dev.tamtoot/documents',
        ).invokeMethod<String>('readText', {
          'uri': uri.toString(),
          'maxBytes': 65536,
        }) ??
        '';
  }
  final file = File.fromUri(uri);
  if (await file.length() > 65536) {
    throw const FormatException('SSH key exceeds 64 KiB.');
  }
  final bytes = <int>[];
  await for (final chunk in file.openRead()) {
    if (bytes.length + chunk.length > 65536) {
      throw const FormatException('SSH key exceeds 64 KiB.');
    }
    bytes.addAll(chunk);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const FormatException('SSH key is not UTF-8 text.');
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}
