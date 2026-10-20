class AgentCommandResult {
  const AgentCommandResult(this.exitCode, this.output);
  final int exitCode;
  final String output;
}

class AgentCommandRunner {
  AgentCommandRunner(
    Uri root, {
    String flutterSdkPath = '',
    String dotnetPath = '',
  });
  bool get available => false;
  Future<AgentCommandResult> runTests(
    String executable,
    List<String> arguments,
  ) => throw UnsupportedError('Tests are unavailable on this platform.');
  Future<AgentCommandResult> run(String executable, List<String> arguments) =>
      throw UnsupportedError('Commands are unavailable on this platform.');
  void stop() {}
}
