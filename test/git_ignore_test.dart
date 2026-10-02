import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/git/git_ignore.dart';

void main() {
  test('gitignore handles directories, globs, negation and nested rules', () {
    final ignore = GitIgnore()
      ..add('''
.dart_tool/
/build/
*.log
!important.log
**/doc/api/
''')
      ..add('generated/\n!generated/keep.txt\n', base: 'ios');

    expect(ignore.ignores('.dart_tool', directory: true), isTrue);
    expect(
      ignore.ignores('.dart_tool/flutter_build/file', directory: false),
      isTrue,
    );
    expect(ignore.ignores('build/output.bin', directory: false), isTrue);
    expect(
      ignore.ignores('nested/build/output.bin', directory: false),
      isFalse,
    );
    expect(ignore.ignores('debug.log', directory: false), isTrue);
    expect(ignore.ignores('important.log', directory: false), isFalse);
    expect(
      ignore.ignores('packages/doc/api/index.html', directory: false),
      isTrue,
    );
    expect(ignore.ignores('ios/generated', directory: true), isTrue);
    expect(ignore.ignores('android/generated', directory: true), isFalse);
  });
}
