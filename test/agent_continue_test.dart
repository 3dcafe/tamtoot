import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/features/agent_dialog.dart';

void main() {
  test('continuation prompt keeps the original task and stop reason', () {
    final prompt = buildAgentContinuationPrompt(
      originalTask: 'Fix Git history dialog layout',
      stopReason: 'Agent timed out after 600 seconds.\nRequest cancelled.',
    );
    expect(prompt, contains('Continue the unfinished agent task'));
    expect(prompt, contains('Agent timed out after 600 seconds.'));
    expect(prompt, isNot(contains('Request cancelled.')));
    expect(prompt, contains('Original task:'));
    expect(prompt, contains('Fix Git history dialog layout'));
    expect(prompt, contains('Prefer replace_in_file'));
  });
}
