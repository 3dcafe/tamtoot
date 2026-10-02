import 'dart:io';
import 'flutter_process_types.dart';

Future<FlutterToolProcess> startFlutterProcess(
  String sdkPath,
  List<String> arguments,
  String? workingDirectory,
) async {
  final sdk = Directory(sdkPath.trim());
  if (sdkPath.trim().isEmpty || !sdk.isAbsolute || !await sdk.exists()) {
    throw ArgumentError('Choose the absolute path to your Flutter SDK folder');
  }
  final flutter = File.fromUri(
    sdk.uri.resolve('bin/flutter${Platform.isWindows ? '.bat' : ''}'),
  );
  if (!await flutter.exists()) {
    throw ArgumentError(
      'Flutter SDK must contain bin/flutter${Platform.isWindows ? '.bat' : ''}',
    );
  }
  // Use the cached Dart launcher on Windows so no user path passes through cmd.exe.
  final executable = Platform.isWindows
      ? File.fromUri(sdk.uri.resolve('bin/cache/dart-sdk/bin/dart.exe')).path
      : flutter.path;
  final args = Platform.isWindows
      ? [
          File.fromUri(
            sdk.uri.resolve('bin/cache/flutter_tools.snapshot'),
          ).path,
          ...arguments,
        ]
      : arguments;
  if (Platform.isWindows &&
      (!await File(executable).exists() || !await File(args.first).exists())) {
    throw StateError(
      'Initialize this SDK by running flutter --version once in a terminal',
    );
  }
  try {
    return _ToolProcess(
      await Process.start(
        executable,
        args,
        workingDirectory: workingDirectory,
        environment: {'FLUTTER_ROOT': sdk.path},
        runInShell: false,
      ),
    );
  } on ProcessException catch (e) {
    if (Platform.isMacOS && e.errorCode == 1) {
      throw StateError(
        'macOS denied launching Flutter SDK. '
        'The current Tamtoot App Sandbox can block external SDK tools. '
        'Use a desktop developer build with suitable process permissions. '
        'SDK path: ${sdk.path}',
      );
    }
    rethrow;
  }
}

Future<String> flutterProjectPath(Uri root, String entryPoint) async {
  if (root.scheme != 'file') {
    throw ArgumentError('Open a local Flutter project folder');
  }
  if (entryPoint.isEmpty ||
      entryPoint.startsWith('/') ||
      entryPoint.contains('\\') ||
      entryPoint.split('/').any((part) => part == '..' || part.contains(':'))) {
    throw ArgumentError(
      'Entry point must be relative to the project, e.g. lib/main.dart',
    );
  }
  final directory = Directory.fromUri(root);
  if (!await File.fromUri(directory.uri.resolve('pubspec.yaml')).exists()) {
    throw StateError('Open the Flutter project root containing pubspec.yaml');
  }
  final file = File.fromUri(directory.uri.resolveUri(Uri(path: entryPoint)));
  if (!await file.exists()) {
    throw StateError('Entry point does not exist: $entryPoint');
  }
  final resolvedRoot = await directory.resolveSymbolicLinks();
  final resolvedFile = await file.resolveSymbolicLinks();
  if (!resolvedFile.startsWith('$resolvedRoot${Platform.pathSeparator}')) {
    throw ArgumentError('Entry point must be inside the project');
  }
  return file.path;
}

class _ToolProcess implements FlutterToolProcess {
  _ToolProcess(this.process);
  final Process process;
  @override
  Stream<List<int>> get stdout => process.stdout;
  @override
  Stream<List<int>> get stderr => process.stderr;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  void write(List<int> bytes) => process.stdin.add(bytes);
  @override
  void kill() {
    process.kill();
  }
}
