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
  AgentHookRunner(Uri root);
  Future<HookResult> run(String type, Map<String, dynamic> input) async =>
      const HookResult();
  void stop() {}
}
