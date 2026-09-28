class AgentCommandResult {
  const AgentCommandResult(this.exitCode, this.output);
  final int exitCode;
  final String output;
}

class AgentCommandRunner {
  AgentCommandRunner(Uri root);
  Future<AgentCommandResult> run(String executable, List<String> arguments) =>
      throw UnsupportedError('Commands are unavailable on this platform.');
  void stop() {}
}
