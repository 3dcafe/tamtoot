import 'dart:async';
import 'dart:convert';
import 'dart:io';

class HookResult {
  const HookResult({
    this.cancel = false,
    this.errorMessage = '',
    this.context = '',
  });
  final bool cancel;
  final String errorMessage, context;
}

class AgentHookRunner {
  AgentHookRunner(this.root);
  final Uri root;
  Process? _process;

  Future<HookResult> run(String type, Map<String, dynamic> input) async {
    if (!RegExp(r'^[A-Za-z]+$').hasMatch(type)) {
      throw const FormatException('Invalid hook type.');
    }
    final hook = File.fromUri(root.resolve('.tamtoot/hooks/$type'));
    if (!await hook.exists()) return const HookResult();
    final process = await Process.start(
      hook.path,
      const [],
      workingDirectory: Directory.fromUri(root).path,
      runInShell: false,
    );
    _process = process;
    process.stdin.write(jsonEncode(input));
    await process.stdin.close();
    final outputFuture = process.stdout.transform(utf8.decoder).join();
    final errorFuture = process.stderr.transform(utf8.decoder).join();
    final exit = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill();
        throw TimeoutException('Hook $type timed out.');
      },
    );
    _process = null;
    var output = await outputFuture;
    var error = await errorFuture;
    if (output.length > 1024 * 1024) {
      throw const FormatException('Hook output exceeds 1 MiB.');
    }
    if (error.length > 4000) error = error.substring(0, 4000);
    if (exit != 0) {
      throw StateError('Hook $type failed ($exit): $error');
    }
    if (output.trim().isEmpty) return const HookResult();
    final data = jsonDecode(output);
    if (data is! Map) {
      throw FormatException('Hook $type returned invalid JSON.');
    }
    return HookResult(
      cancel: data['cancel'] == true,
      errorMessage: data['errorMessage'] is String
          ? data['errorMessage'] as String
          : '',
      context: data['contextModification'] is String
          ? data['contextModification'] as String
          : '',
    );
  }

  void stop() {
    _process?.kill();
    _process = null;
  }
}
