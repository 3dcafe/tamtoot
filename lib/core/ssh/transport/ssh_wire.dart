import 'dart:typed_data';

abstract interface class SshWire {
  Future<Uint8List> read(int length);
  Future<void> write(List<int> bytes);
  Future<void> close();
}
