import 'dart:async';
import 'dart:convert';

import '../git/git_service.dart';
import '../git/git_store.dart';
import 'model_attachment.dart';
import 'model_client.dart';
import 'model_profile.dart';
import 'hook_runner.dart';
import 'command_runner.dart';
import 'mcp_client.dart';

class AgentRunOptions {
  const AgentRunOptions({
    this.yolo = true,
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
    this.attachments = const [],
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
  final List<ModelAttachment> attachments;
  final AgentEventSink onEvent;
  final AgentApproval approve;
  final ModelClient Function()? clientFactory;
  final AgentHookRunner hooks;
  final AgentCommandRunner commands;
  final McpRegistry? mcp;
  bool _stopped = false;
  ModelClient? _active;

  void stop() {
    _stopped = true;
    _active?.cancel();
    commands.stop();
    hooks.stop();
  }

  static const protocol = '''
You are an autonomous coding agent in Tamtoot (mobile IDE: no terminal, builds, tests, or shell).
Never run or ask for runtime checks; verify by reading files and say so in the finish summary.
Work quickly and make progress every iteration.
Do not spend an iteration explaining a plan. Start with the most useful tool action.
Reply with exactly ONE JSON object. No markdown fences, no commentary outside JSON.

Investigation rules:
- search_files is literal text search. Search concrete symbols/identifiers ("TextField", "AgentDialog", "_running"), not natural-language descriptions.
- Maximum 2 consecutive search_files calls since the last read/edit.
- When a search returns ≤4 plausible implementation files, READ THEM NEXT.
- Never repeat a search with the same/similar query under the same or overlapping path.
- Read the smallest useful context.
- If search results include line numbers, read ~40 lines around each match.
- Do not read files from line 1 unless the file structure is actually needed.
- Prefer 1-2 highly relevant files; use up to 4 only when necessary.
- If you already have the edit location, edit immediately.
- After editing, read the changed area once and finish.

Actions:
- say: {"action":"say","text":"..."}
- list_files: {"action":"list_files","path":"relative/folder"}
- search_files: {"action":"search_files","query":"literal symbol or text","path":"optional/relative/folder"}
- read_file: {"action":"read_file","path":"relative/file","startLine":optional,"lineCount":optional}
- read_files: {"action":"read_files","paths":["a.dart","b.dart"],"startLine":optional,"lineCount":optional}
- replace_in_file: {"action":"replace_in_file","path":"relative/file","oldText":"exact existing text","newText":"replacement text"}
- write_file: {"action":"write_file","path":"relative/file","content":"..."}
- mcp_call: {"action":"mcp_call","server":"name","tool":"tool_name","arguments":{}}
- finish: {"action":"finish","summary":"..."}
Relative paths only. Never touch .git or .tamtoot.
Reuse retained excerpts — do not re-read unchanged files.
''';

  /// Agent replies are one JSON action; large completion budgets only waste latency.
  static const int agentMaxTokens = 1200;

  /// Default window when the model does not specify a range.
  static const int defaultReadLineCount = 70;

  /// Lines kept around each search hit when auto-focusing a read.
  static const int matchContextRadius = 20;

  static const int maxActiveFiles = 2;
  static const int maxActiveCharacters = 8000;
  static const int maxExcerptCharacters = 3000;

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
      'Phase: implementation. Start with the most useful tool action. Prefer tools over say.',
      if (promptHook.context.isNotEmpty) 'Hook context:\n${promptHook.context}',
    ];
    final activeFiles = <String, String>{};
    final observations = <String, String>{};
    _rememberObservation(
      observations,
      'Project index',
      await _projectIndex(),
    );
    var mistakes = 0;
    var consecutiveSays = 0;
    var consecutiveSearches = 0;
    var requireReadAfterSearch = false;
    final completedSearches = <_CompletedSearch>[];
    final focusLinesByPath = <String, List<int>>{};
    final agentProfile = _withAgentTokenBudget(profile);
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
        final userPrompt = _buildPrompt(transcript, activeFiles, observations);
        reply = await client.send(
          agentProfile,
          {
            'systemPrompt': [
              agentProfile.systemPrompt,
              protocol,
              if (mcp != null && mcp!.tools.isNotEmpty)
                'Available MCP tools:\n${mcp!.describe()}',
            ].join('\n\n'),
            'userPrompt': userPrompt,
          },
          apiKey: apiKey,
          attachments: iteration == 1 ? attachments : const [],
        );
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
            consecutiveSays++;
            if (consecutiveSays >= 2) {
              throw const ModelApiException(
                'Repeated say without tools wastes tokens. '
                'Emit read_files, read_file, search_files, replace_in_file, write_file, or finish now.',
              );
            }
            onEvent(AgentEvent('say', text));
            _replaceNote(
              transcript,
              'Assistant update:',
              'Assistant update: ${_bounded(text, 600)}',
            );
            _replaceNote(
              transcript,
              'Host note:',
              'Host note: Next step must be a tool or finish — not another say.',
            );
          case 'list_files':
            consecutiveSays = 0;
            if (requireReadAfterSearch) {
              _softRejectSearch(
                transcript,
                'list_files',
                'Search returned implementation files. '
                    'Read them with read_file/read_files before listing or searching again.',
              );
              continue;
            }
            final path = _path(action['path'] ?? '', allowEmpty: true);
            final files = await store.listFiles(path);
            final visible = files.where(_useful).take(120).join('\n');
            onEvent(AgentEvent('tool', 'Listed ${path.isEmpty ? '.' : path}'));
            _rememberObservation(
              observations,
              'List ${path.isEmpty ? '.' : path}',
              'Tool list_files result for ${path.isEmpty ? '.' : path}:\n$visible',
            );
            _compactProjectIndex(observations);
          case 'search_files':
            consecutiveSays = 0;
            final query = _string(action, 'query').trim();
            if (query.length < 2) {
              throw const ModelApiException(
                'search_files query must contain at least 2 characters.',
              );
            }
            final path = _path(action['path'] ?? '', allowEmpty: true);
            final duplicate = _findDuplicateSearch(
              completedSearches,
              query,
              path,
            );
            if (duplicate != null) {
              _softRejectSearch(
                transcript,
                'search_files',
                'Search rejected: "$query" was already searched.\n'
                    '${_formatKnownMatches(duplicate)}\n'
                    'Read the relevant area or edit it.',
              );
              continue;
            }
            if (requireReadAfterSearch) {
              _softRejectSearch(
                transcript,
                'search_files',
                'Search rejected: previous search returned ≤4 implementation files.\n'
                    '${_formatKnownMatchesFromAll(completedSearches)}\n'
                    'Read the relevant area or edit it.',
              );
              continue;
            }
            if (consecutiveSearches >= 2) {
              _softRejectSearch(
                transcript,
                'search_files',
                'Search rejected: already ran 2 search_files since the last read/edit.\n'
                    '${_formatKnownMatchesFromAll(completedSearches)}\n'
                    'Read the relevant area or edit it.',
              );
              continue;
            }
            final result = await _searchFiles(query, path);
            final hits = _parseSearchHits(result);
            final completed = _CompletedSearch(
              query: query,
              path: path,
              result: result,
              hits: hits,
            );
            completedSearches.add(completed);
            consecutiveSearches++;
            for (final hit in hits) {
              if (hit.line == null) continue;
              focusLinesByPath
                  .putIfAbsent(hit.path, () => <int>[])
                  .add(hit.line!);
            }
            onEvent(AgentEvent('tool', 'Searched project for “$query”'));
            _rememberObservation(
              observations,
              'Search $path::$query',
              'Tool search_files result for "$query":\n$result',
            );
            _compactProjectIndex(observations);
            final implementationPaths = hits
                .map((hit) => hit.path)
                .where(_looksLikeImplementationPath)
                .toSet()
                .toList();
            if (implementationPaths.isNotEmpty &&
                implementationPaths.length <= 4) {
              requireReadAfterSearch = true;
              _replaceNote(
                transcript,
                'Host note:',
                'Host note: Search returned ${implementationPaths.length} '
                    'implementation file(s) (${implementationPaths.join(', ')}). '
                    'READ ~40 lines around the matched lines next. Do not search again.',
              );
            } else {
              _replaceNote(
                transcript,
                'Host note:',
                'Host note: After search, read ~40 lines around matches in the '
                    'most relevant 1-2 files. Prefer read_files only when needed.',
              );
            }
          case 'read_file':
            consecutiveSays = 0;
            consecutiveSearches = 0;
            requireReadAfterSearch = false;
            final path = _path(action['path']);
            final bytes = await store.readBytes(path);
            if (bytes.length > 1024 * 1024) {
              throw const ModelApiException(
                'File exceeds the 1 MiB agent limit.',
              );
            }
            final content = utf8.decode(bytes);
            final excerpt = _fileExcerpt(
              path,
              content,
              action,
              focusLines: focusLinesByPath[path],
            );
            _rememberFile(
              activeFiles,
              excerpt.key,
              excerpt.content,
              transcript,
            );
            onEvent(AgentEvent('tool', 'Read $path'));
            _replaceNote(
              transcript,
              'Tool read_file result:',
              'Tool read_file result: ${excerpt.description}. The content is in Active file context.',
            );
            _compactProjectIndex(observations);
            if (activeFiles.isNotEmpty) {
              _replaceNote(
                transcript,
                'Host note:',
                'Host note: File context is available. Prefer replace_in_file or finish over another say.',
              );
            }
          case 'read_files':
            consecutiveSays = 0;
            consecutiveSearches = 0;
            requireReadAfterSearch = false;
            final rawPaths = action['paths'];
            if (rawPaths is! List || rawPaths.isEmpty) {
              throw const ModelApiException(
                'read_files requires a non-empty paths array.',
              );
            }
            if (rawPaths.length > 4) {
              throw const ModelApiException(
                'read_files accepts at most 4 paths per call.',
              );
            }
            final descriptions = <String>[];
            for (final raw in rawPaths) {
              final path = _path(raw);
              final bytes = await store.readBytes(path);
              if (bytes.length > 1024 * 1024) {
                throw ModelApiException(
                  'File exceeds the 1 MiB agent limit: $path',
                );
              }
              final content = utf8.decode(bytes);
              final excerpt = _fileExcerpt(
                path,
                content,
                action,
                focusLines: focusLinesByPath[path],
              );
              _rememberFile(
                activeFiles,
                excerpt.key,
                excerpt.content,
                transcript,
              );
              descriptions.add(excerpt.description);
            }
            onEvent(
              AgentEvent(
                'tool',
                'Read ${rawPaths.length} files: ${descriptions.join('; ')}',
              ),
            );
            _replaceNote(
              transcript,
              'Tool read_files result:',
              'Tool read_files result: ${descriptions.join('; ')}. Contents are in Active file context.',
            );
            _compactProjectIndex(observations);
            _replaceNote(
              transcript,
              'Host note:',
              'Host note: Relevant excerpts are in context. Prefer replace_in_file or finish over another say.',
            );
          case 'replace_in_file':
            consecutiveSays = 0;
            consecutiveSearches = 0;
            final path = _path(action['path']);
            final oldText = _string(action, 'oldText');
            final newText = action['newText'];
            if (newText is! String) {
              throw const ModelApiException('Agent action is missing newText.');
            }
            final allowed =
                options.yolo || await approve('replace_in_file', action);
            if (!allowed) {
              transcript.add(
                'Tool replace_in_file denied by the user. Choose another action or explain.',
              );
              onEvent(AgentEvent('denied', 'Edit denied: $path'));
              continue;
            }
            final content = await store.readText(path);
            final first = content.indexOf(oldText);
            if (first < 0) {
              throw const ModelApiException(
                'oldText was not found. Read the current file and copy the exact text.',
              );
            }
            if (content.indexOf(oldText, first + oldText.length) >= 0) {
              throw const ModelApiException(
                'oldText is not unique. Include more surrounding text.',
              );
            }
            final updated = content.replaceRange(
              first,
              first + oldText.length,
              newText,
            );
            if (utf8.encode(updated).length > 1024 * 1024) {
              throw const ModelApiException(
                'Edited file exceeds the 1 MiB agent limit.',
              );
            }
            await store.writeText(path, updated);
            activeFiles.removeWhere(
              (key, _) => key == path || key.startsWith('$path ['),
            );
            onEvent(AgentEvent('tool', 'Edited $path'));
            transcript.add(
              'Tool replace_in_file result: edited $path successfully. Read the changed area before finishing.',
            );
          case 'write_file':
            consecutiveSays = 0;
            consecutiveSearches = 0;
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
            activeFiles.removeWhere(
              (key, _) => key == path || key.startsWith('$path ['),
            );
            onEvent(AgentEvent('tool', 'Wrote $path'));
            transcript.add(
              'Tool write_file result: wrote $path successfully. Inspect it before finishing.',
            );
          case 'run_command':
            transcript.add(
              'run_command is unavailable: Tamtoot is a mobile IDE without a terminal, interpreter, debugger, build runner, or test runner. Inspect changed files and finish without executing commands.',
            );
            onEvent(
              AgentEvent(
                'denied',
                'Command skipped: this mobile IDE has no runtime or test runner.',
              ),
            );
          case 'mcp_call':
            consecutiveSays = 0;
            consecutiveSearches = 0;
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
            _rememberObservation(
              observations,
              'MCP $server/$tool',
              'MCP $server/$tool result:\n${_bounded(jsonEncode(result), 12000)}',
            );
          case 'finish':
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

  bool _useful(String path) {
    if (!_allowed(path)) return false;
    final parts = path.split('/');
    const generated = {
      '.dart_tool',
      '.gradle',
      '.idea',
      'build',
      'DerivedData',
      'node_modules',
      'Pods',
    };
    return !parts.any(generated.contains);
  }

  String _buildPrompt(
    List<String> transcript,
    Map<String, String> activeFiles,
    Map<String, String> observations,
  ) {
    final out = StringBuffer(transcript.join('\n\n'));
    if (observations.isNotEmpty) {
      out.write('\n\nRetained investigation context:');
      for (final entry in observations.entries) {
        out
          ..write('\n\n--- ${entry.key} ---\n')
          ..write(entry.value);
      }
    }
    if (activeFiles.isNotEmpty) {
      out.write('\n\nActive file context (bounded working set):');
      for (final entry in activeFiles.entries) {
        out
          ..write('\n\n--- ${entry.key} ---\n')
          ..write(entry.value);
      }
    }
    return out.toString();
  }

  Future<String> _projectIndex() async {
    final paths = (await store.listFiles('')).where(_useful).toList()..sort();
    const maxPaths = 120;
    const maxCharacters = 3500;
    final out = StringBuffer(
      'Project file index (one-time). Prefer literal search_files for symbols, then read_files:\n',
    );
    var included = 0;
    for (final path in paths.take(maxPaths)) {
      if (out.length + path.length + 1 > maxCharacters) break;
      out.writeln(path);
      included++;
    }
    if (included < paths.length) {
      out.write('… ${paths.length - included} more files omitted');
    }
    onEvent(AgentEvent('context', 'Indexed $included project files once'));
    return out.toString();
  }

  void _compactProjectIndex(Map<String, String> observations) {
    final current = observations['Project index'];
    if (current == null || current.startsWith('Project file index already')) {
      return;
    }
    final lines = current
        .split('\n')
        .where((line) => line.trim().isNotEmpty && !line.startsWith('…'))
        .length;
    observations['Project index'] =
        'Project file index already provided once (~$lines paths). '
        'Prefer literal search_files or list_files; do not re-list the tree.';
  }

  ModelProfile _withAgentTokenBudget(ModelProfile source) {
    final params = Map<String, dynamic>.from(source.parameters);
    final existing = params['max_tokens'];
    final capped = existing is num
        ? existing.clamp(1, agentMaxTokens).toInt()
        : agentMaxTokens;
    params['max_tokens'] = capped;
    return ModelProfile(
      id: source.id,
      name: source.name,
      provider: source.provider,
      model: source.model,
      systemPrompt: source.systemPrompt,
      userTemplate: source.userTemplate,
      parameters: params,
      apiFormat: source.apiFormat,
      endpoint: source.endpoint,
    );
  }

  static String _normalizeSearchQuery(String query) => query
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_\.]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _similarSearchQuery(String a, String b) {
    final na = _normalizeSearchQuery(a);
    final nb = _normalizeSearchQuery(b);
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb) return true;
    if (na.contains(nb) || nb.contains(na)) return true;
    final ta = na.split(' ').where((token) => token.length >= 2).toSet();
    final tb = nb.split(' ').where((token) => token.length >= 2).toSet();
    if (ta.isEmpty || tb.isEmpty) return false;
    final intersection = ta.intersection(tb).length;
    final smaller = ta.length < tb.length ? ta.length : tb.length;
    return intersection >= 2 && intersection / smaller >= 0.6;
  }

  static bool _pathsOverlap(String a, String b) {
    if (a.isEmpty || b.isEmpty || a == b) return true;
    return a.startsWith('$b/') || b.startsWith('$a/');
  }

  static _CompletedSearch? _findDuplicateSearch(
    List<_CompletedSearch> searches,
    String query,
    String path,
  ) {
    for (final previous in searches.reversed) {
      if (!_pathsOverlap(previous.path, path)) continue;
      if (_similarSearchQuery(previous.query, query)) return previous;
    }
    return null;
  }

  static bool _looksLikeImplementationPath(String path) {
    return RegExp(
      r'\.(dart|kt|swift|ts|tsx|js|jsx|java|go|rs|py|cs|cpp|h|m|mm)$',
      caseSensitive: false,
    ).hasMatch(path);
  }

  static List<_SearchHit> _parseSearchHits(String result) {
    if (result.startsWith('No matches')) return const [];
    final hits = <_SearchHit>[];
    final withLine = RegExp(
      r'^([\w./+-]+\.(?:dart|kt|swift|ts|tsx|js|jsx|java|go|rs|py|cs|cpp|h|m|mm)):(\d+):',
      multiLine: true,
      caseSensitive: false,
    );
    final pathOnly = RegExp(
      r'^([\w./+-]+\.(?:dart|kt|swift|ts|tsx|js|jsx|java|go|rs|py|cs|cpp|h|m|mm)) \(path match\)',
      multiLine: true,
      caseSensitive: false,
    );
    for (final match in withLine.allMatches(result)) {
      hits.add(
        _SearchHit(match.group(1)!, int.parse(match.group(2)!)),
      );
    }
    for (final match in pathOnly.allMatches(result)) {
      final path = match.group(1)!;
      if (hits.any((hit) => hit.path == path)) continue;
      hits.add(_SearchHit(path, null));
    }
    return hits;
  }

  void _softRejectSearch(
    List<String> transcript,
    String tool,
    String message,
  ) {
    onEvent(AgentEvent('denied', '$tool blocked'));
    _replaceNote(transcript, 'Host note:', 'Host note: $message');
  }

  static String _formatKnownMatches(_CompletedSearch search) {
    final lines = <String>[];
    for (final hit in search.hits.take(8)) {
      lines.add(
        hit.line == null ? '- ${hit.path}' : '- ${hit.path}:${hit.line}',
      );
    }
    if (lines.isEmpty) {
      return 'Known matches: (none retained; use previous search result in context)';
    }
    return 'Known matches:\n${lines.join('\n')}';
  }

  static String _formatKnownMatchesFromAll(List<_CompletedSearch> searches) {
    if (searches.isEmpty) {
      return 'Known matches: (none yet)';
    }
    return _formatKnownMatches(searches.last);
  }

  Future<String> _searchFiles(String query, String directory) async {
    final lower = query.toLowerCase();
    final files = (await store.listFiles(directory)).where(_useful).toList()
      ..sort();
    final matches = <String>[];
    var scanned = 0;
    for (final path in files) {
      if (matches.length >= 24 || scanned >= 800) break;
      if (path.toLowerCase().contains(lower)) {
        matches.add('$path (path match)');
        if (matches.length >= 24) break;
      }
      if (!_searchable(path)) continue;
      scanned++;
      try {
        final bytes = await store.readBytes(path);
        if (bytes.length > 256 * 1024 || bytes.contains(0)) continue;
        final lines = utf8.decode(bytes, allowMalformed: true).split('\n');
        for (var index = 0; index < lines.length; index++) {
          final line = lines[index];
          final position = line.toLowerCase().indexOf(lower);
          if (position < 0) continue;
          final start = position > 60 ? position - 60 : 0;
          final end = (position + query.length + 100)
              .clamp(0, line.length)
              .toInt();
          final snippet = line
              .substring(start, end)
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          matches.add('$path:${index + 1}: $snippet');
          if (matches.length >= 24) break;
        }
      } catch (_) {
        // Unreadable and transient files are omitted from search results.
      }
    }
    if (matches.isEmpty) {
      return 'No matches in $scanned searchable files.';
    }
    return '${matches.join('\n')}\n'
        'Returned ${matches.length} matches from $scanned searchable files.';
  }

  bool _searchable(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return true;
    const extensions = {
      'c',
      'cc',
      'cpp',
      'cs',
      'css',
      'dart',
      'go',
      'gradle',
      'h',
      'html',
      'java',
      'js',
      'json',
      'kt',
      'kts',
      'md',
      'm',
      'mm',
      'properties',
      'py',
      'rb',
      'rs',
      'sh',
      'swift',
      'toml',
      'ts',
      'tsx',
      'txt',
      'xml',
      'yaml',
      'yml',
    };
    return extensions.contains(path.substring(dot + 1).toLowerCase());
  }

  _AgentFileExcerpt _fileExcerpt(
    String path,
    String content,
    Map<String, dynamic> action, {
    List<int>? focusLines,
  }) {
    int? integer(String key) {
      final value = action[key];
      if (value == null) return null;
      if (value is! int) {
        throw ModelApiException('$key must be an integer.');
      }
      return value;
    }

    final lines = content.split('\n');
    final requestedStart = integer('startLine');
    final requestedCount = integer('lineCount');
    if (requestedStart != null && requestedStart < 1) {
      throw const ModelApiException('startLine must be positive.');
    }
    if (requestedCount != null &&
        (requestedCount < 1 || requestedCount > 500)) {
      throw const ModelApiException('lineCount must be between 1 and 500.');
    }

    if (requestedStart != null || requestedCount != null) {
      final start = (requestedStart ?? 1) - 1;
      if (start >= lines.length) {
        throw ModelApiException(
          'startLine exceeds the ${lines.length}-line file.',
        );
      }
      final count = requestedCount ?? defaultReadLineCount;
      return _sliceExcerpt(path, lines, start, start + count);
    }

    final uniqueFocus = {
      for (final line in focusLines ?? const <int>[])
        if (line >= 1 && line <= lines.length) line,
    }.toList()
      ..sort();
    if (uniqueFocus.isNotEmpty) {
      return _excerptAroundMatches(path, lines, uniqueFocus);
    }

    if (lines.length <= defaultReadLineCount &&
        content.length <= maxExcerptCharacters) {
      return _AgentFileExcerpt(path, content, '$path (${lines.length} lines)');
    }
    return _sliceExcerpt(path, lines, 0, defaultReadLineCount);
  }

  _AgentFileExcerpt _excerptAroundMatches(
    String path,
    List<String> lines,
    List<int> matchLines,
  ) {
    final windows = <List<int>>[];
    for (final line in matchLines) {
      final start = (line - 1 - matchContextRadius).clamp(0, lines.length);
      final end = (line + matchContextRadius).clamp(0, lines.length);
      if (windows.isNotEmpty && start <= windows.last[1]) {
        windows.last[1] = end > windows.last[1] ? end : windows.last[1];
      } else {
        windows.add([start, end]);
      }
    }
    final parts = <String>[];
    final labels = <String>[];
    var total = 0;
    for (final window in windows) {
      final from = window[0] + 1;
      final to = window[1];
      var chunk = lines.sublist(window[0], window[1]).join('\n');
      if (total + chunk.length > maxExcerptCharacters) {
        final remaining = maxExcerptCharacters - total;
        if (remaining <= 0) break;
        chunk =
            '${chunk.substring(0, remaining)}\n… excerpt character limit';
        parts.add('… lines $from-$to …\n$chunk');
        labels.add('$from-$to');
        break;
      }
      parts.add('… lines $from-$to …\n$chunk');
      labels.add('$from-$to');
      total += chunk.length;
    }
    return _AgentFileExcerpt(
      '$path [lines ${labels.join(',')}]',
      parts.join('\n\n'),
      '$path lines ${labels.join(', ')} of ${lines.length} (around search matches)',
    );
  }

  _AgentFileExcerpt _sliceExcerpt(
    String path,
    List<String> lines,
    int start,
    int endExclusive,
  ) {
    final end = endExclusive.clamp(0, lines.length).toInt();
    final safeStart = start.clamp(0, end).toInt();
    var excerpt = lines.sublist(safeStart, end).join('\n');
    if (excerpt.length > maxExcerptCharacters) {
      excerpt =
          '${excerpt.substring(0, maxExcerptCharacters)}\n… excerpt character limit';
    }
    final from = safeStart + 1;
    final to = end;
    return _AgentFileExcerpt(
      '$path [lines $from-$to]',
      excerpt,
      '$path lines $from-$to of ${lines.length}',
    );
  }

  void _rememberFile(
    Map<String, String> activeFiles,
    String key,
    String content,
    List<String> transcript,
  ) {
    // Keep one excerpt per path (drop older ranges for the same file).
    final pathKey = key.split(' ').first;
    activeFiles.removeWhere(
      (existing, _) =>
          existing == key ||
          existing == pathKey ||
          existing.startsWith('$pathKey '),
    );
    activeFiles[key] = content.length <= maxExcerptCharacters
        ? content
        : '${content.substring(0, maxExcerptCharacters)}\n… excerpt character limit';
    final evicted = <String>[];
    int characters() =>
        activeFiles.values.fold(0, (total, value) => total + value.length);
    while (activeFiles.length > maxActiveFiles ||
        characters() > maxActiveCharacters) {
      final oldest = activeFiles.keys.first;
      activeFiles.remove(oldest);
      evicted.add(oldest);
    }
    if (evicted.isNotEmpty) {
      _replaceNote(
        transcript,
        'Context eviction:',
        'Context eviction: ${evicted.join(', ')}. Read again only if needed.',
      );
    }
  }

  void _rememberObservation(
    Map<String, String> observations,
    String key,
    String value,
  ) {
    observations.remove(key);
    observations[key] = _bounded(value, 6000);
    int characters() =>
        observations.values.fold(0, (total, item) => total + item.length);
    while (observations.length > 6 || characters() > 16000) {
      observations.remove(observations.keys.first);
    }
  }

  void _replaceNote(List<String> transcript, String prefix, String value) {
    transcript.removeWhere((item) => item.startsWith(prefix));
    transcript.add(value);
  }

  String _bounded(String value, int maxCharacters) =>
      value.length <= maxCharacters
      ? value
      : '${value.substring(0, maxCharacters)}\n… result truncated';

  void _trim(List<String> transcript) {
    var characters = transcript.fold(0, (sum, item) => sum + item.length);
    while (characters > 24000 && transcript.length > 3) {
      final removable = transcript.indexWhere(
        (item) =>
            !item.startsWith('Task:') &&
            !item.startsWith('Phase:') &&
            !item.startsWith('Assistant analysis:') &&
            !item.startsWith('Host note:'),
      );
      if (removable < 0) break;
      characters -= transcript[removable].length;
      transcript.removeAt(removable);
    }
  }

  String _preview(String text, {int max = 240}) {
    final trimmed = text.trim();
    if (trimmed.length <= max) return trimmed;
    return '${trimmed.substring(0, max)}…';
  }
}

class _SearchHit {
  const _SearchHit(this.path, this.line);
  final String path;
  final int? line;
}

class _CompletedSearch {
  const _CompletedSearch({
    required this.query,
    required this.path,
    required this.result,
    required this.hits,
  });
  final String query;
  final String path;
  final String result;
  final List<_SearchHit> hits;
}

class _AgentFileExcerpt {
  const _AgentFileExcerpt(this.key, this.content, this.description);
  final String key, content, description;
}
