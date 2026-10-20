// Opt-in single live scenario. Runs the real SessionRunner and Ollama transport.
// dart run tool/agent_readme_diagnostic.dart PROJECT OLLAMA_URL MODEL
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tamtoot/core/opencode/config.dart';
import 'package:tamtoot/core/opencode/llm.dart';
import 'package:tamtoot/core/opencode/message.dart';
import 'package:tamtoot/core/opencode/runner.dart';
import 'package:tamtoot/core/opencode/session.dart';
import 'package:tamtoot/core/opencode/tools.dart';

class TraceClient extends LlmClient {
  final requests = <LlmRequest>[];
  @override
  Stream<LlmEvent> stream(LlmRequest request) {
    requests.add(request);
    stdout.writeln(
      'REQUEST ${requests.length}: tools=${request.tools.map((t) => t.name).join(",")} tool_results=${request.messages.where((m) => m.role == "tool").length}',
    );
    return super.stream(request);
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError('PROJECT OLLAMA_URL MODEL required');
  }
  final root = Directory(args[0]).absolute.path;
  final temp = await Directory.systemTemp.createTemp('tamtoot-readme-');
  final store = SessionStore(temp.path);
  final session = await store.create(title: 'Live README regression');
  final client = TraceClient();
  final runner = SessionRunner(
    root: root,
    store: store,
    client: client,
    config: OpencodeConfig(
      selectedModel: 'ollama/${args[2]}',
      providers: {
        'ollama': ProviderConfig(
          id: 'ollama',
          type: 'ollama',
          baseURL: args[1],
          think: false,
        ),
      },
    ),
    tools: [
      for (final tool in defaultTools())
        Tool(
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters,
          execute: (input, context) async {
            if (!['read', 'glob', 'grep'].contains(tool.name)) {
              throw const ToolFailure('This diagnostic is read-only.');
            }
            stdout.writeln(
              'TOOL ${tool.name} ${jsonEncode(input)} root=${context.root}',
            );
            return tool.execute(input, context);
          },
        ),
    ],
  );
  await runner.prompt(session, 'О чем этот проект?');
  final deadline = DateTime.now().add(const Duration(minutes: 8));
  while (runner.isBusy(session.id) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  if (runner.isBusy(session.id)) {
    await runner.stop(session.id);
    throw StateError('Live scenario timed out');
  }
  final trace = File('${temp.path}/trace.json');
  await trace.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'project': root,
      'requests': [
        for (final request in client.requests)
          {
            'tools': request.tools.map((t) => t.name).toList(),
            'messages': [
              for (final m in request.messages)
                {
                  'role': m.role,
                  'content': m.text,
                  if (m.toolName != null) 'tool_name': m.toolName,
                  if (m.toolCalls.isNotEmpty)
                    'tool_calls': [
                      for (final c in m.toolCalls)
                        {'name': c.name, 'arguments': c.arguments},
                    ],
                },
            ],
          },
      ],
      'session': session.toJson(),
    }),
  );
  stdout.writeln('TRACE ${trace.path}');
  final parts = session.messages.expand((m) => m.parts).whereType<ToolPart>();
  final readme = parts
      .where(
        (p) =>
            p.tool == 'read' &&
            p.state.status == 'completed' &&
            (p.state.input?['path'] == 'README.md' ||
                p.state.input?['path'] == '$root/README.md'),
      )
      .toList();
  if (readme.isEmpty) throw StateError('No successful native README read');
  final source = await File('$root/README.md').readAsString();
  if (!readme.any((p) => p.state.output!.contains(source.split('\n').first))) {
    throw StateError('README result did not contain the real file content');
  }
  if (!client.requests.every((r) => r.tools.any((t) => t.name == 'read')) ||
      !client.requests.any(
        (r) => r.messages.any(
          (m) =>
              m.role == 'tool' &&
              m.toolName == 'read' &&
              m.text.contains('Read file '),
        ),
      )) {
    throw StateError('Native tool definitions/result round trip missing');
  }
  final finals = session.messages.where(
    (m) =>
        m.role == 'assistant' &&
        !m.diagnostic &&
        m.parts.whereType<ToolPart>().isEmpty,
  );
  if (finals.isEmpty) throw StateError('No final answer');
  final answer = finals.last.parts
      .whereType<TextPart>()
      .map((p) => p.text)
      .join('\n');
  if (!RegExp(r'[А-Яа-яЁё]{3}').hasMatch(answer) ||
      !answer.toLowerCase().contains('bego') ||
      !RegExp(r'бетон|crm', caseSensitive: false).hasMatch(answer)) {
    throw StateError(
      'Final answer is not a Russian summary grounded in Bego README',
    );
  }
  stdout.writeln(
    'ANSWER\n$answer\nPASS: native read → actual README → role:tool → Russian summary',
  );
  // HttpClient keep-alive must not keep this diagnostic process running.
  exit(0);
}
