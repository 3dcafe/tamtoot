import 'dart:io';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
export 'sftp_files_stub.dart' show SftpLocalFile;
import 'sftp_files_stub.dart' show SftpLocalFile;

const _channel = MethodChannel('dev.tamtoot/sftp_files');
const _limit = 32 * 1024 * 1024;
Future<SftpLocalFile?> pickSftpFile() async {
  if (Platform.isAndroid || Platform.isIOS) {
    final result = await _channel.invokeMapMethod<String, dynamic>('pick');
    if (result == null) return null;
    final bytes = result['bytes'] as Uint8List;
    if (bytes.length > _limit) {
      throw const FormatException('Local file exceeds 32 MiB.');
    }
    return SftpLocalFile(result['name'] as String, bytes);
  }
  final selected = await openFile();
  if (selected == null) return null;
  if (await selected.length() > _limit) {
    throw const FormatException('Local file exceeds 32 MiB.');
  }
  final output = BytesBuilder(copy: false);
  await for (final bytes in selected.openRead()) {
    if (output.length + bytes.length > _limit) {
      throw const FormatException('Local file exceeds 32 MiB.');
    }
    output.add(bytes);
  }
  return SftpLocalFile(selected.name, output.takeBytes());
}

Future<bool> saveSftpFile(String name, Uint8List bytes) async {
  if (bytes.length > _limit) {
    throw const FormatException('Download exceeds 32 MiB.');
  }
  name = name.replaceAll(RegExp(r'[/\\\x00-\x1f]'), '_');
  if (name.isEmpty) name = 'download';
  if (Platform.isAndroid || Platform.isIOS) {
    return await _channel.invokeMethod<bool>('save', {
          'name': name,
          'bytes': bytes,
        }) ??
        false;
  }
  final selected = await getSaveLocation(suggestedName: name);
  if (selected == null) return false;
  final destination = File(selected.path);
  final temporary = await destination.parent.createTemp('.tamtoot-download-');
  try {
    final file = File('${temporary.path}/data');
    await file.writeAsBytes(bytes, flush: true);
    await file.rename(destination.path);
    return true;
  } finally {
    await temporary.delete(recursive: true);
  }
}
