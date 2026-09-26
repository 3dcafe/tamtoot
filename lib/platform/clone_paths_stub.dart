import 'web_directory_web.dart' as web_fs;

/// A project under TamtootRepos (or from recent prefs).
class ClonedProjectRef {
  const ClonedProjectRef({
    required this.name,
    required this.uri,
    this.remoteUrl,
    this.branch,
  });

  final String name;
  final Uri uri;
  final String? remoteUrl;
  final String? branch;

  String get subtitle {
    final remote = remoteUrl;
    if (remote != null && remote.isNotEmpty) {
      final branchPart = (branch == null || branch!.isEmpty)
          ? ''
          : ' · $branch';
      return '$remote$branchPart';
    }
    return uri.toString();
  }
}

Future<String?> defaultCloneParentPath() async =>
    web_fs.webDirectoryPickerSupported ? 'fsa://local' : null;

String joinClonePath(String parent, String name) {
  if (parent.startsWith('fsa:')) return name;
  return '$parent/$name';
}

Future<bool> cloneTargetBusy(String path) async => false;

Future<bool> looksLikeManagedWorkspace(String path) async => false;

Future<String> uniqueCloneFolderName(String parent, String preferred) async =>
    preferred.trim().isEmpty ? 'repo' : preferred.trim();

Future<void> ensureCloneDirectory(String path) async {}

Uri cloneDirectoryUri(String path) {
  if (path.startsWith('fsa:')) return Uri.parse(path);
  return Uri(scheme: 'fsa', host: 'local', path: '/$path');
}

Future<List<ClonedProjectRef>> listClonedProjects() async => const [];

bool get webDirectoryPickerSupported => web_fs.webDirectoryPickerSupported;

Future<Uri?> pickCloneDestination({String? folderName}) =>
    web_fs.pickWebWorkspaceDirectory(createChild: folderName);
