import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/agents/agent_context_compactor.dart';

void main() {
  test('compacts old context while keeping task and newest exact file', () {
    final transcript = <String>[
      'Task: fix the editor',
      'Phase: implementation',
      for (var index = 0; index < 12; index++)
        'Hook context:\n${'old detail $index ' * 90}',
      'Tool replace_in_file result: edited lib/editor.dart successfully.',
      'Host note: verify the changed area.',
    ];
    final observations = <String, String>{
      for (var index = 0; index < 6; index++)
        'Search $index': 'Search result:\n${'lib/file_$index.dart:20 match\n' * 90}',
    };
    final activeFiles = <String, String>{
      for (var index = 0; index < 6; index++)
        'lib/file_$index.dart [lines 1-200]': 'source $index\n${'x' * 7900}',
    };
    final summary = <String>[];

    final result = const AgentContextCompactor().compact(
      transcript: transcript,
      observations: observations,
      activeFiles: activeFiles,
      summary: summary,
      pinnedCharacters: 10000,
    );

    expect(result.changed, isTrue);
    expect(result.afterCharacters, lessThan(result.beforeCharacters));
    expect(transcript.first, 'Task: fix the editor');
    expect(transcript, contains('Host note: verify the changed area.'));
    expect(activeFiles.keys.last, contains('lib/file_5.dart'));
    expect(summary.join('\n'), contains('Previously inspected:'));
    expect(
      summary.join().length,
      lessThanOrEqualTo(AgentContextCompactor.maxSummaryCharacters),
    );
  });
}
