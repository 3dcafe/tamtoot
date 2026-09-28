import 'dart:convert';
import 'dart:io';

import 'package:tamtoot/core/agents/agent_engine.dart';
import 'package:tamtoot/core/agents/model_profile.dart';
import 'package:tamtoot/core/agents/profile_store.dart';
import 'package:tamtoot/core/git/http_git_service.dart';
import 'package:tamtoot/platform/git_service.dart';

Future<void> main(List<String> arguments) async {
  var yolo = false, jsonOutput = false;
  var timeout = 600, maxMistakes = 3;
  String? profileId;
  final taskParts = <String>[];
  for (var index = 0; index < arguments.length; index++) {
    final arg = arguments[index];
    switch (arg) {
      case '-y' || '--yolo':
        yolo = true;
      case '--json':
        jsonOutput = true;
      case '--timeout':
        timeout = int.parse(arguments[++index]);
      case '--max-consecutive-mistakes':
        maxMistakes = int.parse(arguments[++index]);
      case '--profile':
        profileId = arguments[++index];
      case '--help' || '-h':
        stdout.writeln(
          'ide-agent [-y|--yolo] [--json] [--profile id] '
          '[--timeout seconds] [--max-consecutive-mistakes n] "task"',
        );
        exitCode = 0;
        return;
      default:
        if (arg.startsWith('-')) {
          stderr.writeln('Unknown option: $arg');
          exitCode = 64;
          return;
        }
        taskParts.add(arg);
    }
  }
  var task = taskParts.join(' ').trim();
  if (!stdin.hasTerminal) {
    final piped = await stdin.transform(utf8.decoder).join();
    if (piped.trim().isNotEmpty) {
      task = task.isEmpty ? piped : '$task\n\nPiped context:\n$piped';
    }
  }
  if (task.isEmpty) {
    stderr.writeln('Task is required. Use --help for syntax.');
    exitCode = 64;
    return;
  }

  final root = Directory.current.uri;
  final git = createGitService();
  if (git is! HttpGitService || !await git.isRepository(root)) {
    stderr.writeln('Run ide-agent from a supported Git repository.');
    exitCode = 2;
    return;
  }
  final store = ProfileStore(git.openStore(root));
  final paths = await store.list();
  final selectedPath = profileId == null
      ? paths.firstOrNull
      : store.path(profileId);
  if (selectedPath == null || !paths.contains(selectedPath)) {
    stderr.writeln('Model profile not found in .tamtoot/agents/models/.');
    exitCode = 2;
    return;
  }
  final source = await store.read(selectedPath);
  final instructions = await store.read(ProfileStore.instructionsPath) ?? '';
  final loaded = ModelProfile.parse(source!);
  final profile = ModelProfile(
    id: loaded.id,
    name: loaded.name,
    provider: loaded.provider,
    model: loaded.model,
    systemPrompt: [
      loaded.systemPrompt,
      instructions,
    ].where((value) => value.trim().isNotEmpty).join('\n\n'),
    userTemplate: loaded.userTemplate,
    parameters: loaded.parameters,
    apiFormat: loaded.apiFormat,
    endpoint: loaded.endpoint,
  );
  final apiKey = Platform.environment['TAMTOOT_API_KEY'] ?? '';
  void emit(AgentEvent event) {
    if (jsonOutput) {
      stdout.writeln(jsonEncode(event.toJson()));
    } else {
      stdout.writeln('[${event.type}] ${event.text}');
    }
  }

  final engine = AgentTaskEngine(
    profile: profile,
    store: git.openStore(root),
    git: git,
    root: root,
    apiKey: apiKey,
    onEvent: emit,
    approve: (action, values) async {
      if (!stdin.hasTerminal) return false;
      stderr.write('Allow $action ${values['path']}? [y/N] ');
      return (stdin.readLineSync() ?? '').toLowerCase() == 'y';
    },
  );
  ProcessSignal.sigint.watch().listen((_) => engine.stop());
  try {
    final result = await engine.run(
      task,
      AgentRunOptions(
        yolo: yolo,
        timeout: Duration(seconds: timeout),
        maxConsecutiveMistakes: maxMistakes,
      ),
    );
    if (jsonOutput) {
      stdout.writeln(
        jsonEncode({
          'type': 'result',
          'success': result.success,
          'text': result.message,
          'iterations': result.iterations,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    }
    exitCode = result.success ? 0 : 1;
  } catch (e) {
    if (jsonOutput) {
      stdout.writeln(
        jsonEncode({
          'type': 'error',
          'text': '$e',
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } else {
      stderr.writeln(e);
    }
    exitCode = 1;
  }
}
