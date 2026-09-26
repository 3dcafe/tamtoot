import 'web_directory_web.dart' as web_fs;

Future<String?> defaultCloneParentPath() async =>
    web_fs.webDirectoryPickerSupported ? 'fsa://local' : null;

String joinClonePath(String parent, String name) {
  if (parent.startsWith('fsa:')) return name;
  return '$parent/$name';
}

Future<bool> cloneTargetBusy(String path) async => false;

Future<void> ensureCloneDirectory(String path) async {}

Uri cloneDirectoryUri(String path) {
  if (path.startsWith('fsa:')) return Uri.parse(path);
  return Uri(scheme: 'fsa', host: 'local', path: '/$path');
}

bool get webDirectoryPickerSupported => web_fs.webDirectoryPickerSupported;

Future<Uri?> pickCloneDestination({String? folderName}) =>
    web_fs.pickWebWorkspaceDirectory(createChild: folderName);
