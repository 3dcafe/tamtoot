class McpStdioTransport {
  McpStdioTransport(String command, List<String> arguments, int timeoutSeconds);
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    bool notification = false,
  }) => throw UnsupportedError('STDIO MCP is unavailable on this platform.');
  void close() {}
}
