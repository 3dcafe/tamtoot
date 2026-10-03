import 'dart:async';
import 'dart:io';
import 'flutter_process_types.dart';

Future<String> resolveDotnet(String configured) async {
  final name = Platform.isWindows ? 'dotnet.exe' : 'dotnet';
  Future<String?> candidate(String path) async {
    if (path.trim().isEmpty) return null;
    final file = File(path);
    if (file.isAbsolute && await file.exists()) return file.path;
    final nested = File.fromUri(Directory(path).uri.resolve(name));
    if (nested.isAbsolute && await nested.exists()) return nested.path;
    return null;
  }

  if (configured.trim().isNotEmpty) {
    final found = await candidate(configured.trim());
    if (found != null) return found;
    throw ArgumentError(
      'Choose an absolute dotnet executable or SDK installation folder',
    );
  }
  final env = Platform.environment;
  final paths = <String>[
    env['DOTNET_HOST_PATH'] ?? '',
    env['DOTNET_ROOT'] ?? '',
    env['DOTNET_ROOT_X64'] ?? '',
    env['DOTNET_ROOT_ARM64'] ?? '',
    ...((env['PATH'] ?? '').split(Platform.isWindows ? ';' : ':')),
    if (Platform.isWindows) ...[
      '${env['ProgramFiles'] ?? r'C:\Program Files'}\\dotnet',
      '${env['LOCALAPPDATA'] ?? ''}\\Microsoft\\dotnet',
    ] else ...[
      '${env['HOME'] ?? ''}/.dotnet',
      '/usr/local/share/dotnet',
      '/usr/share/dotnet',
      '/usr/lib/dotnet',
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
    ],
  ];
  for (final path in paths) {
    final found = await candidate(path);
    if (found != null) return found;
  }
  throw StateError(
    '.NET SDK not found. Set its path in Settings or install it and restart Tamtoot to refresh the environment.',
  );
}

Future<FlutterToolProcess> startDotnetProcess(
  String executable,
  List<String> args,
  String? directory,
) async => _DotnetProcess(
  await Process.start(
    executable,
    args,
    workingDirectory: directory,
    runInShell: false,
  ),
);

class _DotnetProcess implements FlutterToolProcess {
  _DotnetProcess(this.process);
  final Process process;
  @override
  Stream<List<int>> get stdout => process.stdout;
  @override
  Stream<List<int>> get stderr => process.stderr;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  void write(List<int> bytes) => process.stdin.add(bytes);
  Future<void> _killWindowsTree() async {
    try {
      final result = await Process.run(
        '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\taskkill.exe',
        ['/PID', '${process.pid}', '/T', '/F'],
        runInShell: false,
      );
      if (result.exitCode != 0) process.kill();
    } catch (_) {
      process.kill();
    }
  }

  @override
  void kill() {
    if (Platform.isWindows) {
      // Kill the owned CLI process and its application children.
      unawaited(_killWindowsTree());
    } else {
      // The CLI handles SIGINT and shuts down its running application.
      process.kill(ProcessSignal.sigint);
    }
  }
}
