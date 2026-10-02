import 'dart:io';
import 'dart:convert';

import 'project_storage.dart';

import 'package:path_provider/path_provider.dart';

import '../core/workspace/tamtoot_meta.dart';

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
    return uri.path;
  }
}

Future<String?> defaultCloneParentPath() async {
  final docs = await getApplicationDocumentsDirectory();
  return '${docs.path}${Platform.pathSeparator}TamtootRepos';
}

String joinClonePath(String parent, String name) =>
    parent.endsWith('/') || parent.endsWith(r'\')
    ? '$parent$name'
    : '$parent${Platform.pathSeparator}$name';

Future<bool> cloneTargetBusy(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return false;
  if (type != FileSystemEntityType.directory) return true;
  final dir = Directory(path);
  return !(await dir.list().isEmpty);
}

Future<bool> looksLikeManagedWorkspace(String path) async {
  final git = Directory('$path${Platform.pathSeparator}.git');
  final meta = File(
    '$path${Platform.pathSeparator}${TamtootProjectMeta.relativePath}',
  );
  return await git.exists() ||
      await meta.exists() ||
      await File(joinClonePath(path, '.tamtoot/project.json')).exists();
}

/// Prefer [preferred]; if taken, return `preferred-2`, `preferred-3`, …
Future<String> uniqueCloneFolderName(String parent, String preferred) async {
  final sanitized = preferred.trim().isEmpty ? 'repo' : preferred.trim();
  var name = sanitized;
  var n = 2;
  while (await cloneTargetBusy(joinClonePath(parent, name))) {
    name = '$sanitized-$n';
    n++;
  }
  return name;
}

Future<void> ensureCloneDirectory(String path) async {
  await Directory(path).create(recursive: true);
}

Uri cloneDirectoryUri(String path) => Uri.directory(path);

/// Projects already cloned into the app documents folder.
Future<List<ClonedProjectRef>> listClonedProjects() async {
  final parent = await defaultCloneParentPath();
  if (parent == null) return const [];
  final dir = Directory(parent);
  if (!await dir.exists()) return const [];

  final out = <ClonedProjectRef>[];
  await for (final entity in dir.list()) {
    if (entity is! Directory) continue;
    final path = entity.path;
    if (!await looksLikeManagedWorkspace(path)) continue;
    final name = path.split(Platform.pathSeparator).last;
    String? remote;
    String? branch;
    try {
      final metaFile = File(
        '$path${Platform.pathSeparator}${TamtootProjectMeta.relativePath}',
      );
      if (await metaFile.exists()) {
        final meta = TamtootProjectMeta.parse(await metaFile.readAsString());
        remote = meta.remoteUrl;
        branch = meta.branch;
      }
    } catch (_) {}
    out.add(
      ClonedProjectRef(
        name: name,
        uri: Uri.directory(path),
        remoteUrl: remote,
        branch: branch,
      ),
    );
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

bool get webDirectoryPickerSupported => false;

Future<Uri?> pickCloneDestination({String? folderName}) async => null;

/// Creates a fresh project without reusing or overwriting an existing directory.
Future<Uri> createProjectDirectory(String parent, String name) async {
  final error = projectNameError(name);
  if (error != null) throw ArgumentError(error);
  final path = joinClonePath(parent, name);
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw StateError('“$name” already exists. Choose another project name.');
  }
  await Directory(path).create(recursive: true);
  final metadata = File.fromUri(
    Uri.directory(path).resolve('.tamtoot/project.json'),
  );
  await metadata.parent.create(recursive: true);
  await metadata.writeAsString(
    jsonEncode({
      'schemaVersion': 1,
      'name': name,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    }),
    flush: true,
  );
  return Uri.directory(path);
}
