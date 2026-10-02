import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'dart:convert';

import 'package:tamtoot/core/agents/agent_engine.dart';
import 'package:tamtoot/core/agents/project_memory.dart';
import 'package:tamtoot/core/agents/model_client.dart';

import 'agent_engine_test.dart' show AgentGit, NoHooks, FakeCommands, agentProfile;
import 'explorer_test.dart' show RepositoryMemory;

void main() {
  test('project memory merges, scrubs secrets and compacts', () {
    final memory = ProjectMemory();
    final first = memory.mergeTask(
      task: 'PNG fails with UTF-8 decoding',
      summary: 'Binary files hit File.readAsString via readLocal',
      readPaths: const [
        'lib/app/session_commands.dart',
        'lib/platform/local_files_io.dart',
      ],
      editedPaths: const ['lib/platform/local_files_io.dart'],
      fileFingerprints: const {
        'lib/platform/local_files_io.dart': '10:abc',
        'lib/app/session_commands.dart': '20:def',
      },
      learnedFacts: const [
        'file.openEntry -> documents.open',
        'readLocal uses File.readAsString',
        'api_key=super-secret-value',
      ],
    );
    expect(first.areaTitle.toLowerCase(), contains('png'));
    expect(memory.areas, hasLength(1));
    expect(memory.areas.single.learned.join(' '), isNot(contains('super-secret')));
    expect(memory.recentEdits.single.path, 'lib/platform/local_files_io.dart');

    memory.mergeTask(
      task: 'PNG fails with UTF-8 decoding for images',
      summary: 'Reuse binary open path',
      readPaths: const ['lib/platform/local_files_io.dart'],
      editedPaths: const ['lib/platform/local_files_io.dart'],
      fileFingerprints: const {'lib/platform/local_files_io.dart': '11:abd'},
      learnedFacts: const ['readLocal should use bytes for images'],
    );
    expect(memory.areas, hasLength(1));

    final selection = memory.selectRelevant('open jpg image file');
    expect(selection.areas, isNotEmpty);
    final prompt = memory.formatForPrompt(selection, stalePaths: {'lib/platform/local_files_io.dart'});
    expect(prompt, contains('Relevant retained project knowledge'));
    expect(prompt, contains('possibly stale'));
    expect(prompt.length, lessThanOrEqualTo(ProjectMemory.maxPromptCharacters + 40));

    // Force compaction by flooding areas.
    for (var i = 0; i < 20; i++) {
      memory.mergeTask(
        task: 'Unrelated area number $i with lots of filler text for compaction',
        summary: 'summary $i ' * 20,
        readPaths: ['lib/extra_$i.dart'],
        editedPaths: ['lib/extra_$i.dart'],
        fileFingerprints: {'lib/extra_$i.dart': '$i:hash'},
        learnedFacts: List.generate(6, (j) => 'fact $i.$j ' * 8),
      );
    }
    expect(memory.characterCount, lessThanOrEqualTo(ProjectMemory.maxDocumentCharacters));
    expect(memory.areas.length, lessThanOrEqualTo(ProjectMemory.maxAreas));
  });

  test('knownPathsForQuery returns remembered implementation files', () {
    final memory = ProjectMemory();
    memory.mergeTask(
      task: 'UTF-8 decode on PNG open',
      summary: 'openEntry uses readAsString',
      readPaths: const ['lib/platform/local_files_io.dart'],
      editedPaths: const [],
      fileFingerprints: const {},
      learnedFacts: const ['openEntry -> readLocal -> readAsString'],
    );
    expect(
      memory.knownPathsForQuery('openEntry'),
      contains('lib/platform/local_files_io.dart'),
    );
  });

  test('agent loads memory, skips redundant search, and persists update', () async {
    final store = RepositoryMemory();
    await store.writeText(
      'lib/platform/local_files_io.dart',
      'Future<String> readLocal() => File(path).readAsString();\n',
    );
    final seed = ProjectMemory();
    seed.mergeTask(
      task: 'PNG UTF-8 decoding error',
      summary: 'Binary open path found',
      readPaths: const ['lib/platform/local_files_io.dart'],
      editedPaths: const [],
      fileFingerprints: {
        'lib/platform/local_files_io.dart': ProjectMemory.fingerprintText(
          await store.readText('lib/platform/local_files_io.dart'),
        ),
      },
      learnedFacts: const [
        'openEntry -> documents.open -> readLocal -> readAsString',
      ],
    );
    await ProjectMemoryStore(store).save(seed);

    final events = <AgentEvent>[];
    final bodies = <String>[];
    final actions = [
      '{"action":"search_files","query":"openEntry","path":"lib"}',
      '{"action":"read_file","path":"lib/platform/local_files_io.dart"}',
      '{"action":"replace_in_file","path":"lib/platform/local_files_io.dart",'
          '"oldText":"readAsString()","newText":"readAsBytes()"}',
      '{"action":"finish","summary":"Switched binary open to bytes."}',
    ];
    ModelClient client() => ModelClient(
      client: MockClient((request) async {
        bodies.add(request.body);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': actions.removeAt(0)},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );

    final engine = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: Uri.parse('memory:///project/'),
      apiKey: '',
      onEvent: events.add,
      approve: (_, _) async => true,
      clientFactory: client,
      hooks: NoHooks(),
      commands: FakeCommands(),
    );

    final result = await engine.run(
      'JPG opening still broken like PNG',
      const AgentRunOptions(yolo: false),
    );
    expect(result.success, isTrue);
    expect(bodies.first, contains('Relevant retained project knowledge'));
    expect(
      events.where((e) => e.type == 'memory').map((e) => e.text),
      anyElement(contains('Loaded')),
    );
    expect(
      events.where((e) => e.type == 'memory').map((e) => e.text),
      anyElement(contains('Skipped redundant search')),
    );
    expect(
      events.where((e) => e.type == 'memory').map((e) => e.text),
      anyElement(contains('Updated area')),
    );
    expect(await store.exists(ProjectMemory.storePath), isTrue);
    final saved = ProjectMemory.parse(
      await store.readText(ProjectMemory.storePath),
    );
    expect(saved.recentEdits, isNotEmpty);
    expect(
      saved.recentEdits.any((e) => e.path.contains('local_files_io.dart')),
      isTrue,
    );
  });
}
