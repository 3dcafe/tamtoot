import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<String?> defaultCloneParentPath() async {
  final docs = await getApplicationDocumentsDirectory();
  return '${docs.path}${Platform.pathSeparator}TamtootRepos';
}

String joinClonePath(String parent, String name) =>
    '$parent${Platform.pathSeparator}$name';

Future<bool> cloneTargetBusy(String path) async {
  final dir = Directory(path);
  if (!await dir.exists()) return false;
  return !(await dir.list().isEmpty);
}

Future<void> ensureCloneDirectory(String path) async {
  await Directory(path).create(recursive: true);
}

Uri cloneDirectoryUri(String path) => Uri.directory(path);

bool get webDirectoryPickerSupported => false;

Future<Uri?> pickCloneDestination({String? folderName}) async => null;
