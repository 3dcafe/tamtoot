import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/agents/hook_runner_io.dart';

void main() {
  test('project hook receives JSON, can cancel and inject context', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('tamtoot-hooks-');
    addTearDown(() => root.delete(recursive: true));
    final folder = await Directory(
      '${root.path}/.tamtoot/hooks',
    ).create(recursive: true);
    final hook = File('${folder.path}/PreToolUse');
    await hook.writeAsString(
      '#!/bin/sh\n'
      'input=\$(cat)\n'
      'case "\$input" in *write_file*) '
      'echo \'{"cancel":true,"errorMessage":"blocked","contextModification":"use tests"}\';; '
      '*) echo \'{"cancel":false}\';; esac\n',
    );
    await Process.run('chmod', ['+x', hook.path]);
    final result = await AgentHookRunner(
      root.uri,
    ).run('PreToolUse', {'toolName': 'write_file'});
    expect(result.cancel, isTrue);
    expect(result.errorMessage, 'blocked');
    expect(result.context, 'use tests');
  });
}
