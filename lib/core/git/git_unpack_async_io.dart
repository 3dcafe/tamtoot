import 'dart:isolate';
import 'git_pack.dart';

/// Large pack decompression must not block the desktop/mobile UI isolate.
Future<List<UnpackedObject>> unpackGitPackAsync(
  List<int> pack,
  GitInflaterAt inflateAt,
) => Isolate.run(() => unpackPackfile(pack, inflateAt));
