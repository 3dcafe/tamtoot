import 'dart:async';
import 'dart:convert';

import '../git/git_service.dart';
import '../git/git_store.dart';
import '../git/multi_root_store.dart';
import 'agent_context_compactor.dart';
import 'model_attachment.dart';
import 'model_client.dart';
import 'native_tool_session.dart';
import 'agent_edit_state.dart';
import 'agent_completion.dart';
import 'agent_generation.dart';
import 'test_command.dart';
import 'model_profile.dart';
import 'hook_runner.dart';
import 'command_runner.dart';
import 'mcp_client.dart';
import 'project_memory.dart';
import 'agent_privacy.dart';

class AgentRunOptions {
  const AgentRunOptions({
    this.writeAndRunTests = false,
    this.localMaxTokens = 4096,
    this.localTemperature = 0.15,
    this.localResponseFormat = 'auto',
    this.localThinking = 'off',
    this.toolCalling = 'json',
    this.yolo = true,
    this.enhancedPrivacy = false,
    this.timeout = const Duration(minutes: 10),
    this.maxConsecutiveMistakes = 3,
    this.maxIterations = 40,
    this.maxActions = 32,
    this.maxNoProgressActions = 8,
    this.maxSearchesBeforeFirstEdit = 5,
    this.maxReadsBeforeFirstEdit = 8,
    this.maxInvestigationIterationsBeforeFirstEdit = 12,
  });

  final int localMaxTokens;
  final double localTemperature;
  final String localResponseFormat, localThinking, toolCalling;
  final bool yolo, enhancedPrivacy, writeAndRunTests;
  final Duration timeout;
  final int maxConsecutiveMistakes, maxIterations;
  final int maxActions, maxNoProgressActions;
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
  // Per-run navigation state: repository shape and task working area.
  bool _dotnetProject = false;
  String? _taskArea;
  Set<String> _forbiddenAreas = {};
  Map<String, List<String>> _areaRoots = const {};
  final Set<String> _strongMatchPaths = {};
  AgentRunOptions _generation = const AgentRunOptions();
  String _responseMode = 'json_object';
  Set<String>? _schemaActions;
  final Set<String> _missingReadPaths = {};
  final Set<String> _blockedActions = {};
  final Set<String> _exhaustedReadPaths = {};
  bool _nativeOllamaRecovery = false;
  bool _omitNativeThink = false;
  final Set<String> _blockedEditPaths = {};
  String? _newPathPattern;
  Map<String, dynamic> get _actionSchema => AgentGeneration.schemaFor(
    allowTests: _testingEnabled,
    allowedActions: _schemaActions,
    missingReadPaths: {..._missingReadPaths, ..._exhaustedReadPaths},
    blockedEditPaths: _blockedEditPaths,
    newPathPattern: _newPathPattern,
  );

  bool get _testingEnabled =>
      _generation.writeAndRunTests && commands.available && _privacy == null;
  AgentPrivacy? _privacy;
  int get _excerptLimit => _privacy != null
      ? 2000
      : _guarded
      ? 4000
      : maxExcerptCharacters;
  ModelClient? _active;
  bool _useNativeTools = false;
  bool get _guarded => profile.isLocal || _useNativeTools;
  bool _omitToolChoice = false;
  String _nativeTask = '';
  String _nativeRetainedNotes = '';
  NativeToolSession? _nativeSession;

  /// Set while a run is in flight so aborted runs still keep what they learned.
  Future<void> Function(Object error)? _flushMemoryOnFailure;
  bool _discardMemory = false;
  Future<void> _pendingMemoryWrite = Future.value();

  /// Prevent aborted runs from restoring memory after the user clears it.
  Future<void> discardConversation() async {
    _discardMemory = true;
    _flushMemoryOnFailure = null;
    stop();
    await _pendingMemoryWrite;
  }

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
- search_files ranks exact word/identifier matches first. Matches where the query is only part of a larger word (e.g. "logo" inside "logout") are listed last and are weak evidence — never edit a file based only on such a partial-word match.
- The task header names a working area when the task clearly targets one part of the repository. Stay inside that area unless file evidence points elsewhere.
- Refining a search with a narrower path or a more exact symbol is allowed when earlier results were partial-word matches only.
- Maximum 2 consecutive search_files calls since the last read/edit.
- When a search returns ≤4 plausible implementation files, READ THEM NEXT.
- Never repeat a search with the same/similar query under the same or overlapping path.
- Never repeat list_files for an unchanged directory. Empty results mean no files were found, not that a reference was inspected.
- Use exact indexed paths. For empty or missing paths, check similarly named indexed files, including accidental leading dots, before declaring a reference unavailable.
- Read the smallest useful context.
- If search results include line numbers, read ~40 lines around each match.
- Do not read files from line 1 unless the file structure is actually needed.
- Prefer 1-2 highly relevant files; use up to 4 only when necessary.
- If you already have the edit location, edit immediately.
- After editing, read the changed area once and finish.
- For reference-based tasks, read BOTH the reference and current implementation before editing. Verify all requested differences before finishing.
- Remembered claims of earlier completion are not proof that the current request is satisfied.
- Do not present a cosmetic partial edit as completion of a layout task. State unfinished work and concrete blockers explicitly.

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
- read_file: {"action":"read_file","path":"<existing-project-path>","startLine":optional,"lineCount":optional}
- read_files: {"action":"read_files","paths":["a.dart","b.dart"],"startLine":optional,"lineCount":optional}
- replace_in_file: {"action":"replace_in_file","path":"<existing-project-path>","oldText":"exact existing text","newText":"replacement text"}
- write_file: {"action":"write_file","path":"<existing-project-path>","content":"..."}
- mcp_call: {"action":"mcp_call","server":"name","tool":"tool_name","arguments":{}}
- finish: {"action":"finish","summary":"..."}
Relative paths only. Never touch .git or .tamtoot.
Reuse retained excerpts — do not re-read unchanged files.
''';

  static const testingPrompt = r'''
The user enabled Write and run tests on desktop. Add meaningful tests for the changed behavior and relevant edge cases; do not just mirror implementation.
Available action: {"action":"run_tests","executable":"flutter","args":["test"]}.
Other supported commands: dart test/analyze, flutter analyze, dotnet test/build, python3 -m pytest/unittest, pytest, npm/pnpm/yarn test, cargo test, go test, mvn test, ctest.
Choose the existing project test framework. Every command requires explicit approval, even in YOLO mode. No shell, pipes, redirects, installers or arbitrary scripts are available.
Use the project root as working directory. Run focused tests first; fix failures and run again after edits. A missing SDK is reported by the host; do not retry an unavailable runner forever.
Do not claim tests passed without an actual zero-exit command result. If denied or unavailable, report that limitation and finish honestly. Failed tests must be reported as failed, not successful verification.
''';

  static const localProtocol = r'''
You are a coding agent. Return exactly one JSON object in message.content.
No reasoning, plans, markdown or claimed tool results. Wait for the actual host result after each action.
Actions:
{"action":"list_files","path":""}
{"action":"search_files","query":"literal text","path":"optional/folder"}
search_files ranks exact word matches first; partial matches (query inside a larger word, e.g. "logo" in "logout") are weak evidence — never edit based only on them.
{"action":"read_file","path":"file","startLine":1,"lineCount":60}
{"action":"read_files","paths":["file1","file2"]}
{"action":"write_file","path":"file","content":"complete file text"}
{"action":"replace_in_file","path":"file","oldText":"unique current fragment","newText":"replacement"}
{"action":"mcp_call","server":"name","tool":"name","arguments":{}}
{"action":"say","text":"brief update"}
{"action":"finish","summary":"what was done and what was not tested"}
Only relative project paths; never .git or .tamtoot. No shell/build/test tool is available.
Read existing files before modifying them. New files may be written directly.
If the project index is empty, do not search/list it; write the requested files.
After a successful write do not repeat it: create the next missing file, read the changed files once, then finish.
Preserve unrelated code. Use small unique replace_in_file edits for existing files.
C# console projects need a .csproj and an entry point. Existing class libraries may have no Program.cs; inspect actual indexed files and never assume a filename exists. C# language version and .NET target version are distinct.
Never claim compilation/tests ran; file reads only check contents.
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
      'Investigation budget reached. Reuse loaded context.\n'
      'Edit only if the essential source and reference are available. '
      'Otherwise use the remaining targeted read for missing essential evidence; '
      'do not guess or make a token cosmetic edit.\n'
      'After the final targeted read, implement the requested change or finish '
      'with the precise blocker and unfinished work.\n'
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
    if (options.maxConsecutiveMistakes < 1 ||
        options.maxIterations < 1 ||
        options.maxActions < 1 ||
        options.maxNoProgressActions < 1) {
      throw const ModelApiException('Agent limits must be positive.');
    }
    if (options.localMaxTokens < 256 ||
        options.localMaxTokens > 32768 ||
        !options.localTemperature.isFinite ||
        options.localTemperature < 0 ||
        options.localTemperature > 2 ||
        !{
          'auto',
          'text',
          'json_object',
          'json_schema',
        }.contains(options.localResponseFormat) ||
        !{'off', 'on', 'default'}.contains(options.localThinking)) {
      throw const ModelApiException('Invalid local generation options.');
    }
    if (!{'auto', 'native', 'json'}.contains(options.toolCalling)) {
      throw const ModelApiException('Invalid tool-calling mode.');
    }
    _useNativeTools =
        options.toolCalling == 'native' &&
        {'ollama', 'chat-completions'}.contains(profile.apiFormat);
    _nativeSession = null;
    _nativeTask = task;
    _omitToolChoice = false;
    if (options.toolCalling == 'auto' &&
        profile.isOllama &&
        !options.enhancedPrivacy) {
      final probe =
          clientFactory?.call() ??
          ModelClient(timeout: const Duration(seconds: 5));
      _active = probe;
      try {
        _useNativeTools = await probe.supportsOllamaTools(
          profile,
          apiKey: apiKey,
        );
      } finally {
        _active = null;
      }
    }
    onEvent(
      AgentEvent(
        'protocol',
        '${profile.provider} / ${profile.model}: ${_useNativeTools ? 'native tools' : 'JSON actions'}',
      ),
    );
    _generation = options;
    _responseMode = options.localResponseFormat == 'auto'
        ? (profile.isOllama ? 'json_schema' : 'json_object')
        : options.localResponseFormat;
    _privacy = options.enhancedPrivacy ? AgentPrivacy() : null;
    if (_privacy != null) {
      try {
        _privacy!.prepareAttachments(attachments);
      } on FormatException catch (error) {
        throw ModelApiException(error.message);
      }
      onEvent(
        AgentEvent(
          'privacy',
          'Enhanced privacy: minimal context, masked hosts, one small file excerpt at a time.',
        ),
      );
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
      onEvent(AgentEvent('termination', _bounded(_firstLine('$error'), 240)));
      if (_stopped) {
        try {
          await _hook('TaskCancel', {'task': task});
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
    _missingReadPaths.clear();
    _blockedActions.clear();
    _blockedEditPaths.clear();
    _exhaustedReadPaths.clear();
    _nativeOllamaRecovery =
        _useNativeTools && options.toolCalling == 'auto' && profile.isOllama;
    _omitNativeThink = false;
    final observations = <String, String>{};
    final allPaths = _privacy == null ? await store.listFiles('') : <String>[];
    _dotnetProject = allPaths.any(
      (p) => p.endsWith('.csproj') || p.endsWith('.sln'),
    );
    final indexedPaths =
        (_privacy == null ? allPaths.where(_visible).toList() : <String>[])
          ..sort();
    _strongMatchPaths.clear();
    _taskArea = _privacy == null ? _detectTaskArea(task) : null;
    _forbiddenAreas = _forbiddenTaskAreas(task);
    _areaRoots = _privacy == null
        ? _buildAreaRoots(indexedPaths)
        : const <String, List<String>>{};
    final emptyProject = _privacy == null && indexedPaths.isEmpty;
    if (_privacy == null && !emptyProject) {
      if (_taskArea != null) {
        final roots = _areaRoots[_taskArea] ?? const <String>[];
        transcript.add(
          'Working area: $_taskArea. Prefer files under ${roots.isEmpty ? 'the matching top-level directories' : roots.join(', ')}. '
          'Do not edit files in other areas unless the task explicitly requires it or file evidence points there.',
        );
      } else {
        final summary = _areaSummary(indexedPaths);
        if (summary.isNotEmpty) {
          transcript.add(
            'Repository layout: $summary. Identify the area this task belongs to before searching, then stay inside it.',
          );
        }
      }
    }
    if (emptyProject) {
      transcript.add(
        'Project is empty at task start. Phase: implementation. Create files directly with write_file; do not search or list an empty project. For a C# console project create both Program.cs and a .csproj. C# 8 means LangVersion 8.0, not .NET 8. Use a compatible supported target, explicit Program.Main and no top-level statements. Verify created files with read_file/read_files. Never claim a build ran without a tool result.',
      );
    }
    final csharpScaffold =
        emptyProject &&
        RegExp(r'(c#|csharp|си.?шарп)', caseSensitive: false).hasMatch(task) &&
        RegExp(r'(project|прилож|проект)', caseSensitive: false).hasMatch(task);
    if (csharpScaffold) {
      transcript.add(
        'C# scaffold recipe: write Hello.csproj using a minimal SDK project, without XML namespaces, schemas or DOCTYPE: <Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><LangVersion>8.0</LangVersion></PropertyGroup></Project>. For C# 8 write Program.cs with using System; class Program { static void Main() { Console.WriteLine("Привет мир"); } }. Adapt the greeting to the task. Each file is a separate write_file action. Then read_files for both and finish. Do not claim compilation.',
      );
    }
    final requiredItems = AgentCompletion.requirementsFromTask(task);
    if (requiredItems.length > 1) {
      transcript.add(
        'Host requirement checklist: ${requiredItems.asMap().entries.map((e) => '[${e.key}] ${e.value}').join('; ')}',
      );
    }
    final listedDirectories = <String>{};
    if (_privacy == null) {
      _rememberObservation(
        observations,
        'Project index',
        await _projectIndex(indexedPaths),
      );
    }
    final memoryStore = ProjectMemoryStore(store);
    var projectMemory = _privacy == null
        ? await memoryStore.load()
        : ProjectMemory();
    final memorySelection = projectMemory.selectRelevant(task);
    final stalePaths = await _staleMemoryPaths(projectMemory, memorySelection);
    final memoryPrompt = projectMemory.formatForPrompt(
      memorySelection,
      stalePaths: stalePaths,
    );
    _nativeRetainedNotes = [
      memoryPrompt,
      if (promptHook.context.isNotEmpty) 'Hook context: ${promptHook.context}',
    ].where((s) => s.isNotEmpty).join('\n\n');
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
    var emptyToolTurns = 0;
    var consecutiveSays = 0;
    var consecutiveSearches = 0;
    var consecutiveBlockedReads = 0;
    var requireReadAfterSearch = false;
    var jsonMode = !profile.isLocal || options.localResponseFormat != 'text';
    String? repairHint;
    final completedSearches = <_CompletedSearch>[];
    final focusLinesByPath = <String, List<int>>{};
    var searchesBeforeEdit = 0;
    var filesReadBeforeEdit = 0;
    var hasEdited = false;
    var actionCount = 0;
    var noProgress = 0;
    var lastBlocker = '';
    final progressKeys = <String>{};
    final readCounts = <String, int>{};
    final blockedReadVersions = <String, String>{};
    final actionAttempts = <String, int>{};
    final repairExcerpts = <String, String>{};
    final repairUsed = <String>{};
    final verifiedEdits = <String>{};
    final verificationMarkers = <String, String>{};
    final editState = AgentEditState();
    final readContents = <String, String>{};
    final testsRequested =
        _testingEnabled ||
        RegExp(r'\btests?\b|тест', caseSensitive: false).hasMatch(task);
    final creationRequested =
        RegExp(
          r'create|scaffold|add|implement|new file|созда|добав|реализ|новый файл',
          caseSensitive: false,
        ).hasMatch(task) ||
        testsRequested;
    void checkRead(String path, String content, Map<String, dynamic> args) {
      if (!_guarded) return;
      final version = ProjectMemory.fingerprintText(content);
      final key =
          '$path:$version:${args['startLine'] ?? 0}:${args['lineCount'] ?? 0}';
      final count = (readCounts[key] ?? 0) + 1;
      if (count > 2) {
        throw const ModelApiException(
          'Unchanged file already read twice. Edit using loaded context or finish.',
        );
      }
      readCounts[key] = count;
      if (count == 2) {
        _exhaustedReadPaths.add(path);
        blockedReadVersions[path] = version;
      }
      // A different range can add context; an identical repeated read cannot.
      if (progressKeys.add('$key:${args['startLine']}:${args['lineCount']}')) {
        noProgress = 0;
      }
    }

    var finalReadUsed = false;
    var testsAttempted = false;
    var testVerification = '';
    int? testExitCode;
    if (_privacy == null) {
      await _seedBuildErrorContext(
        task: task,
        activeFiles: activeFiles,
        transcript: transcript,
        runReadPaths: runReadPaths,
        runFingerprints: runFingerprints,
        focusLinesByPath: focusLinesByPath,
      );
    }
    for (final entry in runFingerprints.entries) {
      editState.observedVersion(entry.key, entry.value);
    }
    final systemPrompt = [
      _privacy == null ? profile.systemPrompt : defaultSystemPrompt,
      _testingEnabled
          ? (profile.isLocal ? localProtocol : protocol)
                .replaceAll(
                  'No shell/build/test tool is available.',
                  'Only approved run_tests is available.',
                )
                .replaceAll(
                  'No shell/build/test tool is available',
                  'Only approved run_tests is available',
                )
                .replaceAll(
                  'mobile IDE: no terminal, builds, tests, or shell',
                  'desktop IDE with approved test execution',
                )
                .replaceAll(
                  'Never run or ask for runtime checks; verify by reading files and say so in the finish summary.',
                  'Run checks only through the approved run_tests action; report its actual result.',
                )
                .replaceAll(
                  'Never claim compilation/tests ran; file reads only check contents.',
                  'Only actual run_tests results can prove compilation or test outcomes.',
                )
          : (profile.isLocal ? localProtocol : protocol),
      if (_testingEnabled) testingPrompt,
      if (_privacy != null)
        'Enhanced privacy overrides context defaults: no project index, instructions or retained memory was supplied. Discover only the files needed for this task. Read one file at a time, at most 40 lines. Hosts are represented by private-*.invalid aliases; preserve aliases exactly in edits. Their real values are restored locally. Do not guess real hosts. MCP and hooks are disabled.',
      if (_privacy == null && mcp != null && mcp!.tools.isNotEmpty)
        'Available MCP tools:\n${mcp!.describe()}',
    ].join('\n\n');
    for (var iteration = 1; iteration <= options.maxIterations; iteration++) {
      if (_stopped) {
        throw const ModelApiException('Agent stopped.');
      }
      if (_guarded &&
          (actionCount >= options.maxActions ||
              noProgress >= options.maxNoProgressActions)) {
        final known = <String>{
          ..._strongMatchPaths,
          for (final search in completedSearches)
            ...search.hits.map((hit) => hit.path),
          ...memoryFiles,
        }.take(6);
        throw ModelApiException(
          'Agent stopped: no useful progress for $noProgress iterations '
          '(limit ${options.maxNoProgressActions}) after $actionCount actions. '
          'Goal: ${_bounded(_firstLine(task), 160)}. '
          '${lastBlocker.isEmpty ? 'No specific tool error was recorded. ' : 'Blocker: $lastBlocker '}'
          '${known.isEmpty ? '' : 'Most relevant known files: ${known.join(', ')}. '}'
          'Adjust the task or add detail and try again.',
        );
      }
      noProgress++;
      if (!hasEdited && noProgress >= 3 && (noProgress - 3) % 3 == 0) {
        // Stall recovery: restate goal, area and known files so the next
        // action is a concrete step instead of another blind attempt.
        final roots = _taskArea == null
            ? ''
            : ' Working area: $_taskArea (prefer ${_areaRoots[_taskArea]?.join(', ') ?? 'its files'}).';
        final known = <String>{
          ..._strongMatchPaths,
          for (final search in completedSearches)
            ...search.hits.map((hit) => hit.path),
          ...memoryFiles,
        }.take(6);
        _replaceNote(
          transcript,
          'Recovery:',
          'Recovery: $noProgress iterations without useful progress. '
              'Goal: ${_bounded(_firstLine(task), 160)}.$roots'
              '${known.isEmpty ? '' : ' Most relevant known files: ${known.join(', ')}.'} '
              '${lastBlocker.isEmpty ? '' : 'Last blocker: $lastBlocker '}'
              'Next iteration must be exactly one of: read_file on the most '
              'relevant listed file, replace_in_file from the loaded context, or '
              'finish stating the precise blocker.',
        );
      }
      onEvent(AgentEvent('iteration', 'Iteration $iteration'));
      for (final path in _exhaustedReadPaths.toList()) {
        if (await store.exists(path)) {
          final bytes = await store.readBytes(path);
          if (bytes.length <= 1024 * 1024) {
            final version = ProjectMemory.fingerprintText(utf8.decode(bytes));
            if (blockedReadVersions[path] != version) {
              _exhaustedReadPaths.remove(path);
            }
          }
        }
      }
      _schemaActions = null;
      _newPathPattern = null;
      if (emptyProject && profile.isLocal) {
        _schemaActions = AgentGeneration.actionNames
            .where((a) => a != 'list_files' && a != 'search_files')
            .toSet();
      }
      if (csharpScaffold && profile.isLocal) {
        final hasProject = indexedPaths.any((p) => p.endsWith('.csproj'));
        final hasProgram = indexedPaths.any((p) => p.endsWith('.cs'));
        if (!hasProject || !hasProgram) {
          _schemaActions = {'write_file'};
          _newPathPattern = !hasProject && !hasProgram
              ? r'^.+\.(csproj|cs)$'
              : !hasProject
              ? r'^.+\.csproj$'
              : r'^.+\.cs$';
        } else if (runEditedPaths.any((path) => !runReadPaths.contains(path))) {
          _schemaActions = {'read_files', 'read_file'};
        } else if (_testingEnabled && !testsAttempted) {
          _schemaActions = {'run_tests', 'write_file', 'replace_in_file'};
        } else {
          _schemaActions = {'finish', 'replace_in_file'};
        }
        _replaceNote(
          transcript,
          'Scaffold status:',
          'Scaffold status: ${hasProject ? 'csproj exists; do not rewrite it.' : 'Create the .csproj.'} ${hasProgram ? 'C# source exists.' : 'Create Program.cs.'} ${hasProject && hasProgram ? 'Read both files, then follow the requested verification workflow.' : 'Create the missing file next.'}',
        );
      }

      if (_guarded) {
        _schemaActions ??= AgentGeneration.actionNames.toSet();
        _schemaActions!.removeAll(_blockedActions);
        if (_privacy != null || mcp == null || mcp!.tools.isEmpty) {
          _schemaActions!.remove('mcp_call');
        }
        if (!creationRequested && !emptyProject) {
          _schemaActions!.remove('write_file');
        }
        if (requireReadAfterSearch ||
            consecutiveSearches >= 2 ||
            runEditedPaths.any((p) => !verifiedEdits.contains(p))) {
          _schemaActions!.removeAll({'search_files', 'list_files'});
        }
        if (listedDirectories.isNotEmpty) _schemaActions!.remove('list_files');
        if (hasEdited) _schemaActions!.remove('say');
      }

      final budgetReached =
          !hasEdited &&
          _investigationExhausted(
            searches: searchesBeforeEdit,
            filesRead: filesReadBeforeEdit,
            iteration: iteration,
            options: options,
          );
      if (_guarded && budgetReached) {
        _schemaActions!.removeAll({'search_files', 'list_files'});
        if (finalReadUsed) {
          _schemaActions!.removeAll({'read_file', 'read_files'});
        }
      }
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
          emptyProject || hasEdited || budgetReached || activeFiles.isNotEmpty;
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
      NativeToolInvocation? invocation;
      var naturalFinal = false;
      if (_useNativeTools && (_nativeSession?.pending.isNotEmpty ?? false)) {
        invocation = _nativeSession!.pending.removeAt(0);
        reply = const ModelReply('');
      } else {
        try {
          reply = await _requestAction(
            options: options,
            maxTokens: implementationPhase
                ? agentEditTokens
                : agentActionTokens,
            jsonMode: jsonMode,
            systemPrompt: repairHint == null
                ? systemPrompt
                : 'Return exactly one valid JSON action in message.content. No explanation.\n${profile.isLocal ? localProtocol : protocol}\n${_testingEnabled ? testingPrompt : ''}',
            userPrompt: repairHint == null
                ? _buildPrompt(
                    transcript,
                    activeFiles,
                    observations,
                    memoryPrompt,
                    compactedContext,
                  )
                : 'Task: ${_bounded(task, 2000)}\n$repairHint\nKnown paths: ${indexedPaths.take(12).join(', ')}\nCurrent exact excerpts:\n${activeFiles.entries.toList().reversed.take(2).map((e) => '${e.key}:\n${e.value}').join('\n\n')}\nEmit one complete small JSON action. Never invent tool results.',
            attachments: iteration == 1 ? attachments : const [],
            // Empty content is answered by a tiny request instead of a full
            // agent turn: bounded exact excerpts, no transcript or reasoning echo.
            onEmptyAnswer: (failure) {
              return _recoveryRequest(
                options: options,
                failure: failure,
                jsonMode: jsonMode,
                implementationPhase: implementationPhase,
                task: task,
                currentExcerpts: activeFiles,
                knownFiles: _knownRelevantFiles(
                  activeFiles: activeFiles,
                  searches: completedSearches,
                  memoryFiles: memoryFiles,
                ),
              );
            },
          );
          repairHint = null;
        } on ModelApiException catch (e) {
          if (_useNativeTools &&
              {400, 422}.contains(e.statusCode) &&
              RegExp(
                r'(?:does not support|not support|unsupported|not supported|unknown|unexpected|unrecognized).*(?:tools?|functions?)|(?:tools?|functions?).*(?:does not support|not support|unsupported|not supported|unrecognized)',
                caseSensitive: false,
              ).hasMatch(e.message)) {
            _useNativeTools = false;
            _nativeSession = null;
            _nativeOllamaRecovery = false;
            onEvent(
              AgentEvent(
                'protocol',
                'Provider rejected native tools; falling back to JSON actions.',
              ),
            );
            continue;
          }
          if (e.message.startsWith('Native protocol stopped')) rethrow;
          if (jsonMode &&
              (ModelClient.rejectedJsonObjectMode(e.message) ||
                  (profile.isLocal &&
                      e.statusCode == 400 &&
                      e.message.contains('format')))) {
            if (_guarded && _responseMode == 'json_schema') {
              _responseMode = 'json_object';
              onEvent(
                AgentEvent(
                  'context',
                  'Provider rejected JSON Schema; trying JSON Object mode',
                ),
              );
              continue;
            }
            jsonMode = false;
            onEvent(
              AgentEvent('context', 'Provider rejected JSON mode; disabled it'),
            );
            continue;
          }
          if (e is ModelEmptyAnswerException ||
              e.message.startsWith('Model still returned empty content') ||
              e.message.startsWith('Model recovery failed') ||
              {401, 403, 404, 405}.contains(e.statusCode)) {
            onEvent(AgentEvent('error', e.message));
            rethrow;
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
        if (_useNativeTools) {
          _nativeSession!.accept(reply);
          if (_nativeSession!.pending.isNotEmpty) {
            emptyToolTurns = 0;
            invocation = _nativeSession!.pending.removeAt(0);
          } else {
            emptyToolTurns++;
            final modificationTask = RegExp(
              r'add|create|implement|fix|change|добав|созда|исправ|измени',
              caseSensitive: false,
            ).hasMatch(task);
            naturalFinal =
                reply.text.trim().isNotEmpty &&
                repairExcerpts.isEmpty &&
                ((hasEdited && runEditedPaths.every(verifiedEdits.contains)) ||
                    (!modificationTask && runReadPaths.isNotEmpty));
            if (emptyToolTurns >= 2 && !naturalFinal) {
              throw const ModelApiException(
                'Native protocol stopped: model returned no tool calls twice; task was not completed.',
              );
            }
            if (!naturalFinal) _nativeSession!.requestExplicitTool();
          }
        }
      }
      onEvent(
        AgentEvent(
          'model',
          '${_useNativeTools ? 'Native' : 'JSON'} response: ${reply.text.length} text characters, ${reply.toolCalls.length} tool calls',
          data: {
            'endpoint': _agentRequestProfile(
              maxTokens: agentEditTokens,
              jsonMode: jsonMode,
            ).requestUri().toString(),
            'apiFormat': _nativeOllamaRecovery ? 'ollama' : profile.apiFormat,
            'request': {
              'model': profile.model,
              'protocol': _useNativeTools ? 'native' : 'json',
              if (_useNativeTools)
                'tools': AgentGeneration.nativeTools(
                  _actionSchema,
                ).map((t) => t['function']['name']).toList(),
            },
            'response': {
              'characters': reply.text.length,
              'tool_calls': reply.toolCalls.length,
              if (reply.usage.isNotEmpty) 'usage': reply.usage,
            },
          },
        ),
      );
      if (reply.usage.isNotEmpty) {
        onEvent(AgentEvent('usage', jsonEncode(reply.usage)));
      }
      if (invocation != null) {
        onEvent(
          AgentEvent(
            'tool_call',
            '${invocation.call.name} [${invocation.id}] requested',
          ),
        );
      }
      late final Map<String, dynamic> action;
      late final String name;
      final beforeTranscript = transcript.length;
      final beforeObservations = Map<String, String>.of(observations);
      String? toolFailure;
      var toolCompleted = false;
      try {
        if (invocation != null) {
          action = invocation.call.action();
        } else if (_useNativeTools && naturalFinal) {
          action = {'action': 'finish', 'summary': reply.text};
        } else if (_useNativeTools) {
          action = {
            'action': 'say',
            'text':
                'No tool calls returned. Requested an explicit tool or finish.',
          };
        } else {
          var objects = _extractJsonObjects(reply.text);
          if (profile.isLocal) {
            final source = reply.text
                .trim()
                .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
                .replaceFirst(RegExp(r'\s*```$'), '');
            try {
              final decoded = jsonDecode(source);
              if (decoded is! Map<String, dynamic>) {
                throw const FormatException();
              }
            } on FormatException {
              throw ModelApiException(
                _looksTruncated(source, reply.note)
                    ? 'Model output was truncated; emit a smaller complete JSON action.'
                    : 'Model returned an invalid agent action: exactly one JSON object is required.',
              );
            }
            objects = [source];
          }
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
        }
        AgentGeneration.validate(action);
        if (_guarded &&
            _schemaActions != null &&
            !_schemaActions!.contains(action['action'])) {
          throw ModelApiException(
            'Model returned an invalid agent action for the current phase. Allowed next actions: ${_schemaActions!.join(', ')}.',
          );
        }
        if (_guarded &&
            action['action'] == 'write_file' &&
            _newPathPattern != null &&
            !RegExp(_newPathPattern!).hasMatch(action['path'] as String)) {
          throw const ModelApiException(
            'Model returned an invalid agent action: create the missing project file instead of overwriting an existing one.',
          );
        }

        if (emptyProject &&
            !hasEdited &&
            {'list_files', 'search_files'}.contains(action['action'])) {
          throw const ModelApiException(
            'Project index is empty. Do not search/list again; create the requested files with write_file or finish if no edits are needed.',
          );
        }
        name = action['action'] as String;
        final actionKey =
            '${jsonEncode(_canonicalAction(action))}:${{'search_files', 'list_files'}.contains(name) ? jsonEncode(_canonicalAction(runFingerprints)) : runFingerprints[action['path']] ?? ''}';
        actionCount++;
        if (_guarded &&
            name != 'read_file' &&
            name != 'read_files' &&
            name != 'finish') {
          final attempts = (actionAttempts[actionKey] ?? 0) + 1;
          actionAttempts[actionKey] = attempts;
          if (attempts > 2) {
            throw const ModelApiException(
              'Repeated identical action without a new file version. Edit using existing context or finish.',
            );
          }
        }
        if (_guarded && (name == 'write_file' || name == 'replace_in_file')) {
          final path = _path(action['path']);
          if (_blockedEditPaths.contains(path)) {
            throw const ModelApiException(
              'Replacement retry exhausted. No more edits to this file are permitted in this run.',
            );
          }
          if (RegExp(
            r'(^|/)relative/(file|results\.txt)(/|$)|^actual/project/path$|[<>]',
          ).hasMatch(path)) {
            throw const ModelApiException(
              'Template placeholder paths cannot be written. Use the actual task file.',
            );
          }
          if (name == 'write_file' &&
              !await store.exists(path) &&
              !task.contains(path) &&
              !(emptyProject && creationRequested) &&
              !(creationRequested &&
                  _featurePathMatchesTask(task, path) &&
                  (_taskArea == null || _areaForPath(path) == _taskArea)) &&
              !(testsRequested &&
                  RegExp(
                    r'(^|/)(test|tests)/|(_test|\.test|\.spec)\.',
                  ).hasMatch(path))) {
            throw const ModelApiException(
              'Creating unrelated files is not authorized by this task.',
            );
          }
        }
        if (name == 'replace_in_file' || name == 'write_file') {
          _assertCompactEditPayload(name, action);
        }
        int? readLineBudget = options.enhancedPrivacy
            ? 40
            : _guarded
            ? 60
            : null;
        var readFileBudget = options.enhancedPrivacy
            ? 1
            : _guarded
            ? 2
            : 4;
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
          readLineBudget = options.enhancedPrivacy ? 40 : maxFinalReadLines;
          readFileBudget = options.enhancedPrivacy ? 1 : maxFinalReadFiles;
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
            if (!listedDirectories.add(path)) {
              throw ModelApiException(
                'Directory ${path.isEmpty ? '.' : path} was already listed. '
                'Reuse its result. Read an exact indexed file instead of repeating list_files.',
              );
            }
            final files = await store.listFiles(path);
            final visible = files
                .where(_visible)
                .take(
                  _privacy != null
                      ? 20
                      : profile.isLocal
                      ? 40
                      : 120,
                )
                .join('\n');
            final hint = path.replaceFirst(RegExp(r'^\.+/?'), '');
            final alternatives = visible.isEmpty && hint.isNotEmpty
                ? indexedPaths
                      .where((p) => p.startsWith('$hint/') || p == hint)
                      .take(12)
                      .join('\n')
                : '';
            onEvent(AgentEvent('tool', 'Listed ${path.isEmpty ? '.' : path}'));
            _rememberObservation(
              observations,
              'List ${path.isEmpty ? '.' : path}',
              'Tool list_files result for ${path.isEmpty ? '.' : path}:\n'
                  '${visible.isEmpty ? 'No files found. The directory may be empty or missing.' : visible}'
                  '${alternatives.isEmpty ? '' : '\nSimilarly named indexed files (use these exact paths):\n$alternatives'}',
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
                'Search rejected: "$query" was already searched with '
                    'relevant results.\n'
                    '${_formatKnownMatches(duplicate)}\n'
                    'Read the relevant area, edit it, or refine with an exact '
                    'symbol under a different path.',
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
            final outcome = await _runSearch(query, path);
            final result = outcome.text;
            final hits = outcome.hits;
            _strongMatchPaths.addAll(outcome.strongPaths);
            final completed = _CompletedSearch(
              query: query,
              path: path,
              result: result,
              hits: hits,
              relevant: outcome.hasRelevantHit,
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
            if (!outcome.hasRelevantHit && hits.isNotEmpty) {
              // Partial-word matches (e.g. "logo" inside "logout") are weak
              // evidence: force refinement instead of reading/editing them.
              _replaceNote(
                transcript,
                'Host note:',
                'Host note: "$query" has no exact word matches — only partial-'
                    'word matches inside larger words. Do NOT read or edit those '
                    'files on this evidence alone. Refine the query to an exact '
                    'symbol, or repeat the search with a narrower path (staying in '
                    'the working area).',
              );
            } else {
              // Only exact-word and path matches count as "implementation
              // files to read next"; partial-word hits (e.g. "logout") must not
              // be pushed as read targets.
              final implementationPaths = hits
                  .where(
                    (hit) =>
                        outcome.strongPaths.contains(hit.path) ||
                        hit.line == null,
                  )
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
            }
            searchesBeforeEdit++;
          case 'read_file':
            consecutiveSays = 0;
            consecutiveSearches = 0;
            requireReadAfterSearch = false;
            final path = _path(action['path']);
            if (await _isDirectoryPath(path)) {
              throw ModelApiException(
                '"$path" is a directory, not a file. Use list_files on '
                '"$path" to see its contents, then read_file an exact file.',
              );
            }
            if (!await store.exists(path)) {
              await _reportMissingRead(path, observations);
              toolFailure = 'File does not exist: $path';
              break;
            }
            _missingReadPaths.remove(path);
            final bytes = await store.readBytes(path);
            if (bytes.length > 1024 * 1024) {
              throw const ModelApiException(
                'File exceeds the 1 MiB agent limit.',
              );
            }
            final content = utf8.decode(bytes);
            checkRead(path, content, action);
            editState.read(path, content);
            readContents[path] = content;
            final excerpt = _fileExcerpt(
              path,
              content,
              action,
              focusLines: focusLinesByPath[path],
              maxLines: readLineBudget,
            );
            if (runEditedPaths.contains(path) &&
                excerpt.content.contains(verificationMarkers[path] ?? '') &&
                ProjectMemory.fingerprintText(content) ==
                    runFingerprints[path]) {
              verifiedEdits.add(path);
            }
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
              if (await _isDirectoryPath(path)) {
                throw ModelApiException(
                  '"$path" is a directory, not a file. Use list_files on '
                  '"$path" to see its contents, then read_file an exact file.',
                );
              }
              if (!await store.exists(path)) {
                await _reportMissingRead(path, observations);
                toolFailure =
                    'Some requested files do not exist, including $path';
                continue;
              }
              _missingReadPaths.remove(path);
              final bytes = await store.readBytes(path);
              if (bytes.length > 1024 * 1024) {
                throw ModelApiException(
                  'File exceeds the 1 MiB agent limit: $path',
                );
              }
              final content = utf8.decode(bytes);
              checkRead(path, content, action);
              editState.read(path, content);
              readContents[path] = content;
              final excerpt = _fileExcerpt(
                path,
                content,
                action,
                focusLines: focusLinesByPath[path],
                maxLines: readLineBudget,
              );
              if (runEditedPaths.contains(path) &&
                  excerpt.content.contains(verificationMarkers[path] ?? '') &&
                  ProjectMemory.fingerprintText(content) ==
                      runFingerprints[path]) {
                verifiedEdits.add(path);
              }
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
                'Read ${descriptions.length} files: ${descriptions.join('; ')}',
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
            if (_guarded && !runReadPaths.contains(path)) {
              throw const ModelApiException(
                'Read the target file before replacing its contents.',
              );
            }
            final oldText = _string(action, 'oldText');
            final newText = action['newText'];
            if (newText is! String) {
              throw const ModelApiException('Agent action is missing newText.');
            }
            final outsideScope = _outsideTaskScope(path);
            final allowed =
                (options.yolo && !outsideScope) ||
                await approve('replace_in_file', action);
            if (!allowed) {
              transcript.add(
                'Tool replace_in_file denied by the user. Choose another action or explain.',
              );
              onEvent(AgentEvent('denied', 'Edit denied: $path'));
              continue;
            }
            if (outsideScope) {
              transcript.add(
                'Scope note: $path is outside the $_taskArea working area and was edited only after user confirmation.',
              );
            }
            final content = await store.readText(path);
            if (profile.isLocal || _useNativeTools) {
              editState.validateRead(path, content);
            }
            if (oldText == newText) {
              throw const ModelApiException(
                'Replacement makes no change. Finish or provide a real edit.',
              );
            }
            if (repairExcerpts.containsKey(path)) {
              if (repairUsed.contains(path)) {
                throw const ModelApiException(
                  'Replacement retry exhausted for this file. Finish and report the unresolved edit.',
                );
              }
              repairUsed.add(path);
              _blockedEditPaths.add(path);
              if (!repairExcerpts[path]!.contains(oldText)) {
                throw const ModelApiException(
                  'Retry must copy an exact fragment from the verified repair excerpt.',
                );
              }
            }
            final first = content.indexOf(oldText);
            if (first < 0) {
              final excerpt = _fileExcerpt(path, content, {
                'startLine': _repairStartLine(
                  content,
                  oldText,
                  focusLinesByPath[path]?.firstOrNull,
                ),
                'lineCount': 40,
              }, maxLines: 40);
              repairExcerpts[path] = excerpt.content;
              editState.read(path, content);
              readContents[path] = content;
              _rememberFile(
                activeFiles,
                excerpt.key,
                excerpt.content,
                transcript,
              );
              onEvent(
                AgentEvent(
                  'tool',
                  'Replacement failed; refreshed ${excerpt.description}',
                ),
              );
              throw const ModelApiException(
                'oldText was not found. Current minimal excerpt is in Active file context. Copy its exact unique fragment; only one replacement retry is allowed.',
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
            if (profile.isLocal || _useNativeTools) {
              editState.validate(path, content, updated);
            }
            if (_guarded) {
              editState.validateRead(path, await store.readText(path));
            }
            await store.writeText(path, updated);
            editState.wrote(path, updated);
            final changedLine =
                '\n'.allMatches(updated.substring(0, first)).length + 1;
            focusLinesByPath[path] = [changedLine];
            verificationMarkers[path] = newText.isNotEmpty
                ? newText.substring(0, newText.length.clamp(0, 120))
                : updated.substring(
                    first,
                    (first + 80).clamp(first, updated.length),
                  );
            repairExcerpts.remove(path);
            repairUsed.remove(path);
            _blockedEditPaths.remove(path);
            activeFiles.removeWhere(
              (key, _) => key == path || key.startsWith('$path ['),
            );
            onEvent(
              AgentEvent('tool', 'Edited $path', data: {'changedPath': path}),
            );
            runEditedPaths.add(path);
            runFingerprints[path] = ProjectMemory.fingerprintText(updated);
            transcript.add(
              'Tool replace_in_file result: edited $path successfully. Read the changed area before finishing.',
            );
            hasEdited = true;
            verifiedEdits.remove(path);
            _exhaustedReadPaths.remove(path);
            _blockedActions.clear();
            if (_guarded) {
              completedSearches.removeWhere(
                (search) =>
                    search.path.isEmpty ||
                    path == search.path ||
                    path.startsWith('${search.path}/'),
              );
            }
            noProgress = 0;
            testsAttempted = false;
            listedDirectories.clear();
          case 'write_file':
            consecutiveSays = 0;
            consecutiveSearches = 0;
            final path = _path(action['path']);
            final content = _string(action, 'content');
            if ((profile.isLocal || _useNativeTools) &&
                await store.exists(path)) {
              final current = await store.readText(path);
              if (current == content) {
                throw const ModelApiException(
                  'File already has this content. Verify or finish.',
                );
              }
              editState.validate(path, current, content);
            }
            if (utf8.encode(content).length > 1024 * 1024) {
              throw const ModelApiException(
                'Write exceeds the 1 MiB agent limit.',
              );
            }
            final outsideScope = _outsideTaskScope(path);
            final allowed =
                (options.yolo && !outsideScope) ||
                await approve('write_file', action);
            if (!allowed) {
              transcript.add(
                'Tool write_file denied by the user. Choose another action or explain.',
              );
              onEvent(AgentEvent('denied', 'Write denied: $path'));
              continue;
            }
            if (outsideScope) {
              transcript.add(
                'Scope note: $path is outside the $_taskArea working area and was written only after user confirmation.',
              );
            }
            await store.validateRegularFilePath(path);
            if (_guarded && await store.exists(path)) {
              editState.validate(path, await store.readText(path), content);
            }
            await store.writeText(path, content);
            editState.wrote(path, content);
            verificationMarkers[path] = content.substring(
              0,
              content.length.clamp(0, 120),
            );
            focusLinesByPath[path] = [1];
            _missingReadPaths.remove(path);
            observations.remove('Missing file $path');
            activeFiles.removeWhere(
              (key, _) => key == path || key.startsWith('$path ['),
            );
            onEvent(
              AgentEvent('tool', 'Wrote $path', data: {'changedPath': path}),
            );
            runEditedPaths.add(path);
            if (!indexedPaths.contains(path)) {
              indexedPaths.add(path);
              indexedPaths.sort();
            }
            if (_privacy == null) {
              observations['Project index'] =
                  'Known project files after edits: ${indexedPaths.take(80).join(', ')}';
            }
            runFingerprints[path] = ProjectMemory.fingerprintText(content);
            transcript.add(
              'Tool write_file result: wrote $path successfully. Inspect it before finishing.',
            );
            hasEdited = true;
            verifiedEdits.remove(path);
            _exhaustedReadPaths.remove(path);
            _blockedActions.clear();
            if (_guarded) {
              completedSearches.removeWhere(
                (search) =>
                    search.path.isEmpty ||
                    path == search.path ||
                    path.startsWith('${search.path}/'),
              );
            }
            noProgress = 0;
            testsAttempted = false;
            listedDirectories.clear();
          case 'run_tests':
            if (!_testingEnabled) {
              throw const ModelApiException(
                'Test execution is disabled. Enable Write and run tests in a desktop local workspace.',
              );
            }
            final executable = _string(action, 'executable');
            final arguments = (action['args'] as List).cast<String>();
            validateAgentTestCommand(executable, arguments);
            if (!await approve('run_tests', action)) {
              testsAttempted = true;
              testExitCode = null;
              testVerification =
                  'Tests were not run: the user denied command execution.';
              toolFailure = testVerification;
              transcript.add(testVerification);
              onEvent(AgentEvent('denied', testVerification));
              break;
            }
            final result = await commands.runTests(executable, arguments);
            testsAttempted = true;
            testExitCode = result.exitCode;
            if (result.exitCode != 0) {
              toolFailure =
                  'Verification command exited with code ${result.exitCode}.';
            }
            testVerification = result.exitCode == 127
                ? 'Tests were not run: $executable is unavailable.'
                : 'Verification: $executable ${arguments.join(' ')} exited with code ${result.exitCode}.';
            onEvent(
              AgentEvent(
                'tool',
                testVerification,
                data: {
                  'exitCode': result.exitCode,
                  'output': _bounded(result.output, 12000),
                },
              ),
            );
            _rememberObservation(
              observations,
              'Test result',
              '$testVerification\n${_bounded(result.output, 12000)}',
            );
            transcript.add(
              '$testVerification Fix failures if possible; otherwise report the limitation honestly.',
            );
            break;
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
            if (_privacy != null) {
              throw const ModelApiException(
                'MCP calls are disabled in enhanced privacy mode.',
              );
            }
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
            final unresolved = action['unresolved'] is List
                ? (action['unresolved'] as List)
                      .whereType<String>()
                      .where((s) => s.trim().isNotEmpty)
                      .toList()
                : <String>[];
            if (_useNativeTools &&
                unresolved.isEmpty &&
                requiredItems.length > 1) {
              final proofs = action['requirements'];
              if (proofs is! List) {
                throw const ModelApiException(
                  'Task incomplete: provide source evidence for every numbered requirement in finish.requirements.',
                );
              }
              final seen = <int>{};
              for (final proof in proofs) {
                if (proof is! Map ||
                    proof['id'] is! int ||
                    proof['path'] is! String ||
                    proof['excerpt'] is! String) {
                  throw const ModelApiException(
                    'Requirement evidence needs id, path and exact excerpt.',
                  );
                }
                final id = proof['id'] as int;
                final path = _path(proof['path']);
                final excerpt = proof['excerpt'] as String;
                if (id < 0 ||
                    id >= requiredItems.length ||
                    !seen.add(id) ||
                    !runReadPaths.contains(path) ||
                    excerpt.trim().length < 8) {
                  throw const ModelApiException(
                    'Invalid, duplicate or unread requirement evidence.',
                  );
                }
                final current = await store.readText(path);
                if (!current.contains(excerpt) ||
                    runFingerprints[path] !=
                        ProjectMemory.fingerprintText(current)) {
                  throw const ModelApiException(
                    'Requirement evidence is missing or stale. Read the actual current source.',
                  );
                }
              }
              if (seen.length != requiredItems.length) {
                throw const ModelApiException(
                  'Task incomplete: not all numbered requirements have verified source evidence.',
                );
              }
              onEvent(
                AgentEvent(
                  'completion',
                  'Verified source evidence for ${seen.length} task requirements.',
                ),
              );
            }
            if (unresolved.isEmpty && AgentCompletion.isHelpPageTask(task)) {
              final current = <String, String>{...readContents};
              for (final path in runEditedPaths) {
                current[path] = await store.readText(path);
              }
              final checks = AgentCompletion.helpChecks(
                current,
                runEditedPaths,
              );
              final missing = checks.entries
                  .where((e) => !e.value)
                  .map((e) => e.key)
                  .toList();
              onEvent(
                AgentEvent(
                  'completion',
                  'Help-page checks: ${checks.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
                ),
              );
              if (missing.isNotEmpty) {
                throw ModelApiException(
                  'Task incomplete: ${missing.join(', ')}. A menu selection alone is not a Help page. Implement the missing requirements or finish with an explicit unresolved list.',
                );
              }
            }
            if (_useNativeTools &&
                unresolved.isEmpty &&
                runEditedPaths.isEmpty &&
                RegExp(
                  r'add|create|implement|fix|change|добав|созда|исправ|измени',
                  caseSensitive: false,
                ).hasMatch(task)) {
              throw const ModelApiException(
                'Task incomplete: no file changes were executed. Implement the requested work or report unresolved requirements.',
              );
            }
            if (_nativeSession?.pending.isNotEmpty ?? false) {
              throw const ModelApiException(
                'finish must follow all tool calls, not precede them.',
              );
            }
            if ((profile.isLocal || _useNativeTools) &&
                unresolved.isEmpty &&
                runEditedPaths.any((p) => !verifiedEdits.contains(p))) {
              throw const ModelApiException(
                'Read the changed area to verify each edited file before finish.',
              );
            }
            if ((_useNativeTools || profile.isLocal) && unresolved.isEmpty) {
              for (final path in runEditedPaths) {
                final current = await store.readBytes(path);
                if (ProjectMemory.fingerprintBytes(current) !=
                    runFingerprints[path]) {
                  verifiedEdits.remove(path);
                  throw ModelApiException(
                    'Edited file changed after verification: $path. Read its current contents before finish.',
                  );
                }
              }
            }
            if (_testingEnabled && hasEdited && !testsAttempted) {
              throw const ModelApiException(
                'Testing was requested: write meaningful tests and request run_tests before finish. If its SDK is missing, report the actual unavailable-runner result.',
              );
            }
            if (csharpScaffold && profile.isLocal) {
              final files = await store.listFiles('');
              if (!files.any((p) => p.endsWith('.csproj')) ||
                  !files.any((p) => p.endsWith('.cs'))) {
                throw const ModelApiException(
                  'C# application is incomplete: create a .csproj and Program.cs before finish. C# 8 requires LangVersion 8.0, not a .NET 8 assumption.',
                );
              }
              if (runEditedPaths.any((p) => !runReadPaths.contains(p))) {
                throw const ModelApiException(
                  'Read the created project files to verify their contents before finish. No build has been run.',
                );
              }
            }
            final summary =
                '${_string(action, 'summary')}${unresolved.isEmpty ? '' : '\nUnresolved: ${unresolved.join('; ')}'}${testVerification.isEmpty ? '' : '\n\n$testVerification'}${repairExcerpts.isEmpty ? '' : '\n\nUnresolved replacements: ${repairExcerpts.keys.join(', ')}. The failed replacements were not applied.'}';
            _flushMemoryOnFailure = null;
            await _persistProjectMemory(
              memoryStore: memoryStore,
              memory: projectMemory,
              task: task,
              summary: unresolved.isEmpty && repairExcerpts.isEmpty
                  ? summary
                  : '',
              unresolved: [
                ...unresolved,
                for (final path in repairExcerpts.keys)
                  'Replacement unresolved: $path',
              ],
              readPaths: runReadPaths,
              editedPaths: runEditedPaths,
              fingerprints: runFingerprints,
              learned: runLearned,
            );
            toolCompleted = true;
            onEvent(AgentEvent('done', summary));
            return AgentRunResult(
              success:
                  unresolved.isEmpty &&
                  repairExcerpts.isEmpty &&
                  (testExitCode == null ||
                      testExitCode == 0 ||
                      testExitCode == 127),
              message: summary,
              iterations: iteration,
            );
          default:
            throw ModelApiException('Unknown agent action: $name');
        }
        toolCompleted = toolFailure == null;
        if (name != 'say' && name != 'finish') {
          final post = await _hook('PostToolUse', {
            'toolName': name,
            'parameters': action,
            'success': toolCompleted,
          });
          if (post.context.isNotEmpty) {
            transcript.add('Hook context:\n${post.context}');
          }
        }
        if (_guarded &&
            !{'say', 'read_file', 'read_files'}.contains(name) &&
            progressKeys.add(actionKey)) {
          noProgress = 0;
        }
        mistakes = 0;
      } catch (e) {
        toolCompleted = false;
        mistakes++;
        final message = e is ModelApiException
            ? e.message
            : e is FormatException
            ? 'Malformed tool/action arguments: ${e.message}'
            : '$e';
        toolFailure = message;
        if (_useNativeTools && invocation == null) {
          _nativeSession?.hostNote(
            'Final response/action rejected by host: $message',
          );
        }
        lastBlocker = _bounded(_firstLine(message), 200);
        if (e is FormatException ||
            message.contains('invalid agent action') ||
            message.contains('truncated')) {
          repairHint = 'Previous action was invalid or truncated. $message';
        }
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
      } finally {
        if (invocation != null) {
          final requested = <String>{};
          try {
            final args = invocation.call.action();
            if (args['path'] is String) requested.add(args['path'] as String);
            if (args['paths'] is List) {
              requested.addAll((args['paths'] as List).whereType<String>());
            }
          } catch (_) {}
          final result = <String, dynamic>{
            'ok': toolCompleted,
            'tool': invocation.call.name,
            'paths': requested.take(4).toList(),
            if (toolFailure != null) 'error': _bounded(toolFailure, 1200),
            'result': [
              for (final entry in observations.entries)
                if (beforeObservations[entry.key] != entry.value)
                  _bounded(entry.value, 2200),
              for (final entry in activeFiles.entries)
                if ({
                      'read_file',
                      'read_files',
                    }.contains(invocation.call.name) &&
                    requested.any(
                      (p) =>
                          entry.key == p || entry.key.startsWith('$p [lines '),
                    ))
                  '${entry.key}:\n${entry.value}',
              ...transcript
                  .skip(beforeTranscript)
                  .map((item) => _bounded(item, 1200)),
            ].join('\n'),
          };
          result['result'] = _bounded(result['result'] as String, 10000);
          if (!toolCompleted && toolFailure == null) {
            result['error'] =
                'Operation was blocked or denied; no successful execution was reported.';
          }
          _nativeSession!.result(invocation, jsonEncode(result));
          onEvent(
            AgentEvent(
              'tool_result',
              '${invocation.call.name} [${invocation.id}]: ${toolCompleted ? 'completed' : 'failed/blocked'}',
            ),
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
      try {
        return await onEmptyAnswer(e);
      } on ModelEmptyAnswerException {
        rethrow;
      } on ModelApiException catch (failure) {
        throw ModelApiException(
          'Model recovery failed: ${failure.message}',
          statusCode: failure.statusCode,
        );
      }
    }
  }

  Future<ModelReply> _send({
    bool recovery = false,
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
    if (_useNativeTools) {
      _nativeSession ??= NativeToolSession(
        '${_privacy == null ? profile.systemPrompt : defaultSystemPrompt}\nUse the provided tools for all actions. Never emit JSON actions in message.content. Never invent tool results. Read current files before editing, preserve unrelated code and use small exact replacements. After edits read the changed area. Call finish explicitly with actual results and blockers. For numbered task requirements, include requirements evidence (id, path, exact excerpt) in finish; do not mark an unimplemented requirement complete. Stay within the task working area.\n${_privacy == null ? '' : 'Enhanced privacy: preserve masked aliases exactly, read one file with at most 40 lines, do not guess original hosts, and do not use MCP or commands.'}\n${_testingEnabled ? testingPrompt : ''}',
        userPrompt,
        'Task: $_nativeTask\n${AgentCompletion.requirementContext(_nativeTask)}\n$_nativeRetainedNotes\nWorking area: ${_taskArea ?? 'determine from real file evidence'}.',
      );
      onEvent(
        AgentEvent(
          'context',
          'Native context: ${jsonEncode(_nativeSession!.messages(_nativeOllamaRecovery ? 'ollama' : profile.apiFormat)).length} characters',
        ),
      );
    }
    final client =
        clientFactory?.call() ?? ModelClient(timeout: options.timeout);
    _active = client;
    try {
      return await client.send(
        _agentRequestProfile(
          maxTokens: maxTokens,
          jsonMode: jsonMode,
          recovery: recovery,
        ),
        {
          'systemPrompt': _privacy?.mask(systemPrompt) ?? systemPrompt,
          'userPrompt': _privacy?.mask(userPrompt) ?? userPrompt,
        },
        apiKey: apiKey,
        allowNativeToolActions: !_useNativeTools && !profile.isLocal,
        tools: _useNativeTools
            ? AgentGeneration.nativeTools(_actionSchema)
            : null,
        messages: _useNativeTools ? _nativeMessages() : null,
        toolChoiceAuto: !_omitToolChoice,
        attachments: _privacy?.prepareAttachments(attachments) ?? attachments,
      );
    } on ModelApiException catch (error) {
      if (_useNativeTools &&
          !_omitToolChoice &&
          error.statusCode == 400 &&
          error.message.contains('tool_choice')) {
        _omitToolChoice = true;
        onEvent(
          AgentEvent(
            'protocol',
            'Provider does not support tool_choice; keeping tools without that optional field.',
          ),
        );
        return await _send(
          recovery: recovery,
          options: options,
          maxTokens: maxTokens,
          jsonMode: jsonMode,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          attachments: attachments,
        );
      }
      final native = _nativeOllamaRecovery || profile.apiFormat == 'ollama';
      if (native &&
          _generation.localThinking == 'off' &&
          !_omitNativeThink &&
          error.statusCode == 400 &&
          error.message.toLowerCase().contains('think')) {
        _omitNativeThink = true;
        onEvent(
          AgentEvent(
            'context',
            'Model does not support think; retrying native Ollama once without that parameter.',
          ),
        );
        return await _send(
          recovery: true,
          options: options,
          maxTokens: agentRecoveryTokens,
          jsonMode: jsonMode,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          attachments: attachments,
        );
      }
      if (native &&
          _omitNativeThink &&
          error.statusCode == 400 &&
          error.message.toLowerCase().contains('think')) {
        throw ModelApiException(
          'Model recovery failed: ${error.message}',
          statusCode: error.statusCode,
        );
      }
      rethrow;
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
    Map<String, String> currentExcerpts = const {},
  }) async {
    if ((failure.reasoningOnly || failure.finishReason == 'length') &&
        profile.isLocal &&
        profile.isOllama &&
        profile.apiFormat == 'chat-completions' &&
        _generation.localThinking == 'off') {
      _nativeOllamaRecovery = true;
    }
    onEvent(
      AgentEvent(
        'context',
        'Recovery request after '
            '${failure.reasoningOnly ? 'a reasoning-only reply' : 'empty content'} '
            '(minimal prompt, at most $agentRecoveryTokens tokens)',
      ),
    );
    const system =
        'Return exactly one JSON action in message.content.\n'
        'Do not explain. Do not use reasoning_content.\n'
        'Shapes:\n'
        '{"action":"read_file","path":"<existing-project-path>","startLine":1,"lineCount":60}\n'
        '{"action":"replace_in_file","path":"<existing-project-path>","oldText":"...","newText":"..."}\n'
        '{"action":"write_file","path":"<existing-project-path>","content":"..."}\n'
        '{"action":"search_files","query":"literal text"}\n'
        '{"action":"finish","summary":"..."}';
    final allowed =
        (implementationPhase
                ? const [
                    'read_file',
                    'read_files',
                    'replace_in_file',
                    'write_file',
                    'run_tests',
                    'finish',
                  ]
                : const ['search_files', 'read_file', 'read_files', 'finish'])
            .where(
              (name) =>
                  (_schemaActions == null || _schemaActions!.contains(name)) &&
                  (name != 'run_tests' || _testingEnabled),
            );
    final user = StringBuffer()
      ..writeln('Previous response failed because content was empty.')
      ..writeln(_testingEnabled ? testingPrompt : '')
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
    for (final entry in currentExcerpts.entries.toList().reversed.take(2)) {
      user
        ..writeln('Current exact excerpt ${entry.key}:')
        ..writeln(entry.value);
    }
    user
      ..writeln()
      ..write('Return the next action only.');
    return await _send(
      recovery: true,
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
    if (_privacy != null) return const HookResult();
    final result = await hooks.run(type, input);
    onEvent(AgentEvent('hook', '$type: ${result.cancel ? 'blocked' : 'ok'}'));
    return result;
  }

  Map<String, dynamic> _decodeActionObject(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> || decoded['action'] is! String) {
      throw const ModelApiException('Model returned an invalid agent action.');
    }
    return _privacy == null
        ? decoded
        : _privacy!.restoreValue(decoded) as Map<String, dynamic>;
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
    if (objects.length > 1) {
      _replaceNote(
        transcript,
        'Host note:',
        'Host note: Your reply contained multiple actions. Only one is executed '
            'per iteration; the remaining actions and claimed results were NOT executed. '
            'Wait for the actual tool result and emit exactly one JSON object next.',
      );
    }
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

  static bool _allowed(String path) =>
      !path.split('/').any((part) => part == '.git' || part == '.tamtoot');

  /// A path is a directory when other indexed files live under it; a regular
  /// file never has children, so this never misfires on real files.
  Future<bool> _isDirectoryPath(String path) async =>
      path.isNotEmpty && (await store.listFiles(path)).isNotEmpty;

  /// Reading/searching another area does not authorize writing it. Such
  /// changes need explicit user approval even in YOLO mode.
  bool _outsideTaskScope(String path) {
    final area = _taskArea;
    final rootName = path
        .split('/')
        .first
        .replaceFirst(RegExp(r'^@'), '')
        .toLowerCase();
    final pathArea =
        _areaForPath(path) ??
        (_backendRootNames.contains(rootName)
            ? 'backend'
            : _frontendRootNames.contains(rootName)
            ? 'frontend'
            : null);
    if (pathArea != null && _forbiddenAreas.contains(pathArea)) return true;
    if (area == null) return false;
    if (pathArea == null || pathArea == area) return false;
    return true;
  }

  bool _visible(String path) => _useful(path, dotnetProject: _dotnetProject);

  static bool _useful(String path, {bool dotnetProject = false}) {
    if (!_allowed(path)) return false;
    final parts = path.split('/');
    const generated = {
      '.dart_tool',
      '.angular',
      '.gradle',
      '.idea',
      '.next',
      '.nyc_output',
      '.pytest_cache',
      '__pycache__',
      'build',
      'coverage',
      'dist',
      'DerivedData',
      'node_modules',
      'obj',
      'out',
      'Pods',
      'target',
    };
    if (parts.any(generated.contains)) return false;
    // bin/ holds build output in .NET repositories, but real source entry
    // points in Dart and other projects — exclude it only for .NET.
    if (dotnetProject && parts.any((part) => part == 'bin')) return false;
    return true;
  }

  static const _areaKeywords = {
    'frontend': [
      'frontend',
      'front-end',
      'angular',
      'react',
      'vue',
      'svelte',
      'ui',
      'ux',
      'html',
      'css',
      'scss',
      'dom',
      'компонент',
      'клик',
      'кнопк',
      'логотип',
      'интерфейс',
      'фронт',
      'верстк',
      'вёрстка',
      'страниц',
      'виджет',
      'экран',
      'иконк',
      'шапк',
    ],
    'backend': [
      'backend',
      'api',
      'endpoint',
      'endpoints',
      'controller',
      'бэкенд',
      'сервер',
      'контроллер',
      'эндпоинт',
      'база данн',
      'миграц',
      'репозитор',
      'sql',
    ],
    'tests': ['test', 'tests', 'spec', 'тест'],
  };

  static const _frontendRootNames = {
    'frontend',
    'client',
    'web',
    'ui',
    'spa',
    'portal',
  };
  static const _backendRootNames = {'backend', 'api', 'server', 'services'};
  static const _testRootNames = {'test', 'tests', 'e2e', 'spec', 'integration'};

  /// Which repository area the task most likely targets, or null when the
  /// task gives no usable signal (or signals several areas equally).
  static Set<String> _forbiddenTaskAreas(String task) {
    final areas = <String>{};
    final prefix =
        r"(?:do not|don't|never|не)\s+(?:modify|edit|touch|change|трог[а-яё]*|меня[а-яё]*|изменя[а-яё]*)\s+(?:the\s+)?(?:(?:files|code|файлы|код)\s+(?:in|of|в)\s+)?";
    for (final entry in {
      'backend': r'backend|back-end|бэкенд|бэкэнд|бекенд|сервер',
      'frontend': r'frontend|front-end|фронт',
      'tests': r'tests|тест',
    }.entries) {
      if (RegExp(
        '$prefix(?:${entry.value})',
        caseSensitive: false,
        unicode: true,
      ).hasMatch(task)) {
        areas.add(entry.key);
      }
    }
    return areas;
  }

  static String? _detectTaskArea(String task) {
    final lower = task.toLowerCase();
    // Explicit scope beats incidental mentions of another area as reference.
    for (final entry in {
      'frontend': r'frontend|front-end|фронтенд|фронт',
      'backend': r'backend|back-end|бэкенд',
      'tests': r'tests|тесты',
    }.entries) {
      if (RegExp(
        '(?:${entry.value})'
                r'\s+(?:only|exclusively)\b|(?:only|exclusively|только|исключительно)\s+(?:in\s+|inside\s+|the\s+)?(?:' +
            entry.value +
            ')',
        caseSensitive: false,
      ).hasMatch(task)) {
        return entry.key;
      }
    }
    final forbidden = _forbiddenTaskAreas(task);
    final scores = <String, int>{};
    _areaKeywords.forEach((area, keywords) {
      if (forbidden.contains(area)) return;
      var score = 0;
      for (final keyword in keywords) {
        // Leading word boundary so "ui" does not fire inside "requirement"
        // and "тест" does not fire inside "протестировать". Latin keywords
        // also need a trailing boundary ("api" vs "rapid"); Cyrillic ones
        // intentionally allow inflection suffixes ("клик", "кликнуть").
        final ascii = RegExp(r'^[a-z0-9]+$').hasMatch(keyword);
        final pattern = RegExp(
          '(^|[^a-z0-9а-яё_])${RegExp.escape(keyword)}${ascii ? r'($|[^a-z0-9а-яё_])' : ''}',
        );
        if (pattern.hasMatch(lower)) score++;
      }
      if (score > 0) scores[area] = score;
    });
    if (scores.isEmpty) return null;
    final best = scores.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final tied = scores.values.where((score) => score == best.value).length > 1;
    return tied ? null : best.key;
  }

  /// Maps area -> existing top-level roots, longest first. Only roots that
  /// actually exist in the index are claimed, so classification is project-
  /// specific instead of a fixed global scheme.
  static Map<String, List<String>> _buildAreaRoots(List<String> indexedPaths) {
    final roots = <String, String>{};
    final segments = <String>{};
    for (final path in indexedPaths) {
      segments.add(path.split('/').first);
    }
    for (final segment in segments) {
      final name = segment.toLowerCase().replaceFirst(RegExp(r'^@'), '');
      if (name.startsWith('.')) continue;
      if (_testRootNames.contains(name)) {
        roots[segment] = 'tests';
      } else if (_backendRootNames.contains(name) || name.endsWith('.api')) {
        roots[segment] = 'backend';
      } else if (_frontendRootNames.contains(name)) {
        roots[segment] = 'frontend';
      }
    }
    if (segments.contains('src')) {
      // A bare src/ is claimed only when exactly one area uses it as a
      // compound root (frontend/src, backend/src); otherwise it is ambiguous.
      final claimed = <String>{};
      for (final entry in roots.entries) {
        if (indexedPaths.any((p) => p.startsWith('${entry.key}/src/'))) {
          claimed.add(entry.value);
        }
      }
      if (claimed.length == 1) roots['src'] = claimed.single;
    }
    final byArea = <String, List<String>>{};
    roots.forEach((root, area) {
      byArea.putIfAbsent(area, () => []).add(root);
    });
    for (final list in byArea.values) {
      list.sort((a, b) => b.length.compareTo(a.length));
    }
    return byArea;
  }

  String? _areaForPath(String path) {
    String? area;
    var bestLength = -1;
    _areaRoots.forEach((candidate, roots) {
      for (final root in roots) {
        final inside = path == root || path.startsWith('$root/');
        if (inside && root.length > bestLength) {
          area = candidate;
          bestLength = root.length;
        }
      }
    });
    return area;
  }

  static String _areaSummary(List<String> paths) {
    final counts = <String, int>{};
    for (final path in paths) {
      final segment = path.split('/').first;
      if (!segment.startsWith('.')) {
        counts[segment] = (counts[segment] ?? 0) + 1;
      }
    }
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries
        .take(6)
        .map((entry) => '${entry.key} (${entry.value} files)')
        .join(', ');
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

  List<Map<String, dynamic>> _nativeMessages() {
    final messages = _nativeSession!.messages(
      _nativeOllamaRecovery ? 'ollama' : profile.apiFormat,
    );
    if (_privacy == null) return messages;
    return [
      for (final value in _privacy!.maskValue(messages) as List)
        Map<String, dynamic>.from(value as Map),
    ];
  }

  bool _featurePathMatchesTask(String task, String path) {
    final lower = task.toLowerCase();
    final file = path.toLowerCase();
    if (AgentCompletion.isHelpPageTask(task) && file.contains('help')) {
      return true;
    }
    final tokens = RegExp(r'[a-zа-яё][a-zа-яё0-9_]{3,}', caseSensitive: false)
        .allMatches(lower)
        .map((m) => m[0]!)
        .where(
          (t) => !{
            'create',
            'implement',
            'frontend',
            'backend',
            'project',
            'component',
            'public',
            'добавить',
            'создать',
            'проект',
            'страница',
          }.contains(t),
        );
    final segments = file.split(RegExp(r'[/._-]+')).toSet();
    return tokens.any(segments.contains);
  }

  Object? _canonicalAction(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonicalAction(value[key])};
    }
    if (value is List) return value.map(_canonicalAction).toList();
    return value;
  }

  int _repairStartLine(String content, String oldText, int? focus) {
    final tokens = RegExp(
      r'[A-Za-z_][A-Za-z_0-9]{2,}',
    ).allMatches(oldText).map((m) => m[0]!).toSet().take(32).toList();
    final lines = content.split('\n');
    var best = focus ?? 1;
    var score = 0;
    for (var i = 0; i < lines.length; i++) {
      final matched = tokens.where(lines[i].contains).length;
      if (matched > score) {
        best = (i - 10).clamp(0, lines.length - 1) + 1;
        score = matched;
      }
    }
    return best;
  }

  Future<void> _reportMissingRead(
    String path,
    Map<String, String> observations,
  ) async {
    if (!_missingReadPaths.add(path)) {
      throw ModelApiException(
        'File "$path" was already reported missing. Read an exact path from the available files instead.',
      );
    }
    // Refresh only after a missing read: files may have moved since indexing.
    final available = _privacy == null
        ? ((await store.listFiles('')).where(_visible).toList()..sort())
        : <String>[];
    final message =
        'File "$path" does not exist. No content was read. '
        'Do not retry this path or create it merely to inspect the project. '
        'Use an exact available path below; class libraries need no Program.cs.\n'
        '${_privacy != null ? 'Use list_files explicitly to discover the relevant directory.' : 'Available project files:\n${_bounded(available.take(80).join('\n'), 6000)}'}';
    _rememberObservation(observations, 'Missing file $path', message);
    onEvent(AgentEvent('tool', message));
  }

  Future<String> _projectIndex(List<String> paths) async {
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
    bool recovery = false,
  }) {
    final format = _nativeOllamaRecovery ? 'ollama' : profile.apiFormat;
    final params = Map<String, dynamic>.from(profile.parameters);
    // Each API format names the completion budget differently.
    params.removeWhere((key, _) => ModelClient.tokenBudgetKeys.contains(key));
    params[ModelClient.tokenBudgetKey(format)] = profile.isLocal
        ? (recovery
              ? _generation.localMaxTokens.clamp(256, agentRecoveryTokens)
              : _generation.localMaxTokens)
        : maxTokens;
    if (profile.isLocal) params['temperature'] = _generation.localTemperature;
    for (final entry in ModelClient.disableThinkingParameters(
      format,
      provider: profile.provider,
    ).entries) {
      final existing = params[entry.key];
      final value = entry.value;
      params[entry.key] = existing is Map && value is Map
          ? {...Map<String, dynamic>.from(existing), ...value}
          : value;
    }
    if (profile.isLocal) {
      for (final key in [
        'enable_thinking',
        'thinking',
        'chat_template_kwargs',
        'think',
        'reasoning_effort',
      ]) {
        params.remove(key);
      }
      if (_generation.localThinking != 'default') {
        if (format == 'ollama' && !_omitNativeThink) {
          params['think'] = _generation.localThinking == 'on';
        }
        // Ollama-compatible endpoints support this standard field; no template kwargs.
        if (format == 'chat-completions' && profile.isOllama) {
          params['reasoning_effort'] = _generation.localThinking == 'on'
              ? 'medium'
              : 'none';
        }
      }
      params.remove('response_format');
      params.remove('format');
      if (jsonMode && !_useNativeTools && format == 'ollama') {
        params['format'] = _responseMode == 'json_schema'
            ? _actionSchema
            : 'json';
      }
      if (jsonMode && !_useNativeTools && format == 'chat-completions') {
        params['response_format'] = _responseMode == 'json_schema'
            ? {
                'type': 'json_schema',
                'json_schema': {
                  'name': 'agent_action',
                  'schema': _actionSchema,
                },
              }
            : {'type': 'json_object'};
      }
    } else if (jsonMode &&
        !_useNativeTools &&
        ModelClient.supportsJsonObjectMode(format)) {
      params['response_format'] = const {'type': 'json_object'};
    }
    return ModelProfile(
      id: profile.id,
      name: profile.name,
      provider: profile.provider,
      model: profile.model,
      systemPrompt: profile.systemPrompt,
      userTemplate: profile.userTemplate,
      parameters: _privacy == null
          ? params
          : _privacy!.maskValue(params) as Map<String, dynamic>,
      apiFormat: format,
      endpoint: _nativeOllamaRecovery
          ? profile
                .requestUri()
                .replace(
                  path: profile.requestUri().path.replaceFirst(
                    RegExp(r'/(v1/chat/completions|api/(tags|chat|generate))$'),
                    '/api/chat',
                  ),
                )
                .toString()
          : profile.endpoint,
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
      // A search with only partial-word matches (e.g. "logo" inside
      // "logout") produced no usable evidence; a refined retry with a
      // narrower path or an exact symbol is legitimate, not a duplicate.
      if (!previous.relevant && previous.path != path) continue;
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
    if (_privacy != null || _discardMemory) return;
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
      if (_discardMemory) return;
      final write = _pendingMemoryWrite.then((_) async {
        if (!_discardMemory) await memoryStore.save(memory);
      });
      _pendingMemoryWrite = write.catchError((Object _) {});
      await write;
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
    if (profile.isLocal) _blockedActions.add(tool);
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

  /// Whether the match at [position] occupies a whole identifier/word: the
  /// characters on both sides must not be identifier characters. This is what
  /// keeps "logo" from reading as a hit inside "logout".
  static bool _isWordMatch(String line, int position, int length) {
    bool isIdent(int index) {
      final code = line.codeUnitAt(index);
      return (code >= 0x30 && code <= 0x39) || // 0-9
          (code >= 0x41 && code <= 0x5a) || // A-Z
          (code >= 0x61 && code <= 0x7a) || // a-z
          code == 0x5f || // _
          code == 0x24; // $
    }

    final before = position > 0 && isIdent(position - 1);
    final afterIndex = position + length;
    final after = afterIndex < line.length && isIdent(afterIndex);
    return !before && !after;
  }

  static String _matchPath(String match) =>
      match.split(':').first.split(' ').first;

  Future<_SearchOutcome> _runSearch(String query, String directory) async {
    final lower = query.toLowerCase();
    final files = (await store.listFiles(directory)).where(_visible).toList()
      ..sort();
    final preferred = _taskArea == null
        ? const <String>[]
        : (_areaRoots[_taskArea] ?? const <String>[]);
    int scopeRank(String path) =>
        preferred.any((root) => path == root || path.startsWith('$root/'))
        ? 0
        : 1;

    final strong = <String>[];
    final weak = <String>[];
    final pathMatches = <String>[];
    final strongPaths = <String>{};
    final matchLimit = _privacy == null ? 24 : 8;
    var scanned = 0;
    for (final path in files) {
      if (scanned >= 800) break;
      if (strong.length >= matchLimit &&
          weak.length >= matchLimit &&
          pathMatches.length >= matchLimit) {
        break;
      }
      if (path.toLowerCase().contains(lower)) {
        pathMatches.add('$path (path match)');
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
          final formatted = _privacy == null
              ? '$path:${index + 1}: $snippet'
              : '$path:${index + 1}: [content withheld; read a small excerpt]';
          if (_isWordMatch(line, position, lower.length)) {
            if (strong.length < matchLimit) strong.add(formatted);
            strongPaths.add(path);
          } else if (weak.length < matchLimit) {
            weak.add(formatted);
          }
        }
      } catch (_) {
        // Unreadable and transient files are omitted from search results.
      }
    }

    // Stable partition: files from the task's working area come first within
    // each quality tier; alphabetical order is otherwise preserved.
    List<String> ranked(List<String> matches) => [
      ...matches.where((match) => scopeRank(_matchPath(match)) == 0),
      ...matches.where((match) => scopeRank(_matchPath(match)) != 0),
    ];

    final buffer = StringBuffer();
    var total = 0;
    void addAll(List<String> items) {
      for (final item in items) {
        buffer.writeln(item);
        total++;
      }
    }

    final rankedStrong = ranked(strong);
    addAll(rankedStrong);
    addAll(ranked(pathMatches));
    final rankedWeak = ranked(weak);
    if (rankedWeak.isNotEmpty) {
      if (_privacy == null) {
        buffer.writeln(
          'Partial-word matches (the query is only part of a larger word, '
          'e.g. "logo" in "logout") — weak evidence, listed last:',
        );
      }
      addAll(rankedWeak);
    }

    final hasRelevantHit = strongPaths.isNotEmpty || pathMatches.isNotEmpty;
    var text = '';
    if (total == 0) {
      text = 'No matches in $scanned searchable files.';
    } else {
      text =
          '${buffer.toString().trimRight()}\n'
          'Returned $total matches from $scanned searchable files.';
      if (!hasRelevantHit) {
        text +=
            '\nNote: all matches are partial-word matches only (the query '
            'appears inside larger words). Refine the query to an exact symbol '
            'or pass a narrower path'
            '${preferred.isEmpty ? '' : ' (working area: ${preferred.join(', ')})'}.';
      }
    }
    return _SearchOutcome(
      text: text,
      hits: _parseSearchHits(text),
      hasRelevantHit: hasRelevantHit,
      strongPaths: strongPaths,
    );
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
      if (_privacy != null) {
        final start = (uniqueFocus.first - 21).clamp(0, lines.length);
        return _sliceExcerpt(path, lines, start, start + 40);
      }
      return _excerptAroundMatches(
        path,
        lines,
        uniqueFocus,
        maxLines: maxLines,
      );
    }

    if (lines.length <= budget && content.length <= _excerptLimit) {
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
      if (total + chunk.length > _excerptLimit) {
        final remaining = _excerptLimit - total;
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
      if (total + add > _excerptLimit) break;
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
          (existing) => existing == pathKey || existing.startsWith('$pathKey '),
        )
        .toList();
    if (activeFiles.containsKey(key)) {
      // Refresh the exact same window.
    } else if (samePath.length >= 2) {
      activeFiles.remove(samePath.first);
    }
    // Prefer whole-line truncation so replace_in_file never sees a fake file end.
    if (content.length <= _excerptLimit) {
      activeFiles[key] = content;
    } else {
      final cut = content.lastIndexOf('\n', _excerptLimit);
      final keepTo = cut > 0 ? cut : _excerptLimit;
      activeFiles[key] = '${content.substring(0, keepTo)}\n… excerpt truncated';
    }
    final evicted = <String>[];
    int characters() =>
        activeFiles.values.fold(0, (total, value) => total + value.length);
    while (activeFiles.length > (_privacy == null ? maxActiveFiles : 1) ||
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
          {'startLine': (line - 25).clamp(1, 1 << 30), 'lineCount': 60},
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
    this.relevant = true,
  });
  final String query;
  final String path;
  final String result;
  final List<_SearchHit> hits;

  /// False when the search only produced partial-word matches (the query was
  /// found inside larger words). Such a search must not force a read and must
  /// not block a refined follow-up search.
  final bool relevant;
}

class _SearchOutcome {
  const _SearchOutcome({
    required this.text,
    required this.hits,
    required this.hasRelevantHit,
    required this.strongPaths,
  });
  final String text;
  final List<_SearchHit> hits;
  final bool hasRelevantHit;
  final Set<String> strongPaths;
}

class _AgentFileExcerpt {
  const _AgentFileExcerpt(this.key, this.content, this.description);
  final String key, content, description;
}
