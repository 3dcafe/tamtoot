import 'dart:async';
import 'dart:convert';
import 'dart:io';

class AgentCommandResult {
  const AgentCommandResult(this.exitCode, this.output);
  final int exitCode;
  final String output;
}

class AgentCommandRunner {
  AgentCommandRunner(this.root);
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

    final collectors = [collect(process.stdout), collect(process.stderr)];
    final exit = await process.exitCode.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        process.kill();
        throw TimeoutException('Command timed out after 120 seconds.');
      },
    );
    await Future.wait(collectors);
    _process = null;
    return AgentCommandResult(exit, output.toString());
  }

  void stop() {
    _process?.kill();
    _process = null;
  }
}
