import 'dart:async';
import 'dart:convert';

import '../git/git_service.dart';
import '../git/git_store.dart';
import 'model_client.dart';
import 'model_profile.dart';
import 'hook_runner.dart';
import 'command_runner.dart';
import 'mcp_client.dart';

class AgentRunOptions {
  const AgentRunOptions({
    this.yolo = false,
    this.timeout = const Duration(minutes: 10),
    this.maxConsecutiveMistakes = 3,
    this.maxIterations = 40,
  });

  final bool yolo;
  final Duration timeout;
  final int maxConsecutiveMistakes, maxIterations;
}

class AgentEvent {
  AgentEvent(this.type, this.text, {this.data = const {}, DateTime? at})
    : at = at ?? DateTime.now();
  final String type, text;
  final Map<String, dynamic> data;
  final DateTime at;

  Map<String, dynamic> toJson() => {
    'type': type,
    'text': text,
    'ts': at.millisecondsSinceEpoch,
    if (data.isNotEmpty) 'data': data,
  };
}

class AgentRunResult {
  const AgentRunResult({
    required this.success,
    required this.message,
    required this.iterations,
  });
  final bool success;
  final String message;
  final int iterations;
}

typedef AgentApproval =
    Future<bool> Function(String action, Map<String, dynamic> arguments);
typedef AgentEventSink = void Function(AgentEvent event);

class AgentTaskEngine {
  AgentTaskEngine({
    required this.profile,
    required this.store,
    required this.git,
    required this.root,
    required this.apiKey,
    required this.onEvent,
    required this.approve,
    this.clientFactory,
    AgentHookRunner? hooks,
    AgentCommandRunner? commands,
    this.mcp,
  }) : hooks = hooks ?? AgentHookRunner(root),
       commands = commands ?? AgentCommandRunner(root);

  final ModelProfile profile;
  final GitRepositoryStore store;
  final GitService git;
  final Uri root;
  final String apiKey;
  final AgentEventSink onEvent;
  final AgentApproval approve;
  final ModelClient Function()? clientFactory;
  final AgentHookRunner hooks;
  final AgentCommandRunner commands;
  final McpRegistry? mcp;
  bool _wroteFiles = false, _ranTests = false;
  bool _stopped = false;
  ModelClient? _active;

  void stop() {
    _stopped = true;
    _active?.cancel();
    commands.stop();
    hooks.stop();
  }

  static const protocol = '''
You are an autonomous coding agent.
Reply with exactly ONE JSON object for the next step. Never return two actions.
Do not wrap the object in markdown. Do not add commentary before or after it.
Allowed actions (examples only — emit one of these shapes):
- say: {"action":"say","text":"..."}
- list_files: {"action":"list_files","path":"relative/folder"}
- read_file: {"action":"read_file","path":"relative/file"}
- write_file: {"action":"write_file","path":"relative/file","content":"..."}
- run_command: {"action":"run_command","executable":"flutter","args":["test"]}
- mcp_call: {"action":"mcp_call","server":"name","tool":"tool_name","arguments":{}}
- finish: {"action":"finish","summary":"..."}
Use relative paths only. Never access .git or .tamtoot. Read relevant files before writing.
Commands run directly without a shell. After changing files, run relevant tests before finishing.
Do not finish until the requested work is complete, inspected, and tests pass.
''';

  Future<AgentRunResult> run(String task, AgentRunOptions options) async {
    if (task.trim().isEmpty) {
      throw const ModelApiException('Enter an agent task.');
    }
    if (options.maxConsecutiveMistakes < 1 || options.maxIterations < 1) {
      throw const ModelApiException('Agent limits must be positive.');
    }
    if (options.yolo) {
      final changes = await git.statusEntries(root);
      if (changes.isNotEmpty) {
        throw const ModelApiException(
          'YOLO Mode requires a clean Git working tree. Commit or discard changes first.',
        );
      }
    }
    final startHook = await _hook('TaskStart', {
      'task': task,
      'yolo': options.yolo,
    });
    if (startHook.cancel) {
      throw ModelApiException(
        startHook.errorMessage.isEmpty
            ? 'TaskStart hook cancelled the task.'
            : startHook.errorMessage,
      );
    }
    try {
      return await _runLoop(task, options).timeout(
        options.timeout,
        onTimeout: () {
          stop();
          throw ModelApiException(
            'Agent timed out after ${options.timeout.inSeconds} seconds.',
          );
        },
      );
    } catch (_) {
      if (_stopped) {
        try {
          await hooks.run('TaskCancel', {'task': task});
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<AgentRunResult> _runLoop(String task, AgentRunOptions options) async {
    final promptHook = await _hook('UserPromptSubmit', {'prompt': task});
    if (promptHook.cancel) {
      throw ModelApiException(
        promptHook.errorMessage.isEmpty
            ? 'UserPromptSubmit hook cancelled the task.'
            : promptHook.errorMessage,
      );
    }
    final transcript = <String>[
      'Task: $task',
      if (promptHook.context.isNotEmpty) 'Hook context:\n${promptHook.context}',
    ];
    var mistakes = 0;
    for (var iteration = 1; iteration <= options.maxIterations; iteration++) {
      if (_stopped) {
        throw const ModelApiException('Agent stopped.');
      }
      onEvent(AgentEvent('iteration', 'Iteration $iteration'));
      final client =
          clientFactory?.call() ?? ModelClient(timeout: options.timeout);
      _active = client;
      ModelReply reply;
      try {
        reply = await client.send(profile, {
          'systemPrompt': [
            profile.systemPrompt,
            protocol,
            if (mcp != null && mcp!.tools.isNotEmpty)
              'Available MCP tools:\n${mcp!.describe()}',
          ].join('\n\n'),
          'userPrompt': transcript.join('\n\n'),
        }, apiKey: apiKey);
      } finally {
        _active = null;
      }
      onEvent(
        AgentEvent(
          'model',
          _preview(reply.text),
          data: {
            'endpoint': profile.requestUri().toString(),
            'apiFormat': profile.apiFormat,
            'request': reply.request,
            'response': {
              'text': reply.text,
              if (reply.note.isNotEmpty) 'note': reply.note,
              if (reply.usage.isNotEmpty) 'usage': reply.usage,
            },
          },
        ),
      );
      final action = _decodeAction(reply.text);
      final name = action['action'];
      try {
        if (name != 'say' && name != 'finish') {
          final pre = await _hook('PreToolUse', {
            'toolName': name,
            'parameters': action,
          });
          if (pre.cancel) {
            final reason = pre.errorMessage.isEmpty
                ? 'PreToolUse hook blocked $name.'
                : pre.errorMessage;
            onEvent(AgentEvent('hook', reason));
            transcript.add('Tool blocked by hook: $reason');
            continue;
          }
          if (pre.context.isNotEmpty) {
            transcript.add('Hook context:\n${pre.context}');
          }
        }
        switch (name) {
          case 'say':
            final text = _string(action, 'text');
            onEvent(AgentEvent('say', text));
            transcript.add(
              'Assistant update: $text\nContinue with the next action.',
            );
          case 'list_files':
            final path = _path(action['path'] ?? '', allowEmpty: true);
            final files = await store.listFiles(path);
            final visible = files.where(_allowed).take(500).join('\n');
            onEvent(AgentEvent('tool', 'Listed ${path.isEmpty ? '.' : path}'));
            transcript.add('Tool list_files result:\n$visible');
          case 'read_file':
            final path = _path(action['path']);
            final bytes = await store.readBytes(path);
            if (bytes.length > 1024 * 1024) {
              throw const ModelApiException(
                'File exceeds the 1 MiB agent limit.',
              );
            }
            final content = utf8.decode(bytes);
            onEvent(AgentEvent('tool', 'Read $path'));
            transcript.add('Tool read_file $path result:\n$content');
          case 'write_file':
            final path = _path(action['path']);
            final content = _string(action, 'content');
            if (utf8.encode(content).length > 1024 * 1024) {
              throw const ModelApiException(
                'Write exceeds the 1 MiB agent limit.',
              );
            }
            final allowed = options.yolo || await approve('write_file', action);
            if (!allowed) {
              transcript.add(
                'Tool write_file denied by the user. Choose another action or explain.',
              );
              onEvent(AgentEvent('denied', 'Write denied: $path'));
              continue;
            }
            await store.validateRegularFilePath(path);
            await store.writeText(path, content);
            _wroteFiles = true;
            onEvent(AgentEvent('tool', 'Wrote $path'));
            transcript.add(
              'Tool write_file result: wrote $path successfully. Inspect it before finishing.',
            );
          case 'run_command':
            final executable = _string(action, 'executable');
            final rawArgs = action['args'];
            if (rawArgs is! List || rawArgs.any((item) => item is! String)) {
              throw const ModelApiException(
                'run_command args must be strings.',
              );
            }
            final arguments = rawArgs.cast<String>();
            final allowed =
                options.yolo || await approve('run_command', action);
            if (!allowed) {
              transcript.add('Tool run_command denied by the user.');
              onEvent(AgentEvent('denied', 'Command denied: $executable'));
              continue;
            }
            onEvent(
              AgentEvent('tool', 'Running $executable ${arguments.join(' ')}'),
            );
            final result = await commands.run(executable, arguments);
            final looksLikeTest = arguments.any(
              (arg) => {'test', 'analyze', 'check'}.contains(arg),
            );
            if (looksLikeTest && result.exitCode == 0) _ranTests = true;
            transcript.add(
              'Tool run_command exit ${result.exitCode}:\n${result.output}',
            );
            if (result.exitCode != 0) {
              throw ModelApiException(
                'Command exited with ${result.exitCode}.',
              );
            }
          case 'mcp_call':
            final registry = mcp;
            if (registry == null) {
              throw const ModelApiException('No MCP servers are connected.');
            }
            final server = _string(action, 'server');
            final tool = _string(action, 'tool');
            final rawArguments = action['arguments'];
            if (rawArguments is! Map<String, dynamic>) {
              throw const ModelApiException('MCP arguments must be an object.');
            }
            final allowed = options.yolo || await approve('mcp_call', action);
            if (!allowed) {
              transcript.add('MCP call denied by the user.');
              onEvent(AgentEvent('denied', 'MCP denied: $server/$tool'));
              continue;
            }
            final result = await registry.call(server, tool, rawArguments);
            onEvent(AgentEvent('tool', 'MCP $server/$tool'));
            transcript.add('MCP $server/$tool result:\n${jsonEncode(result)}');
          case 'finish':
            if (_wroteFiles && !_ranTests) {
              transcript.add(
                'Completion blocked: files changed but no successful test/analyze command ran.',
              );
              onEvent(
                AgentEvent(
                  'guard',
                  'Completion blocked until relevant tests pass.',
                ),
              );
              continue;
            }
            final summary = _string(action, 'summary');
            onEvent(AgentEvent('done', summary));
            return AgentRunResult(
              success: true,
              message: summary,
              iterations: iteration,
            );
          default:
            throw ModelApiException('Unknown agent action: $name');
        }
        if (name != 'say' && name != 'finish') {
          final post = await _hook('PostToolUse', {
            'toolName': name,
            'parameters': action,
            'success': true,
          });
          if (post.context.isNotEmpty) {
            transcript.add('Hook context:\n${post.context}');
          }
        }
        mistakes = 0;
      } catch (e) {
        mistakes++;
        final message = e is ModelApiException ? e.message : '$e';
        onEvent(AgentEvent('error', message));
        transcript.add(
          'Tool/action error: $message\nFix the mistake and continue.',
        );
        if (mistakes >= options.maxConsecutiveMistakes) {
          throw ModelApiException(
            'Agent stopped after $mistakes consecutive mistakes: $message',
          );
        }
      }
      _trim(transcript);
    }
    throw ModelApiException(
      'Agent reached the ${options.maxIterations}-iteration limit.',
    );
  }

  Future<HookResult> _hook(String type, Map<String, dynamic> input) async {
    final result = await hooks.run(type, input);
    onEvent(AgentEvent('hook', '$type: ${result.cancel ? 'blocked' : 'ok'}'));
    return result;
  }

  Map<String, dynamic> _decodeAction(String text) {
    final source = _extractJsonObject(text);
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> || decoded['action'] is! String) {
      throw const ModelApiException('Model returned an invalid agent action.');
    }
    return decoded;
  }

  /// Models sometimes emit NDJSON / several actions; keep the first object only.
  String _extractJsonObject(String text) {
    var source = text.trim();
    if (source.startsWith('```')) {
      source = source.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      source = source.replaceFirst(RegExp(r'\s*```$'), '');
      source = source.trim();
    }
    final start = source.indexOf('{');
    if (start < 0) {
      throw const ModelApiException('Model returned an invalid agent action.');
    }
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < source.length; i++) {
      final ch = source[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
        continue;
      }
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return source.substring(start, i + 1);
      }
    }
    throw const ModelApiException('Model returned an invalid agent action.');
  }

  String _string(Map<String, dynamic> action, String key) {
    final value = action[key];
    if (value is! String || value.isEmpty) {
      throw ModelApiException('Agent action is missing $key.');
    }
    return value;
  }

  String _path(dynamic raw, {bool allowEmpty = false}) {
    if (raw is! String) throw const ModelApiException('Invalid agent path.');
    final path = raw.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
    if (allowEmpty && (path.isEmpty || path == '.')) return '';
    final parts = path.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..') ||
        !_allowed(path)) {
      throw const ModelApiException(
        'Agent path is outside the project or protected.',
      );
    }
    return path;
  }

  bool _allowed(String path) =>
      path != '.git' &&
      !path.startsWith('.git/') &&
      path != '.tamtoot' &&
      !path.startsWith('.tamtoot/');

  void _trim(List<String> transcript) {
    var characters = transcript.fold(0, (sum, item) => sum + item.length);
    while (characters > 120000 && transcript.length > 2) {
      characters -= transcript[1].length;
      transcript.removeAt(1);
    }
  }

  String _preview(String text, {int max = 240}) {
    final trimmed = text.trim();
    if (trimmed.length <= max) return trimmed;
    return '${trimmed.substring(0, max)}…';
  }
}
