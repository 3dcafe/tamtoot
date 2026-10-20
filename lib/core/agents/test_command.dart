/// Only test/build entry points are exposed to the desktop agent. Arguments are
/// passed as a list, never interpreted as a shell command by Tamtoot.
void validateAgentTestCommand(String executable, List<String> arguments) {
  if (executable.contains('/') ||
      executable.contains('\\') ||
      executable.contains('\u0000') ||
      arguments.any((a) => a.contains('\u0000'))) {
    throw const FormatException('Use a test runner name and an argument list.');
  }
  for (final argument in arguments) {
    final value = argument.contains('=')
        ? argument.substring(argument.indexOf('=') + 1)
        : argument;
    if (value.startsWith('/') ||
        value.startsWith('\\') ||
        value.startsWith('~') ||
        RegExp(r'^[A-Za-z]:').hasMatch(value) ||
        value.startsWith('file:') ||
        value.split(RegExp(r'[/\\]')).contains('..')) {
      throw const FormatException(
        'Test arguments must use paths inside the project.',
      );
    }
  }
  final first = arguments.firstOrNull;
  final allowed = switch (executable) {
    'flutter' || 'dart' => first == 'test' || first == 'analyze',
    'dotnet' => first == 'test' || first == 'build',
    'cargo' || 'go' || 'mvn' => first == 'test',
    'npm' || 'pnpm' || 'yarn' =>
      first == 'test' ||
          (arguments.length > 1 &&
              first == 'run' &&
              // 'build' runs the frontend compiler; its TypeScript/Angular
              // diagnostics verify whether a compilation fix worked.
              {'test', 'build'}.contains(arguments[1])),
    'python' || 'python3' =>
      arguments.length >= 2 &&
          first == '-m' &&
          {'pytest', 'unittest'}.contains(arguments[1]),
    'pytest' || 'ctest' => true,
    _ => false,
  };
  if (!allowed) {
    throw const FormatException(
      'Only supported test/build commands are allowed; shell commands are unavailable.',
    );
  }
}
