import '../filesystem/filesystem.dart';

enum ProjectKind { flutter, dotnet }

class LaunchTarget {
  const LaunchTarget(
    this.kind,
    this.root,
    this.file,
    this.label, {
    this.runnable = true,
  });
  final ProjectKind kind;
  final Uri root;
  final String file;
  final String label;
  final bool runnable;
  String get id => '${kind.name}:${root.resolve(file)}';
}

/// File hints only; detection never executes project code or SDK commands.
Future<List<LaunchTarget>> detectProjects(
  FileSystemProvider files,
  Uri root,
) async {
  final result = <LaunchTarget>[];
  var directories = 0;
  const ignored = {
    '.git',
    '.dart_tool',
    'build',
    'bin',
    'obj',
    'node_modules',
    'Pods',
    '.symlinks',
  };
  Future<void> visit(Uri folder, int depth) async {
    if (++directories > 150 || depth > 4) return;
    List<FileEntry> entries;
    try {
      entries = await files.list(folder);
    } catch (_) {
      return;
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    for (final entry in entries) {
      if (entry.directory) continue;
      if (entry.name != 'pubspec.yaml' &&
          !entry.name.toLowerCase().endsWith('.csproj'))
        continue;
      try {
        final text = await files.read(entry.uri);
        final relative = entry.uri.path.substring(root.path.length);
        if (entry.name == 'pubspec.yaml') {
          if (RegExp(
            r'^[ \t]+flutter:[ \t]*(?:#[^\n]*)?\r?\n[ \t]+sdk:[ \t]*flutter[ \t]*(?:#[^\n]*)?\r?$',
            multiLine: true,
          ).hasMatch(text)) {
            result.add(
              LaunchTarget(
                ProjectKind.flutter,
                folder,
                'pubspec.yaml',
                'Flutter · $relative',
              ),
            );
          }
        } else {
          final manifest = text.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
          final runnable =
              RegExp(
                r'<OutputType>\s*(Exe|WinExe)\s*</OutputType>',
                caseSensitive: false,
              ).hasMatch(manifest) ||
              RegExp(
                r'Microsoft\.NET\.Sdk\.Web',
                caseSensitive: false,
              ).hasMatch(manifest);
          result.add(
            LaunchTarget(
              ProjectKind.dotnet,
              folder,
              entry.name,
              'C# / .NET · $relative${runnable ? '' : ' (library / run type unknown)'}',
              runnable: runnable,
            ),
          );
        }
      } catch (_) {
        /* An unreadable manifest does not prevent other detection. */
      }
    }
    for (final entry in entries.where(
      (e) =>
          e.directory && !ignored.contains(e.name) && !e.name.startsWith('.'),
    )) {
      await visit(entry.uri, depth + 1);
    }
  }

  await visit(root, 0);
  return result;
}
