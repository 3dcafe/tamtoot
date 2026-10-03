import 'dart:async';
import 'dart:convert';

import '../git/git_service.dart';
import '../git/git_store.dart';
import '../git/multi_root_store.dart';
import 'agent_context_compactor.dart';
import 'model_attachment.dart';
import 'model_client.dart';
import 'model_profile.dart';
import 'hook_runner.dart';
import 'command_runner.dart';
import 'mcp_client.dart';
import 'project_memory.dart';

class AgentRunOptions {
  const AgentRunOptions({
    this.yolo = true,
    this.timeout = const Duration(minutes: 10),
    this.maxConsecutiveMistakes = 3,
    this.maxIterations = 40,
    this.maxSearchesBeforeFirstEdit = 5,
    this.maxReadsBeforeFirstEdit = 8,
    this.maxInvestigationIterationsBeforeFirstEdit = 12,
  });

  final bool yolo;
  final Duration timeout;
  final int maxConsecutiveMistakes, maxIterations;
  final int maxSearchesBeforeFirstEdit;
  final int maxReadsBeforeFirstEdit;
  final int maxInvestigationIterationsBeforeFirstEdit;
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
    this.workspaceRoots = const [],
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
  final List<Uri> workspaceRoots;
  bool _stopped = false;
  ModelClient? _active;

  /// Set while a run is in flight so aborted runs still keep what they learned.
  Future<void> Function(Object error)? _flushMemoryOnFailure;

  void stop() {
    _stopped = true;
    _active?.cancel();
    commands.stop();
    hooks.stop();
  }

  static const protocol = '''
CRITICAL: Your entire reply must be one JSON object starting with {.
Put the action in message content. Do not use reasoning_content / chain-of-thought.
If you think first, you will hit the token limit and fail.

You are an autonomous coding agent in Tamtoot (mobile IDE: no terminal, builds, tests, or shell).
Never run or ask for runtime checks; verify by reading files and say so in the finish summary.
Work quickly and make progress every iteration.
Do not spend an iteration explaining a plan. Start with the most useful tool action.
Reply with exactly ONE JSON object. No markdown fences, no commentary, no chain-of-thought, and no reasoning outside that JSON.

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

Implementation rules:
- Once the root cause is identified, STOP investigating and implement the smallest safe fix.
- Do not search for alternative implementations after the relevant call chain is understood.
- Prefer making a reasonable localized fix over fully mapping the architecture.
- If you have read both the caller and the failing implementation, your next action should normally be replace_in_file.
- Additional searches after root cause identification are allowed only when required to make the edit safely.
- replace_in_file must change a SMALL unique fragment only. Keep oldText and newText short (a few lines). Never paste a whole class/file into JSON.
- If a larger rewrite is needed, prefer several small replace_in_file steps, not one giant payload.

Memory rules:
- Retained project memory is pinned at the top of the context. Read it first.
- Compacted run context is a navigation summary, not exact source. Re-read the current excerpt before editing.
- When memory already names the relevant file, read that file instead of searching for it.
- Use retained project knowledge before searching.
- Do not rediscover known file locations unless the information appears stale or insufficient.
- Previous knowledge is a navigation hint, not authoritative source code.
- Before editing a previously known file, verify the smallest relevant current excerpt.
- Reuse known call chains, symbols, and implementation locations.
- After solving a task, preserve only durable project knowledge: important files, symbols, relationships, root causes, edits, and unresolved issues.
- Never preserve long reasoning or entire file contents.

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

  /// One navigation action is a few dozen tokens; this is pure headroom.
  static const int agentActionTokens = 700;

  /// Edits carry oldText/newText, so they get a slightly larger budget.
  static const int agentEditTokens = 1600;

  /// Minimal recovery request after an empty reply: cheap in and out.
  static const int agentRecoveryTokens = 800;

  /// Default window when the model does not specify a range.
  static const int defaultReadLineCount = 160;

  /// Lines kept around each search hit when auto-focusing a read.
  static const int matchContextRadius = 35;

  static const int maxActiveFiles = 6;
  static const int maxActiveCharacters = 48000;
  static const int maxExcerptCharacters = 8000;

  /// Soft cap so replace_in_file JSON cannot burn the whole completion budget.
  static const int maxReplaceFragmentCharacters = 4000;

  /// Shape of the single targeted read still allowed once the budget is spent.
  static const int maxFinalReadFiles = 3;
  static const int maxFinalReadLines = 160;

  static const investigationBudgetPrompt =
      'Investigation budget reached. You have enough context.\n'
      'Next action must be replace_in_file, write_file, or finish.\n'
      'Do NOT call read_file/read_files again — Active file context already '
      'has the relevant lines. Emit replace_in_file NOW.\n'
      'search_files and list_files stay disabled until you edit.';

  /// Compiler-style diagnostics: `path/file.cshtml(103,3): error RZ1034: ...`
  static final _buildErrorPattern = RegExp(
    r'([^\s\(\)]+\.(?:cshtml|razor|cs|dart|tsx?|jsx?|html?|css|js))\('
    r'(\d+)(?:,\d+)?\)\s*:\s*error\b',
    caseSensitive: false,
  );

  Future<AgentRunResult> run(String task, AgentRunOptions options) async {
    if (task.trim().isEmpty) {
      throw const ModelApiException('Enter an agent task.');
    }
    if (options.maxConsecutiveMistakes < 1 || options.maxIterations < 1) {
      throw const ModelApiException('Agent limits must be positive.');
    }
    if (options.yolo) {
      final roots = workspaceRoots.isEmpty ? [root] : workspaceRoots;
      for (final workspace in roots) {
        if (!await git.isRepository(workspace)) continue;
        final changes = await git.statusEntries(workspace);
      if (changes.isNotEmpty) {
          throw ModelApiException(
            'YOLO Mode requires a clean Git working tree. Commit or discard changes in $workspace first.',
        );
        }
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
    } catch (error) {
      if (_stopped) {
        try {
          await hooks.run('TaskCancel', {'task': task});
        } catch (_) {}
      }
      final flush = _flushMemoryOnFailure;
      _flushMemoryOnFailure = null;
      if (flush != null) {
        try {
          await flush(error);
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
    final compactedContext = <String>[];
    const contextCompactor = AgentContextCompactor();
    final activeFiles = <String, String>{};
    final observations = <String, String>{};
    _rememberObservation(observations, 'Project index', await _projectIndex());
    final memoryStore = ProjectMemoryStore(store);
    var projectMemory = await memoryStore.load();
    final memorySelection = projectMemory.selectRelevant(task);
    final stalePaths = await _staleMemoryPaths(projectMemory, memorySelection);
    final memoryPrompt = projectMemory.formatForPrompt(
      memorySelection,
      stalePaths: stalePaths,
    );
    final memoryFiles = <String>{
      ...memorySelection.recentEdits.map((edit) => edit.path),
      ...memorySelection.areas.expand((area) => area.files),
    }.take(4).toList();
    if (memoryPrompt.isNotEmpty) {
      onEvent(
        AgentEvent(
          'memory',
          'Loaded ${memorySelection.areaCount} relevant project '
              '${memorySelection.areaCount == 1 ? 'memory' : 'memories'}',
        ),
      );
      for (final path in memoryFiles.take(3)) {
        onEvent(AgentEvent('memory', 'Reused known location: $path'));
      }
      if (memoryFiles.isNotEmpty) {
        transcript.add(
          'Memory note: Retained memory already points to '
          '${memoryFiles.join(', ')}. Read the smallest relevant excerpt there '
          'instead of searching for it again.',
        );
      }
    }
    final runReadPaths = <String>{};
    final runEditedPaths = <String>{};
    final runFingerprints = <String, String>{};
    final runLearned = <String>[];
    // Investigation that ends in a mistake limit or timeout is still worth
    // keeping, otherwise the next run rediscovers the same call chain.
    _flushMemoryOnFailure = (error) => _persistProjectMemory(
      memoryStore: memoryStore,
      memory: projectMemory,
      task: task,
      summary: '',
      readPaths: runReadPaths,
      editedPaths: runEditedPaths,
      fingerprints: runFingerprints,
      learned: runLearned,
      unresolved: [
        'Run stopped before finishing: ${_bounded(_firstLine('$error'), 120)}',
      ],
    );
    var mistakes = 0;
    var consecutiveSays = 0;
    var consecutiveSearches = 0;
    var consecutiveBlockedReads = 0;
    var requireReadAfterSearch = false;
    var jsonMode = true;
    final completedSearches = <_CompletedSearch>[];
    final focusLinesByPath = <String, List<int>>{};
    var searchesBeforeEdit = 0;
    var filesReadBeforeEdit = 0;
    var hasEdited = false;
    var finalReadUsed = false;
    await _seedBuildErrorContext(
      task: task,
      activeFiles: activeFiles,
      transcript: transcript,
      runReadPaths: runReadPaths,
      runFingerprints: runFingerprints,
      focusLinesByPath: focusLinesByPath,
    );
    final systemPrompt = [
      profile.systemPrompt,
      protocol,
      if (mcp != null && mcp!.tools.isNotEmpty)
        'Available MCP tools:\n${mcp!.describe()}',
    ].join('\n\n');
    for (var iteration = 1; iteration <= options.maxIterations; iteration++) {
      if (_stopped) {
        throw const ModelApiException('Agent stopped.');
      }
      onEvent(AgentEvent('iteration', 'Iteration $iteration'));
      final budgetReached =
          !hasEdited &&
          _investigationExhausted(
            searches: searchesBeforeEdit,
            filesRead: filesReadBeforeEdit,
            iteration: iteration,
            options: options,
          );
      if (!hasEdited) {
        _injectInvestigationBudget(
          transcript,
          searches: searchesBeforeEdit,
          filesRead: filesReadBeforeEdit,
          iteration: iteration,
          options: options,
        );
      }
      final implementationPhase =
          hasEdited || budgetReached || activeFiles.isNotEmpty;
      final compaction = contextCompactor.compact(
        transcript: transcript,
        observations: observations,
        activeFiles: activeFiles,
        summary: compactedContext,
        pinnedCharacters: systemPrompt.length + memoryPrompt.length,
      );
      if (compaction.changed) {
        onEvent(
          AgentEvent(
            'context',
            'Compressed context: ${compaction.beforeCharacters} → '
                '${compaction.afterCharacters} characters '
                '(${compaction.fileExcerpts} file excerpts, '
                '${compaction.observations} observations, '
                '${compaction.transcriptItems} messages)',
          ),
        );
      }
      late final ModelReply reply;
      try {
        reply = await _requestAction(
          options: options,
          maxTokens: implementationPhase ? agentEditTokens : agentActionTokens,
          jsonMode: jsonMode,
          systemPrompt: systemPrompt,
          userPrompt: _buildPrompt(
            transcript,
            activeFiles,
            observations,
            memoryPrompt,
            compactedContext,
          ),
          attachments: iteration == 1 ? attachments : const [],
          // Empty content is answered by a tiny request instead of a full
          // agent turn: no transcript, no file context, no reasoning echo.
          onEmptyAnswer: (failure) => _recoveryRequest(
            options: options,
            failure: failure,
            jsonMode: jsonMode,
            implementationPhase: implementationPhase,
            task: task,
            knownFiles: _knownRelevantFiles(
              activeFiles: activeFiles,
              searches: completedSearches,
              memoryFiles: memoryFiles,
            ),
          ),
        );
      } on ModelApiException catch (e) {
        if (jsonMode && ModelClient.rejectedJsonObjectMode(e.message)) {
          jsonMode = false;
          onEvent(
            AgentEvent('context', 'Provider rejected JSON mode; disabled it'),
          );
          continue;
        }
        mistakes++;
        onEvent(AgentEvent('error', e.message));
        _replaceNote(
          transcript,
          'Host note:',
          'Host note: ${_requestFailureNote(e)}',
        );
        if (mistakes >= options.maxConsecutiveMistakes) {
          throw ModelApiException(
            'Agent stopped after $mistakes consecutive mistakes: ${e.message}',
          );
        }
        continue;
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
      late final Map<String, dynamic> action;
      late final String name;
      try {
        final objects = _extractJsonObjects(reply.text);
        if (objects.isEmpty) {
          if (_looksTruncated(reply.text, reply.note)) {
            throw ModelApiException(
              'Model output was truncated before a complete JSON action '
              '(${reply.note.isEmpty ? 'incomplete JSON' : reply.note}). '
              'Emit a MUCH smaller action next. For edits, use replace_in_file '
              'with a few-line unique oldText/newText only — never a whole file.',
            );
          }
          throw const ModelApiException(
            'Model returned an invalid agent action.',
          );
        }
        action = _selectAction(
          objects,
          budgetReached: budgetReached,
          finalReadUsed: finalReadUsed,
          transcript: transcript,
        );
        name = action['action'] as String;
        if (name == 'replace_in_file' || name == 'write_file') {
          _assertCompactEditPayload(name, action);
        }
        int? readLineBudget;
        var readFileBudget = 4;
        final isRead = name == 'read_file' || name == 'read_files';
        if (budgetReached && isRead) {
          if (finalReadUsed) {
            consecutiveBlockedReads++;
            _softRejectSearch(
              transcript,
              name,
              'The final targeted read was already used.\n'
              '$investigationBudgetPrompt\n'
              'Blocked read #$consecutiveBlockedReads. '
              'Do not read again — replace_in_file or finish.',
            );
            // Soft-denies used to burn all iterations for free. Count them.
            mistakes++;
            if (consecutiveBlockedReads >= 2 ||
                mistakes >= options.maxConsecutiveMistakes) {
              throw ModelApiException(
                'Agent kept calling $name after the investigation budget. '
                'Context is already loaded — press Continue and emit '
                'replace_in_file (or finish) instead of another read.',
              );
            }
            continue;
          }
          // Normalize the read instead of denying it: denying would only cost
          // another model round-trip to ask for the same thing, smaller.
          finalReadUsed = true;
          readLineBudget = maxFinalReadLines;
          readFileBudget = maxFinalReadFiles;
          onEvent(
            AgentEvent(
              'context',
              'Final targeted read: max $maxFinalReadFiles files, '
                  '$maxFinalReadLines lines each',
            ),
          );
        } else if (!hasEdited &&
            _blocksPreEditInvestigation(
              name,
              searches: searchesBeforeEdit,
              filesRead: filesReadBeforeEdit,
              iteration: iteration,
              options: options,
            )) {
          _softRejectSearch(
            transcript,
            name,
            'Investigation budget reached ($name blocked).\n'
            '$investigationBudgetPrompt',
          );
          continue;
        }
        if (!isRead) consecutiveBlockedReads = 0;
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
            final knownFromMemory = projectMemory.knownPathsForQuery(query);
            if (knownFromMemory.isNotEmpty &&
                runReadPaths.isEmpty &&
                !hasEdited) {
              onEvent(AgentEvent('memory', 'Skipped redundant search: $query'));
              _softRejectSearch(
                transcript,
                'search_files',
                'Search skipped: retained project knowledge already points to:\n'
                    '${knownFromMemory.map((item) => '- $item').join('\n')}\n'
                    'Read the smallest relevant current excerpt from those files '
                    '(or one targeted search only if that knowledge is insufficient/stale).',
              );
              continue;
            }
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
            if (hits.isNotEmpty) {
              final sample = hits
                  .take(3)
                  .map(
                    (hit) =>
                        hit.line == null ? hit.path : '${hit.path}:${hit.line}',
                  )
                  .join(', ');
              runLearned.add('$query → $sample');
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
            searchesBeforeEdit++;
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
              maxLines: readLineBudget,
            );
            _rememberFile(
              activeFiles,
              excerpt.key,
              excerpt.content,
              transcript,
            );
            onEvent(AgentEvent('tool', 'Read $path'));
            runReadPaths.add(path);
            runFingerprints[path] = ProjectMemory.fingerprintText(content);
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
            filesReadBeforeEdit++;
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
            // Over-wide batches are trimmed, not rejected: the host already
            // knows what the smaller request would look like.
            final requestedPaths = rawPaths.length > readFileBudget
                ? rawPaths.take(readFileBudget).toList()
                : rawPaths;
            if (requestedPaths.length < rawPaths.length) {
              _replaceNote(
                transcript,
                'Normalized action:',
                'Normalized action: read_files trimmed to the first '
                    '${requestedPaths.length} of ${rawPaths.length} paths.',
              );
            }
            final descriptions = <String>[];
            for (final raw in requestedPaths) {
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
                maxLines: readLineBudget,
              );
              _rememberFile(
                activeFiles,
                excerpt.key,
                excerpt.content,
                transcript,
              );
              descriptions.add(excerpt.description);
              runReadPaths.add(path);
              runFingerprints[path] = ProjectMemory.fingerprintText(content);
            }
            onEvent(
              AgentEvent(
                'tool',
                'Read ${requestedPaths.length} files: ${descriptions.join('; ')}',
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
            filesReadBeforeEdit += requestedPaths.length;
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
            runEditedPaths.add(path);
            runFingerprints[path] = ProjectMemory.fingerprintText(updated);
            transcript.add(
              'Tool replace_in_file result: edited $path successfully. Read the changed area before finishing.',
            );
            hasEdited = true;
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
            runEditedPaths.add(path);
            runFingerprints[path] = ProjectMemory.fingerprintText(content);
            transcript.add(
              'Tool write_file result: wrote $path successfully. Inspect it before finishing.',
            );
            hasEdited = true;
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
            _flushMemoryOnFailure = null;
            await _persistProjectMemory(
              memoryStore: memoryStore,
              memory: projectMemory,
              task: task,
              summary: summary,
              readPaths: runReadPaths,
              editedPaths: runEditedPaths,
              fingerprints: runFingerprints,
              learned: runLearned,
            );
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
        final editHint =
            message.contains('truncated') ||
                message.contains('too large') ||
                message.contains('incomplete JSON') ||
                message.contains('invalid agent action')
            ? '\nFor code changes: emit replace_in_file with a few-line unique '
                  'oldText/newText only. Do not rewrite whole files in one JSON action.'
            : '';
        transcript.add(
          'Tool/action error: $message$editHint\n'
          'Fix the mistake and continue with one short JSON action.',
        );
        if (mistakes >= options.maxConsecutiveMistakes) {
          throw ModelApiException(
            'Agent stopped after $mistakes consecutive mistakes: $message',
          );
        }
      }
    }
    throw ModelApiException(
      'Agent reached the ${options.maxIterations}-iteration limit.',
    );
  }

  /// One model turn; empty content is repaired by [onEmptyAnswer] in place.
  Future<ModelReply> _requestAction({
    required AgentRunOptions options,
    required int maxTokens,
    required bool jsonMode,
    required String systemPrompt,
    required String userPrompt,
    List<ModelAttachment> attachments = const [],
    Future<ModelReply> Function(ModelEmptyAnswerException failure)?
    onEmptyAnswer,
  }) async {
    try {
      return await _send(
        options: options,
        maxTokens: maxTokens,
        jsonMode: jsonMode,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        attachments: attachments,
      );
    } on ModelEmptyAnswerException catch (e) {
      if (onEmptyAnswer == null) rethrow;
      onEvent(AgentEvent('error', e.message));
      return await onEmptyAnswer(e);
    }
  }

  Future<ModelReply> _send({
    required AgentRunOptions options,
    required int maxTokens,
    required bool jsonMode,
    required String systemPrompt,
    required String userPrompt,
    List<ModelAttachment> attachments = const [],
  }) async {
    if (attachments.isNotEmpty) {
      final summary = attachments
          .map((item) {
            final via = item.isImage
                ? 'image'
                : item.asUtf8Text != null
                ? 'text'
                : 'file';
            return '${item.name} ($via, ${item.bytes.length} B)';
          })
          .join(', ');
      onEvent(
        AgentEvent(
          'context',
          'Sending ${attachments.length} attachment(s) to the model: $summary',
        ),
      );
    }
    final client =
        clientFactory?.call() ?? ModelClient(timeout: options.timeout);
    _active = client;
    try {
      return await client.send(
        _agentRequestProfile(maxTokens: maxTokens, jsonMode: jsonMode),
        {'systemPrompt': systemPrompt, 'userPrompt': userPrompt},
        apiKey: apiKey,
        attachments: attachments,
      );
    } finally {
      _active = null;
    }
  }

  /// Cheap second attempt: phase, allowed actions and known paths only.
  ///
  /// The failed reasoning is never echoed back — it is what exhausted the
  /// budget in the first place.
  Future<ModelReply> _recoveryRequest({
    required AgentRunOptions options,
    required ModelEmptyAnswerException failure,
    required bool jsonMode,
    required bool implementationPhase,
    required String task,
    required List<String> knownFiles,
  }) {
    onEvent(
      AgentEvent(
        'context',
        'Recovery request after '
            '${failure.reasoningOnly ? 'a reasoning-only reply' : 'empty content'} '
            '(minimal prompt, $agentRecoveryTokens tokens)',
      ),
    );
    const system =
        'Return exactly one JSON action in message.content.\n'
        'Do not explain. Do not use reasoning_content.\n'
        'Shapes:\n'
        '{"action":"read_file","path":"relative/file","startLine":1,"lineCount":60}\n'
        '{"action":"replace_in_file","path":"relative/file","oldText":"...","newText":"..."}\n'
        '{"action":"write_file","path":"relative/file","content":"..."}\n'
        '{"action":"search_files","query":"literal text"}\n'
        '{"action":"finish","summary":"..."}';
    final allowed = implementationPhase
        ? const ['read_file', 'replace_in_file', 'write_file', 'finish']
        : const ['search_files', 'read_file', 'finish'];
    final user = StringBuffer()
      ..writeln('Previous response failed because content was empty.')
      ..writeln()
      ..writeln('Task: ${_bounded(task.trim(), 200)}')
      ..writeln(
        'Current required phase: '
        '${implementationPhase ? 'implementation' : 'investigation'}.',
      )
      ..writeln('Allowed next actions:');
    for (final action in allowed) {
      user.writeln('- $action');
    }
    if (knownFiles.isNotEmpty) {
      user
        ..writeln()
        ..writeln('Known relevant files:');
      for (final path in knownFiles) {
        user.writeln('- $path');
      }
    }
    user
      ..writeln()
      ..write('Return the next action only.');
    return _send(
      options: options,
      maxTokens: agentRecoveryTokens,
      jsonMode: jsonMode,
      systemPrompt: system,
      userPrompt: user.toString(),
    );
  }

  List<String> _knownRelevantFiles({
    required Map<String, String> activeFiles,
    required List<_CompletedSearch> searches,
    required List<String> memoryFiles,
  }) {
    final paths = <String>{};
    for (final key in activeFiles.keys) {
      paths.add(key.split(' ').first);
    }
    if (searches.isNotEmpty) {
      for (final hit in searches.last.hits) {
        if (_looksLikeImplementationPath(hit.path)) paths.add(hit.path);
      }
    }
    paths.addAll(memoryFiles);
    return paths.take(4).toList();
  }

  /// Short, reasoning-free note for the transcript after a failed request.
  String _requestFailureNote(ModelApiException e) {
    if (e is ModelEmptyAnswerException) {
      final details = [
        if (e.finishReason.isNotEmpty) 'finish_reason: ${e.finishReason}',
        if (e.reasoningOnly)
          'reasoning_content: ${e.reasoningCharacters} chars',
        if (e.hadToolCalls) 'native tool_calls',
      ].join(', ');
      return 'Previous reply left message.content empty'
          '${details.isEmpty ? '' : ' ($details)'}. '
          'Write one short JSON action into message.content. '
          'First character must be {. No analysis, no reasoning_content.';
    }
    return 'Model request failed: ${_bounded(_firstLine(e.message), 200)}. '
        'Emit exactly one short JSON action next. First character must be {.';
  }

  static String _firstLine(String value) {
    final index = value.indexOf('\n');
    return index < 0 ? value : value.substring(0, index);
  }

  Future<HookResult> _hook(String type, Map<String, dynamic> input) async {
    final result = await hooks.run(type, input);
    onEvent(AgentEvent('hook', '$type: ${result.cancel ? 'blocked' : 'ok'}'));
    return result;
  }

  Map<String, dynamic> _decodeActionObject(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> || decoded['action'] is! String) {
      throw const ModelApiException('Model returned an invalid agent action.');
    }
    return decoded;
  }

  /// When the model emits NDJSON and the first action is a read the host would
  /// soft-block, prefer the next edit/finish from the same reply.
  Map<String, dynamic> _selectAction(
    List<String> objects, {
    required bool budgetReached,
    required bool finalReadUsed,
    required List<String> transcript,
  }) {
    final first = _decodeActionObject(objects.first);
    final firstName = first['action'] as String;
    final canPreferFollowUp = _wouldBlockRead(
      firstName,
      budgetReached: budgetReached,
      finalReadUsed: finalReadUsed,
    );
    if (!canPreferFollowUp || objects.length < 2) {
      return first;
    }
    try {
      final next = _decodeActionObject(objects[1]);
      final nextName = next['action'] as String;
      if (nextName == 'replace_in_file' ||
          nextName == 'write_file' ||
          nextName == 'finish') {
        onEvent(
          AgentEvent(
            'context',
            'Normalized: skipped blocked $firstName, ran $nextName',
          ),
        );
        _replaceNote(
          transcript,
          'Host note:',
          'Host note: Skipped blocked $firstName from a multi-action reply; '
              'ran $nextName instead.',
        );
        return next;
      }
    } catch (_) {
      // Keep the blocked read as the selected action; the soft-reject path
      // below will tell the model to edit instead.
    }
    return first;
  }

  static bool _wouldBlockRead(
    String action, {
    required bool budgetReached,
    required bool finalReadUsed,
  }) {
    if (action != 'read_file' && action != 'read_files') return false;
    return budgetReached && finalReadUsed;
  }

  void _assertCompactEditPayload(String name, Map<String, dynamic> action) {
    if (name == 'replace_in_file') {
      for (final key in ['oldText', 'newText']) {
        final value = action[key];
        if (value is! String) continue;
        if (value.length > maxReplaceFragmentCharacters) {
          throw ModelApiException(
            '$name.$key is too large (${value.length} chars; '
            'max $maxReplaceFragmentCharacters). '
            'Replace a few unique lines only, then finish or do another small edit.',
          );
        }
      }
      return;
    }
    if (name == 'write_file') {
      final content = action['content'];
      if (content is String &&
          content.length > maxReplaceFragmentCharacters * 4) {
        throw ModelApiException(
          'write_file.content is too large for one agent step '
          '(${content.length} chars). Prefer replace_in_file for small unique fragments.',
        );
      }
    }
  }

  static bool _looksTruncated(String text, String note) {
    final source = text.trim();
    if (source.isEmpty) return true;
    var depth = 0;
    var inString = false;
    var escaped = false;
    var sawObject = false;
    for (var i = 0; i < source.length; i++) {
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
      if (ch == '{') {
        depth++;
        sawObject = true;
      } else if (ch == '}') {
        depth--;
      }
    }
    final incompleteJson = sawObject && (inString || depth != 0);
    if (incompleteJson) return true;
    // Provider said length, but JSON closed — accept it.
    return false;
  }

  /// Models sometimes emit NDJSON / several actions. Return complete objects
  /// only (trailing truncated JSON is ignored when at least one object parsed).
  static List<String> _extractJsonObjects(String text, {int max = 3}) {
    var source = text.trim();
    if (source.startsWith('```')) {
      source = source.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      source = source.replaceFirst(RegExp(r'\s*```$'), '');
      source = source.trim();
    }
    final out = <String>[];
    var cursor = 0;
    while (out.length < max) {
      final start = source.indexOf('{', cursor);
      if (start < 0) break;
      var depth = 0;
      var inString = false;
      var escaped = false;
      var end = -1;
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
          if (depth == 0) {
            end = i;
            break;
          }
        }
      }
      if (end < 0) break;
      out.add(source.substring(start, end + 1));
      cursor = end + 1;
    }
    return out;
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

  /// Suffix candidates from an absolute/relative compiler path.
  Iterable<String> _projectPathCandidates(String raw) sync* {
    final segments = raw
        .replaceAll('\\', '/')
        .trim()
        .split('/')
        .where((part) => part.isNotEmpty && part != '.' && part != '..')
        .toList();
    for (var i = 0; i < segments.length; i++) {
      final candidate = segments.sublist(i).join('/');
      try {
        yield _path(candidate);
      } catch (_) {
        // Skip escape / protected prefixes.
      }
    }
  }

  bool _allowed(String path) =>
      !path.split('/').any((part) => part == '.git' || part == '.tamtoot');

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
    String memoryPrompt,
    List<String> compactedContext,
  ) {
    final out = StringBuffer(transcript.join('\n\n'));
    // Pinned: persistent memory must never be evicted by fresh observations.
    if (memoryPrompt.isNotEmpty) {
      out.write('\n\n--- Retained project memory (persistent) ---\n');
      out.write(memoryPrompt);
    }
    if (compactedContext.isNotEmpty) {
      out.write('\n\n--- Compacted run context ---\n');
      for (final item in compactedContext) {
        out.writeln('- $item');
      }
    }
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
    const maxPaths = 240;
    const maxCharacters = 8000;
    final out = StringBuffer(
      'Project file index (one-time). Prefer literal search_files for symbols, then read_files:\n',
    );
    final multi = store is MultiRootGitRepositoryStore
        ? store as MultiRootGitRepositoryStore
        : null;
    if (multi != null) {
      out
        ..writeln('Primary project paths are unprefixed.')
        ..writeln(multi.mountDescription);
    }
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

  /// Profile for one agent request: tight budget, no thinking, JSON mode.
  ModelProfile _agentRequestProfile({
    required int maxTokens,
    required bool jsonMode,
  }) {
    final format = profile.apiFormat;
    final params = Map<String, dynamic>.from(profile.parameters);
    // Each API format names the completion budget differently.
    params.removeWhere((key, _) => ModelClient.tokenBudgetKeys.contains(key));
    params[ModelClient.tokenBudgetKey(format)] = maxTokens;
    for (final entry in ModelClient.disableThinkingParameters(format).entries) {
      final existing = params[entry.key];
      final value = entry.value;
      params[entry.key] = existing is Map && value is Map
          ? {...Map<String, dynamic>.from(existing), ...value}
          : value;
    }
    if (jsonMode && ModelClient.supportsJsonObjectMode(format)) {
      // The protocol is a single JSON object, so ask the API to enforce it.
      params['response_format'] = const {'type': 'json_object'};
    }
    return ModelProfile(
      id: profile.id,
      name: profile.name,
      provider: profile.provider,
      model: profile.model,
      systemPrompt: profile.systemPrompt,
      userTemplate: profile.userTemplate,
      parameters: params,
      apiFormat: format,
      endpoint: profile.endpoint,
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
      hits.add(_SearchHit(match.group(1)!, int.parse(match.group(2)!)));
    }
    for (final match in pathOnly.allMatches(result)) {
      final path = match.group(1)!;
      if (hits.any((hit) => hit.path == path)) continue;
      hits.add(_SearchHit(path, null));
    }
    return hits;
  }

  Future<Set<String>> _staleMemoryPaths(
    ProjectMemory memory,
    ProjectMemorySelection selection,
  ) async {
    final stale = <String>{};
    final candidates = <String>{
      ...selection.areas.expand((area) => area.files),
      ...selection.recentEdits.map((edit) => edit.path),
    };
    for (final path in candidates) {
      String? expected;
      for (final area in memory.areas) {
        expected ??= area.fileFingerprints[path];
      }
      for (final edit in memory.recentEdits) {
        if (edit.path == path && edit.fingerprint.isNotEmpty) {
          expected ??= edit.fingerprint;
        }
      }
      if (expected == null || expected.isEmpty) continue;
      try {
        if (!await store.exists(path)) {
          stale.add(path);
          continue;
        }
        final current = ProjectMemory.fingerprintBytes(
          await store.readBytes(path),
        );
        if (current != expected) stale.add(path);
      } catch (_) {
        stale.add(path);
      }
    }
    return stale;
  }

  Future<void> _persistProjectMemory({
    required ProjectMemoryStore memoryStore,
    required ProjectMemory memory,
    required String task,
    required String summary,
    required Set<String> readPaths,
    required Set<String> editedPaths,
    required Map<String, String> fingerprints,
    required List<String> learned,
    List<String> unresolved = const [],
  }) async {
    if (readPaths.isEmpty && editedPaths.isEmpty && summary.trim().isEmpty) {
      return;
    }
    try {
      // Refresh fingerprints for edited/read files when missing.
      for (final path in {...readPaths, ...editedPaths}) {
        if (fingerprints.containsKey(path)) continue;
        try {
          if (await store.exists(path)) {
            fingerprints[path] = ProjectMemory.fingerprintBytes(
              await store.readBytes(path),
            );
          }
        } catch (_) {}
      }
      final result = memory.mergeTask(
        task: task,
        summary: summary,
        readPaths: readPaths,
        editedPaths: editedPaths,
        fileFingerprints: fingerprints,
        learnedFacts: learned.take(6),
        unresolved: unresolved,
      );
      await memoryStore.save(memory);
      onEvent(AgentEvent('memory', 'Updated area: ${result.areaTitle}'));
      if (result.compacted) {
        onEvent(
          AgentEvent(
            'memory',
            'Compacted project memory: '
                '${(result.charactersBefore / 4).round()} -> '
                '${(result.charactersAfter / 4).round()} tokens',
          ),
        );
      }
    } catch (error) {
      onEvent(
        AgentEvent(
          'memory',
          'Skipped memory update: ${_bounded('$error', 200)}',
        ),
      );
    }
  }

  void _softRejectSearch(List<String> transcript, String tool, String message) {
    onEvent(AgentEvent('denied', '$tool blocked'));
    _replaceNote(transcript, 'Host note:', 'Host note: $message');
  }

  void _injectInvestigationBudget(
    List<String> transcript, {
    required int searches,
    required int filesRead,
    required int iteration,
    required AgentRunOptions options,
  }) {
    if (!_shouldPromptInvestigationBudget(
      searches: searches,
      filesRead: filesRead,
      iteration: iteration,
      options: options,
    )) {
      return;
    }
    _replaceNote(
      transcript,
      'Investigation budget:',
      'Investigation budget: $investigationBudgetPrompt',
    );
  }

  static bool _investigationExhausted({
    required int searches,
    required int filesRead,
    required int iteration,
    required AgentRunOptions options,
  }) {
    return searches >= options.maxSearchesBeforeFirstEdit ||
        filesRead >= options.maxReadsBeforeFirstEdit ||
        iteration > options.maxInvestigationIterationsBeforeFirstEdit;
  }

  static bool _shouldPromptInvestigationBudget({
    required int searches,
    required int filesRead,
    required int iteration,
    required AgentRunOptions options,
  }) {
    if (_investigationExhausted(
      searches: searches,
      filesRead: filesRead,
      iteration: iteration,
      options: options,
    )) {
      return true;
    }
    return searches >= 2 && filesRead >= 2;
  }

  static bool _blocksPreEditInvestigation(
    String action, {
    required int searches,
    required int filesRead,
    required int iteration,
    required AgentRunOptions options,
  }) {
    // Reads are never denied here: the caller narrows them instead.
    if (action == 'read_file' ||
        action == 'read_files' ||
        action == 'replace_in_file' ||
        action == 'write_file' ||
        action == 'finish' ||
        action == 'mcp_call') {
      return false;
    }
    if (action == 'search_files' &&
        searches >= options.maxSearchesBeforeFirstEdit) {
      return true;
    }
    if (!_investigationExhausted(
      searches: searches,
      filesRead: filesRead,
      iteration: iteration,
      options: options,
    )) {
      return false;
    }
    return action == 'search_files' ||
        action == 'list_files' ||
        action == 'say';
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
    int? maxLines,
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
    // Out-of-range windows are clamped rather than rejected, so a slightly
    // wrong range never costs an extra model round-trip.
    final requestedStart = integer('startLine')?.clamp(1, lines.length);
    final requestedCount = integer('lineCount')?.clamp(1, maxLines ?? 500);
    final budget = maxLines ?? defaultReadLineCount;

    if (requestedStart != null || requestedCount != null) {
      final start = (requestedStart ?? 1) - 1;
      final count = requestedCount ?? budget;
      return _sliceExcerpt(path, lines, start, start + count);
    }

    final uniqueFocus = {
      for (final line in focusLines ?? const <int>[])
        if (line >= 1 && line <= lines.length) line,
    }.toList()..sort();
    if (uniqueFocus.isNotEmpty) {
      return _excerptAroundMatches(
        path,
        lines,
        uniqueFocus,
        maxLines: maxLines,
      );
    }

    if (lines.length <= budget && content.length <= maxExcerptCharacters) {
      return _AgentFileExcerpt(path, content, '$path (${lines.length} lines)');
    }
    return _sliceExcerpt(path, lines, 0, budget);
  }

  _AgentFileExcerpt _excerptAroundMatches(
    String path,
    List<String> lines,
    List<int> matchLines, {
    int? maxLines,
  }) {
    // Share the line budget between match windows when one is set.
    final radius = maxLines == null
        ? matchContextRadius
        : (maxLines ~/ (2 * matchLines.length)).clamp(6, matchContextRadius);
    final windows = <List<int>>[];
    for (final line in matchLines) {
      final start = (line - 1 - radius).clamp(0, lines.length);
      final end = (line + radius).clamp(0, lines.length);
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
        chunk = '${chunk.substring(0, remaining)}\n… excerpt character limit';
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
    final kept = <String>[];
    var total = 0;
    var actualEnd = safeStart;
    for (var i = safeStart; i < end; i++) {
      final line = lines[i];
      final add = line.length + (kept.isEmpty ? 0 : 1);
      if (total + add > maxExcerptCharacters) break;
      kept.add(line);
      total += add;
      actualEnd = i + 1;
    }
    final truncated = actualEnd < end;
    final excerpt = truncated
        ? '${kept.join('\n')}\n… excerpt truncated after line $actualEnd of ${lines.length}'
        : kept.join('\n');
    final from = safeStart + 1;
    final to = actualEnd == safeStart ? safeStart : actualEnd;
    return _AgentFileExcerpt(
      '$path [lines $from-$to]',
      excerpt,
      truncated
          ? '$path lines $from-$to of ${lines.length} (truncated)'
          : '$path lines $from-$to of ${lines.length}',
    );
  }

  void _rememberFile(
    Map<String, String> activeFiles,
    String key,
    String content,
    List<String> transcript,
  ) {
    final pathKey = key.split(' ').first;
    // Keep up to two ranges per file (e.g. open tags + error line / close tags).
    // Wiping to a single window caused start↔end ping-pong and missed mismatches.
    final samePath = activeFiles.keys
        .where(
          (existing) =>
              existing == pathKey || existing.startsWith('$pathKey '),
        )
        .toList();
    if (activeFiles.containsKey(key)) {
      // Refresh the exact same window.
    } else if (samePath.length >= 2) {
      activeFiles.remove(samePath.first);
    }
    // Prefer whole-line truncation so replace_in_file never sees a fake file end.
    if (content.length <= maxExcerptCharacters) {
      activeFiles[key] = content;
    } else {
      final cut = content.lastIndexOf('\n', maxExcerptCharacters);
      final keepTo = cut > 0 ? cut : maxExcerptCharacters;
      activeFiles[key] =
          '${content.substring(0, keepTo)}\n… excerpt truncated';
    }
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

  /// Pre-load the file/line named in a compiler error so the agent can edit
  /// immediately instead of burning iterations rediscovering the location.
  Future<void> _seedBuildErrorContext({
    required String task,
    required Map<String, String> activeFiles,
    required List<String> transcript,
    required Set<String> runReadPaths,
    required Map<String, String> runFingerprints,
    required Map<String, List<int>> focusLinesByPath,
  }) async {
    final matches = _buildErrorPattern.allMatches(task).take(3);
    if (matches.isEmpty) return;
    for (final match in matches) {
      final rawPath = match.group(1)!;
      final line = int.tryParse(match.group(2)!);
      if (line == null || line < 1) continue;
      String? path;
      for (final candidate in _projectPathCandidates(rawPath)) {
        if (await store.exists(candidate)) {
          path = candidate;
          break;
        }
      }
      if (path == null) continue;
      try {
        final bytes = await store.readBytes(path);
        if (bytes.length > 1024 * 1024) continue;
        final content = utf8.decode(bytes);
        focusLinesByPath.putIfAbsent(path, () => <int>[]).add(line);
        final excerpt = _fileExcerpt(
          path,
          content,
          {
            'startLine': (line - 25).clamp(1, 1 << 30),
            'lineCount': 60,
          },
          focusLines: focusLinesByPath[path],
          maxLines: 80,
        );
        _rememberFile(activeFiles, excerpt.key, excerpt.content, transcript);
        runReadPaths.add(path);
        runFingerprints[path] = ProjectMemory.fingerprintText(content);
        onEvent(
          AgentEvent(
            'context',
            'Seeded build-error context: ${excerpt.description}',
          ),
        );
        _replaceNote(
          transcript,
          'Build error context:',
          'Build error context: ${excerpt.description} is already in Active '
              'file context. Prefer replace_in_file for the malformed tag/'
              'syntax near that line — do not keep re-reading the same file.',
        );
      } catch (_) {
        // Best-effort seed; the model can still read if this fails.
      }
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
