/// Local generation controls. Schema mode is opt-in for compatible servers.
class AgentGeneration {
  static const actionNames = [
    'list_files',
    'search_files',
    'read_file',
    'read_files',
    'write_file',
    'replace_in_file',
    'mcp_call',
    'say',
    'finish',
  ];
  static const _fields = {
    'path': {'type': 'string'},
    'paths': {
      'type': 'array',
      'items': {'type': 'string'},
      'minItems': 1,
    },
    'query': {'type': 'string'},
    'content': {'type': 'string'},
    'oldText': {'type': 'string'},
    'newText': {'type': 'string'},
    'text': {'type': 'string'},
    'summary': {'type': 'string'},
    'server': {'type': 'string'},
    'tool': {'type': 'string'},
    'arguments': {'type': 'object'},
    'startLine': {'type': 'integer', 'minimum': 1},
    'lineCount': {'type': 'integer', 'minimum': 1},
  };
  static const _required = {
    'list_files': <String>[],
    'search_files': ['query'],
    'read_file': ['path'],
    'read_files': ['paths'],
    'write_file': ['path', 'content'],
    'replace_in_file': ['path', 'oldText', 'newText'],
    'mcp_call': ['server', 'tool', 'arguments'],
    'say': ['text'],
    'finish': ['summary'],
  };
  static const _optional = {
    'list_files': ['path'],
    'search_files': ['path'],
    'read_file': ['startLine', 'lineCount'],
    'read_files': ['startLine', 'lineCount'],
  };

  /// Each alternative requires the fields needed to execute that action.
  static final Map<String, dynamic> schema = {
    'type': 'object',
    'oneOf': [
      for (final name in actionNames)
        {
          'type': 'object',
          'properties': {
            'action': {'type': 'string', 'const': name},
            for (final field in [..._required[name]!, ...?_optional[name]])
              field: _fields[field],
          },
          'required': ['action', ..._required[name]!],
          'additionalProperties': false,
        },
    ],
  };

  static void validate(Map<String, dynamic> action) {
    final name = action['action'];
    // Existing run_command is handled as an explicit unavailable tool by host.
    if (!actionNames.contains(name) && name != 'run_command') {
      throw const FormatException('Unknown agent action.');
    }
    final fields = switch (name) {
      'write_file' => ['path', 'content'],
      'replace_in_file' => ['path', 'oldText', 'newText'],
      'read_file' => ['path'],
      'search_files' => ['query'],
      'mcp_call' => ['server', 'tool'],
      'say' => ['text'],
      'finish' => ['summary'],
      _ => <String>[],
    };
    for (final field in fields) {
      if (action[field] is! String) {
        throw FormatException('$name requires a string $field.');
      }
    }
    if (name == 'read_files' &&
        (action['paths'] is! List ||
            (action['paths'] as List).isEmpty ||
            (action['paths'] as List).any((v) => v is! String))) {
      throw const FormatException('read_files requires nonempty string paths.');
    }
    if (name == 'mcp_call' && action['arguments'] is! Map<String, dynamic>) {
      throw const FormatException('mcp_call requires an arguments object.');
    }
    for (final field in ['startLine', 'lineCount']) {
      if (action.containsKey(field) &&
          (action[field] is! int || (action[field] as int) < 1)) {
        throw FormatException('$field must be a positive integer.');
      }
    }
  }
}
