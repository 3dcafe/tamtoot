import 'dart:convert';
import '../filesystem/filesystem.dart';

enum ProjectKind { flutter, dotnet, angular }

class LaunchTarget {
  const LaunchTarget(
    this.kind,
    this.root,
    this.file,
    this.label, {
    this.runnable = true,
    this.previewPort = 4200,
  });
  final ProjectKind kind;
  final Uri root;
  final String file;
  final String label;
  final bool runnable;
  final int previewPort;
  String get id =>
      '${kind.name}:${root.resolve(file)}${kind == ProjectKind.angular ? ':$label' : ''}';
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
          entry.name != 'angular.json' &&
          !entry.name.toLowerCase().endsWith('.csproj')) {
        continue;
      }
      try {
        final text = await files.read(entry.uri);
        final relative = entry.uri.path.startsWith(root.path)
            ? entry.uri.path.substring(root.path.length)
            : entry.name;
        if (entry.name == 'angular.json') {
          final config = jsonDecode(text) as Map<String, dynamic>;
          final projects = config['projects'];
          if (projects is Map) {
            for (final item in projects.entries) {
              final project = item.value;
              if (project is! Map) continue;
              final targets = project['architect'] ?? project['targets'];
              final serve = targets is Map ? targets['serve'] : null;
              if (serve is! Map) continue;
              final options = serve['options'];
              final configurations = serve['configurations'];
              final selected = configurations is Map
                  ? configurations[serve['defaultConfiguration']]
                  : null;
              final port = selected is Map && selected['port'] != null
                  ? selected['port']
                  : options is Map
                  ? options['port']
                  : null;
              result.add(
                LaunchTarget(
                  ProjectKind.angular,
                  folder,
                  'angular.json',
                  'Angular · ${item.key}',
                  runnable: false,
                  previewPort: port is int && port > 0 && port <= 65535
                      ? port
                      : 4200,
                ),
              );
            }
          }
        } else if (entry.name == 'pubspec.yaml') {
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
