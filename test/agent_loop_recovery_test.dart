import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tamtoot/core/agents/agent_engine.dart';
import 'package:tamtoot/core/agents/model_client.dart';
import 'agent_local_models_test.dart' show engine, answer;
import 'explorer_test.dart' show RepositoryMemory;

const path = 'lib/pages/components/cardVisit.dart';
const source = '''import 'package:flutter/material.dart';
class CardVisit extends StatelessWidget {
  const CardVisit({super.key, required this.openVisit, required this.openDetails});
  final VoidCallback openVisit;
  final VoidCallback openDetails;
  static final visitStyle = TextButton.styleFrom(foregroundColor: Colors.blue);
  static final detailsStyle = TextButton.styleFrom(foregroundColor: Colors.grey);
  static final newVisitStyle = TextButton.styleFrom(foregroundColor: Colors.green);
  static final newDetailsStyle = TextButton.styleFrom(foregroundColor: Colors.orange);
  @override
  Widget build(BuildContext context) => Column(children: [
    TextButton(onPressed: openVisit, style: visitStyle, child: Text('Visit')),
    TextButton(onPressed: openDetails, style: detailsStyle, child: Text('Details')),
  ]);
}
''';
Map<String, dynamic> read() => {
  'action': 'read_file',
  'path': path,
  'startLine': 1,
  'lineCount': 20,
};
Map<String, dynamic> edit(String old, String replacement) => {
  'action': 'replace_in_file',
  'path': path,
  'oldText': old,
  'newText': replacement,
};
Map<String, dynamic> finish() => {
  'action': 'finish',
  'summary':
      'Updated only the two button styles; verified file contents. Tests were not run.',
};

void main() {
  test(
    'repairing malformed JSON retains exact loaded source instead of guessing oldText',
    () async {
      final store = RepositoryMemory();
      await store.writeText(path, source);
      final replies = [
        jsonEncode(read()),
        '{"action":"replace_in_file",',
        jsonEncode(edit('style: visitStyle', 'style: newVisitStyle')),
        jsonEncode(read()),
        jsonEncode(finish()),
      ];
      var requests = 0;
      final run = engine(store, (request) async {
        if (requests == 2) {
          expect(request.body, contains('onPressed: openVisit'));
          expect(request.body, contains('style: visitStyle'));
        }
        return answer(replies[requests++]);
      });
      expect(
        (await run.run(
          'Change style in $path',
          const AgentRunOptions(),
        )).success,
        true,
      );
      expect(requests, 5);
    },
  );

  test(
    'explicit test task may create a test but not a results artifact',
    () async {
      final store = RepositoryMemory();
      await store.writeText(path, source);
      final actions = [
        {'action': 'write_file', 'path': 'results.txt', 'content': 'junk'},
        {
          'action': 'write_file',
          'path': 'test/card_visit_test.dart',
          'content': 'void main() {}',
        },
        {'action': 'read_file', 'path': 'test/card_visit_test.dart'},
        {'action': 'finish', 'summary': 'Created a test skeleton; not run.'},
      ];
      var requests = 0;
      final run = engine(
        store,
        (_) async => answer(jsonEncode(actions[requests++])),
      );
      await run.run('Add tests for the card widget', const AgentRunOptions());
      expect(await store.exists('results.txt'), false);
      expect(await store.exists('test/card_visit_test.dart'), true);
    },
  );

  test(
    'native Ollama rejects think then returns empty: at most three calls',
    () async {
      final store = RepositoryMemory();
      await store.writeText(path, source);
      var requests = 0;
      final run = engine(store, (request) async {
        requests++;
        final body = jsonDecode(request.body);
        if (requests == 1) {
          expect(body['think'], false);
          return http.Response(
            '{"error":"model does not support thinking"}',
            400,
          );
        }
        expect(body.containsKey('think'), false);
        expect(body['options']['num_predict'], 800);
        return answer(
          '',
          format: 'ollama',
          finish: 'length',
          reasoning: 'private',
        );
      }, format: 'ollama');
      await expectLater(
        run.run('Explain this project', const AgentRunOptions()),
        throwsA(isA<ModelEmptyAnswerException>()),
      );
      expect(requests, 3);
    },
  );

  test('reading an unrelated range does not verify an edit', () async {
    final store = RepositoryMemory();
    final longSource =
        '${List.filled(100, '// unrelated line').join('\n')}\n$source';
    await store.writeText(path, longSource);
    final targetRead = {
      'action': 'read_file',
      'path': path,
      'startLine': 101,
      'lineCount': 20,
    };
    final actions = [
      targetRead,
      edit('style: visitStyle', 'style: newVisitStyle'),
      read(),
      finish(),
      targetRead,
      finish(),
    ];
    var requests = 0;
    final events = <AgentEvent>[];
    final run = engine(
      store,
      (_) async => answer(jsonEncode(actions[requests++])),
      events: events,
    );
    expect(
      (await run.run(
        'Change the button style in $path',
        const AgentRunOptions(),
      )).success,
      true,
    );
    expect(
      events.where((e) => e.type == 'error').map((e) => e.text).join(),
      contains('verify each edited file'),
    );
    expect(requests, 6);
  });

  test(
    'placeholder writes are rejected even in an empty scaffolding task',
    () async {
      final store = RepositoryMemory();
      final actions = [
        {'action': 'write_file', 'path': 'relative/file', 'content': 'junk'},
        {
          'action': 'write_file',
          'path': 'relative/results.txt',
          'content': 'junk',
        },
        {'action': 'finish', 'summary': 'No files created.'},
      ];
      var requests = 0;
      final run = engine(
        store,
        (_) async => answer(jsonEncode(actions[requests++])),
      );
      await run.run('Create an application', const AgentRunOptions());
      expect(await store.exists('relative/file'), false);
      expect(await store.exists('relative/results.txt'), false);
    },
  );

  test('an externally changed version can be read after two reads', () async {
    final store = RepositoryMemory();
    await store.writeText(path, source);
    final actions = [read(), read(), read(), finish()];
    var requests = 0;
    final events = <AgentEvent>[];
    final run = engine(store, (_) async {
      if (requests == 2) {
        await store.writeText(path, '$source// External update');
      }
      return answer(jsonEncode(actions[requests++]));
    }, events: events);
    expect(
      (await run.run('Explain $path', const AgentRunOptions())).success,
      true,
    );
    expect(events.where((e) => e.type == 'error'), isEmpty);
  });

  for (final unsupported in [false, true]) {
    test(
      'reasoning length uses native Ollama think false; unsupported=$unsupported is bounded',
      () async {
        final store = RepositoryMemory();
        await store.writeText(path, source);
        var requests = 0;
        final run = engine(store, (request) async {
          requests++;
          final body = jsonDecode(request.body);
          if (requests == 1) {
            return answer(
              '',
              finish: 'length',
              reasoning: unsupported ? 'private-thought' : null,
            );
          }
          expect(request.url.path, '/api/chat');
          expect(body['options']['num_predict'], 800);
          expect(request.body, isNot(contains('private-thought')));
          if (requests == 2) {
            expect(body['think'], false);
            if (unsupported) {
              return http.Response(
                '{"error":"model does not support thinking"}',
                400,
              );
            }
          } else {
            expect(body.containsKey('think'), false);
          }
          return answer(jsonEncode(finish()), format: 'ollama');
        });
        expect(
          (await run.run(
            'Explain the project',
            const AgentRunOptions(),
          )).success,
          true,
        );
        expect(requests, unsupported ? 3 : 2);
      },
    );
  }

  test(
    'replacement allows no third retry after an unverified fragment',
    () async {
      final store = RepositoryMemory();
      await store.writeText(path, source);
      final actions = [
        read(),
        edit('imaginary fragment', 'bad'),
        edit('another imaginary fragment', 'bad'),
        edit('style: visitStyle', 'style: bad'),
        {
          'action': 'finish',
          'summary': 'Could not apply the edit; file unchanged.',
        },
      ];
      var requests = 0;
      final run = engine(store, (request) async {
        if (requests == 3) {
          final schema = jsonDecode(
            request.body,
          )['response_format']['json_schema']['schema'];
          final replaceSchema = (schema['oneOf'] as List).firstWhere(
            (s) => s['properties']['action']['const'] == 'replace_in_file',
          );
          expect(
            replaceSchema['properties']['path']['not']['enum'],
            contains(path),
          );
        }
        return answer(jsonEncode(actions[requests++]));
      });
      final result = await run.run(
        'Change the style in $path',
        const AgentRunOptions(maxConsecutiveMistakes: 4),
      );
      expect(result.success, false);
      expect(result.message, contains('Unresolved replacements'));
      expect(await store.readText(path), source);
    },
  );

  test(
    'forbidden search is absent from the next schema and cannot execute',
    () async {
      final store = RepositoryMemory();
      await store.writeText(path, source);
      final actions = [
        {'action': 'search_files', 'query': 'visitStyle'},
        {'action': 'search_files', 'query': 'visitStyle'},
        read(),
        finish(),
      ];
      var requests = 0;
      final run = engine(store, (request) async {
        if (requests == 1) {
          final schema = jsonDecode(
            request.body,
          )['response_format']['json_schema']['schema'];
          expect(
            (schema['oneOf'] as List).map(
              (s) => s['properties']['action']['const'],
            ),
            isNot(contains('search_files')),
          );
        }
        return answer(jsonEncode(actions[requests++]));
      });
      expect(
        (await run.run('Explain $path', const AgentRunOptions())).success,
        true,
      );
    },
  );

  test('finish requires reading the changed file version', () async {
    final store = RepositoryMemory();
    await store.writeText(path, source);
    final actions = [
      read(),
      edit('style: visitStyle', 'style: newVisitStyle'),
      finish(),
      read(),
      finish(),
    ];
    var requests = 0;
    final events = <AgentEvent>[];
    final run = engine(
      store,
      (_) async => answer(jsonEncode(actions[requests++])),
      events: events,
    );
    expect(
      (await run.run(
        'Change the style in $path',
        const AgentRunOptions(),
      )).success,
      true,
    );
    expect(events.where((e) => e.type == 'done'), hasLength(1));
    expect(requests, 5);
  });

  test('action budget bounds an otherwise progressing run', () async {
    final store = RepositoryMemory();
    await store.writeText(path, source);
    var requests = 0;
    final run = engine(store, (_) async {
      requests++;
      return answer(jsonEncode(read()));
    });
    await expectLater(
      run.run('Explain $path', const AgentRunOptions(maxActions: 2)),
      throwsA(isA<ModelApiException>()),
    );
    expect(requests, 2);
  });

  test(
    'two Flutter styles: find, read, edit, verify, finish preserves callbacks and creates no files',
    () async {
      final store = RepositoryMemory();
      await store.writeText(path, source);
      final actions = [
        {'action': 'search_files', 'query': 'visitStyle'},
        read(),
        edit('style: visitStyle', 'style: newVisitStyle'),
        read(),
        edit('style: detailsStyle', 'style: newDetailsStyle'),
        read(),
        finish(),
      ];
      var requests = 0;
      final run = engine(
        store,
        (_) async => answer(jsonEncode(actions[requests++])),
      );
      final result = await run.run(
        'Change the styles of the two Flutter buttons in $path; preserve onPressed handlers',
        const AgentRunOptions(),
      );
      expect(result.success, true);
      expect(requests, actions.length);
      expect(
        await store.readText(path),
        source
            .replaceFirst('style: visitStyle', 'style: newVisitStyle')
            .replaceFirst('style: detailsStyle', 'style: newDetailsStyle'),
      );
      expect(
        (await store.listFiles('')).where((p) => !p.startsWith('.tamtoot/')),
        [path],
      );
    },
  );

  test(
    'third unchanged read is excluded from schema and rejected, edits reset file version',
    () async {
      final store = RepositoryMemory();
      await store.writeText(path, source);
      final actions = [
        read(),
        read(),
        read(),
        edit('style: visitStyle', 'style: newVisitStyle'),
        read(),
        finish(),
      ];
      var requests = 0;
      final events = <AgentEvent>[];
      final run = engine(store, (request) async {
        if (requests == 2) {
          final schema = jsonDecode(
            request.body,
          )['response_format']['json_schema']['schema'];
          final readSchema = (schema['oneOf'] as List).firstWhere(
            (s) => s['properties']['action']['const'] == 'read_file',
          );
          expect(
            readSchema['properties']['path']['not']['enum'],
            contains(path),
          );
        }
        return answer(jsonEncode(actions[requests++]));
      }, events: events);
      expect(
        (await run.run(
          'Update the style in $path',
          const AgentRunOptions(),
        )).success,
        true,
      );
      expect(
        events.where((e) => e.type == 'error').map((e) => e.text).join(),
        contains('already read twice'),
      );
    },
  );

  test(
    'missing oldText refreshes a bounded excerpt and permits one exact retry',
    () async {
      final store = RepositoryMemory();
      await store.writeText(path, source);
      final actions = [
        read(),
        edit('style: inventedStyle', 'style: newVisitStyle'),
        edit('style: visitStyle', 'style: newVisitStyle'),
        read(),
        finish(),
      ];
      var requests = 0;
      final run = engine(store, (request) async {
        if (requests == 2) expect(request.body, contains('style: visitStyle'));
        return answer(jsonEncode(actions[requests++]));
      });
      expect(
        (await run.run(
          'Update the style in $path',
          const AgentRunOptions(),
        )).success,
        true,
      );
      expect(
        await store.readText(path),
        contains('onPressed: openVisit, style: newVisitStyle'),
      );
    },
  );

  for (final badPath in [
    'relative/file',
    'relative/results.txt',
    'unrelated.txt',
  ]) {
    test('rejects unrequested output $badPath', () async {
      final store = RepositoryMemory();
      await store.writeText(path, source);
      final actions = [
        {'action': 'write_file', 'path': badPath, 'content': 'placeholder'},
        finish(),
      ];
      var requests = 0;
      final run = engine(
        store,
        (_) async => answer(jsonEncode(actions[requests++])),
      );
      await run.run('Change styles in $path', const AgentRunOptions());
      expect(await store.exists(badPath), false);
      expect(await store.readText(path), source);
    });
  }

  test('no progress budget bounds repeated say actions', () async {
    final store = RepositoryMemory();
    await store.writeText(path, source);
    var requests = 0;
    final run = engine(store, (_) async {
      requests++;
      return answer('{"action":"say","text":"Still working"}');
    });
    await expectLater(
      run.run(
        'Explain this project',
        const AgentRunOptions(maxNoProgressActions: 3),
      ),
      throwsA(isA<ModelApiException>()),
    );
    expect(requests, lessThanOrEqualTo(3));
  });
}
