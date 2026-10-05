import 'git_pack.dart';

Future<List<UnpackedObject>> unpackGitPackAsync(
  List<int> pack,
  GitInflaterAt inflateAt,
) async => unpackPackfile(pack, inflateAt);
