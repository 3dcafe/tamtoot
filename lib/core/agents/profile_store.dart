import '../git/git_store.dart';
import 'model_profile.dart';

class ProfileStore {
  ProfileStore(this.files);
  final GitRepositoryStore files;
  static const folder = '.tamtoot/agents/models';
  static const instructionsPath = '.tamtoot/agents/instructions.md';
  String path(String id) {
    if (!ModelProfile.idPattern.hasMatch(id)) {
      throw const FormatException('Invalid profile ID');
    }
    return '$folder/$id.json';
  }

  Future<String?> read(String path) async {
    await files.validateRegularFilePath(path);
    return await files.exists(path) ? files.readText(path) : null;
  }

  Future<List<String>> list() async {
    await files.validateRegularFilePath('$folder/index.json');
    if (!await files.exists(folder)) return [];
    return (await files.listFiles(folder))
        .where(
          (p) =>
              p.startsWith('$folder/') &&
              p.endsWith('.json') &&
              !p.substring(folder.length + 1).contains('/'),
        )
        .toList()
      ..sort();
  }

  Future<void> save(String path, String text, String? expected) async {
    if (await read(path) != expected) {
      throw StateError(
        'This file changed outside the dialog. Reopen it before saving.',
      );
    }
    await files.writeText(path, text);
  }

  Future<void> delete(String id, String expected) async {
    final target = path(id);
    if (await read(target) != expected) {
      throw StateError('Profile changed outside the dialog. Reopen it.');
    }
    await files.delete(target);
  }
}
