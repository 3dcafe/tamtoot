import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../platform/flutter_process_io.dart';
import '../../platform/dotnet_process_io.dart';
import '../../platform/flutter_process_types.dart';
import '../../platform/process_tree_io.dart';
import 'test_command.dart';

class AgentCommandResult {
  const AgentCommandResult(this.exitCode, this.output);
  final int exitCode;
  final String output;
}

class AgentCommandRunner {
  AgentCommandRunner(
    this.root, {
    this.flutterSdkPath = '',
    this.dotnetPath = '',
  });
  final String flutterSdkPath, dotnetPath;
  FlutterToolProcess? _toolProcess;
  bool get available =>
      root.scheme == 'file' && !Platform.isAndroid && !Platform.isIOS;

  Future<AgentCommandResult> runTests(
    String executable,
    List<String> arguments,
  ) async {
    validateAgentTestCommand(executable, arguments);
    if (!available) {
      return const AgentCommandResult(
        127,
        'Test execution is unavailable on this platform or workspace.',
      );
    }
    try {
      if (executable == 'flutter' && flutterSdkPath.trim().isNotEmpty) {
        final process = await startFlutterProcess(
          flutterSdkPath,
          arguments,
          Directory.fromUri(root).path,
        );
        _toolProcess = process;
        try {
          return await _collect(
            process.stdout,
            process.stderr,
            process.exitCode,
          );
        } finally {
          _toolProcess = null;
        }
      }
      if (executable == 'dart' && flutterSdkPath.trim().isNotEmpty) {
        final sdk = Directory(flutterSdkPath.trim());
        if (!sdk.isAbsolute) throw ArgumentError('SDK must be absolute');
        final dart = File.fromUri(
          sdk.uri.resolve(
            'bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}',
          ),
        );
        if (!await dart.exists()) {
          throw ArgumentError('Initialize the configured Flutter SDK first');
        }
        final process = await Process.start(
          dart.path,
          arguments,
          workingDirectory: Directory.fromUri(root).path,
          runInShell: false,
        );
        _process = process;
        try {
          return await _collect(
            process.stdout,
            process.stderr,
            process.exitCode,
          );
        } finally {
          _process = null;
        }
      }
      if (executable == 'dotnet') {
        final process = await startDotnetProcess(
          await resolveDotnet(dotnetPath),
          arguments,
          Directory.fromUri(root).path,
        );
        _toolProcess = process;
        try {
          return await _collect(
            process.stdout,
            process.stderr,
            process.exitCode,
          );
        } finally {
          _toolProcess = null;
        }
      }
      // Batch wrappers can invoke cmd.exe even when runInShell is false.
      // Flutter has a native SDK launcher above; never fall back to a batch shell.
      if (Platform.isWindows &&
          {'flutter', 'npm', 'pnpm', 'yarn', 'mvn'}.contains(executable)) {
        return AgentCommandResult(
          127,
          'No native launcher is configured for $executable. Configure a native SDK or run this tool manually. No tests ran.',
        );
      }
      return await run(
        Platform.isWindows ? '$executable.exe' : executable,
        arguments,
      );
    } on ProcessException {
      return AgentCommandResult(
        127,
        'Test runner $executable could not be started. Install/configure its SDK or check app process permissions. No tests ran.',
      );
    } on ArgumentError {
      return AgentCommandResult(
        127,
        'Configured $executable SDK is unavailable. Check SDK settings. No tests ran.',
      );
    } on StateError {
      return AgentCommandResult(
        127,
        'Test runner $executable is unavailable. Check SDK settings and app process permissions. No tests ran.',
      );
    }
  }

  final Uri root;
  Process? _process;

  static const blocked = {
    'rm',
    'rmdir',
    'sudo',
    'su',
    'shutdown',
    'reboot',
    'mkfs',
    'diskutil',
    'dd',
  };

  Future<AgentCommandResult> run(
    String executable,
    List<String> arguments,
  ) async {
    if (executable.isEmpty ||
        executable.contains('/') ||
        executable.contains('\\') ||
        blocked.contains(executable.toLowerCase())) {
      throw const FormatException('Unsafe or invalid command executable.');
    }
    if (arguments.any((arg) => arg.contains('\u0000'))) {
      throw const FormatException('Invalid command argument.');
    }
    if (executable == 'git' &&
        (arguments.contains('--hard') ||
            arguments.contains('clean') ||
            arguments.contains('worktree'))) {
      throw const FormatException('Destructive Git command is blocked.');
    }
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: Directory.fromUri(root).path,
      runInShell: false,
    );
    _process = process;
    try {
      return await _collect(process.stdout, process.stderr, process.exitCode);
    } finally {
      _process = null;
    }
  }

  Future<AgentCommandResult> _collect(
    Stream<List<int>> stdout,
    Stream<List<int>> stderr,
    Future<int> exitCode,
  ) async {
    final output = StringBuffer();
    var size = 0;
    Future<void> collect(Stream<List<int>> stream) async {
      await for (final chunk in stream) {
        if (size >= 1024 * 1024) continue;
        final remaining = 1024 * 1024 - size;
        final bytes = chunk.length > remaining
            ? chunk.sublist(0, remaining)
            : chunk;
        output.write(utf8.decode(bytes, allowMalformed: true));
        size += bytes.length;
      }
    }

    final collectors = [collect(stdout), collect(stderr)];
    for (final task in collectors) {
      unawaited(task.then((_) {}, onError: (Object _, StackTrace _) {}));
    }
    final exit = await exitCode.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        stop();
        throw TimeoutException('Command timed out after 120 seconds.');
      },
    );
    await Future.wait(collectors);
    return AgentCommandResult(exit, output.toString());
  }

  void stop() {
    _toolProcess?.kill();
    _toolProcess = null;
    final process = _process;
    if (process != null) unawaited(terminateProcessTree(process));
    _process = null;
  }
}
