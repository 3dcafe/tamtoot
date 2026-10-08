import 'dart:typed_data';

class SftpLocalFile {
  const SftpLocalFile(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

Future<SftpLocalFile?> pickSftpFile() async =>
    throw UnsupportedError('Native file transfer unavailable.');
Future<bool> saveSftpFile(String name, Uint8List bytes) async =>
    throw UnsupportedError('Native file transfer unavailable.');
