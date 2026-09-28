import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/agents/command_runner_io.dart';

void main() {
  test(
    'command runner avoids shell interpolation and blocks destructive tools',
    () async {
      if (Platform.isWindows) return;
      final root = await Directory.systemTemp.createTemp('tamtoot-command-');
      addTearDown(() => root.delete(recursive: true));
      final runner = AgentCommandRunner(root.uri);
      final result = await runner.run('printf', [
        '%s',
        r'$(touch should-not-exist)',
      ]);
      expect(result.exitCode, 0);
      expect(result.output, r'$(touch should-not-exist)');
      expect(File('${root.path}/should-not-exist').existsSync(), isFalse);
      await expectLater(
        runner.run('rm', ['-rf', root.path]),
        throwsFormatException,
      );
      await expectLater(
        runner.run('git', ['reset', '--hard']),
        throwsFormatException,
      );
    },
  );
}
