import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tamtoot/core/agents/agent_engine.dart';
import 'package:tamtoot/core/agents/model_client.dart';
import 'package:tamtoot/core/agents/model_profile.dart';
import 'package:tamtoot/core/agents/native_tool_session.dart';
import 'agent_engine_test.dart' show AgentGit, NoHooks;
import 'agent_local_models_test.dart' show localProfile, answer;
import 'explorer_test.dart' show RepositoryMemory;

Map<String, dynamic> call(String id, String name, Map<String, dynamic> args) =>
    {
      'id': id,
      'type': 'function',
      'function': {'name': name, 'arguments': jsonEncode(args)},
    };
http.Response reply(
  List<Map<String, dynamic>> calls, {
  String text = '',
  bool ollama = false,
}) => http.Response(
  jsonEncode(
    ollama
        ? {
            'message': {
              'role': 'assistant',
              'content': text,
              'tool_calls': [
                for (final c in calls)
                  {
                    'function': {
                      'name': c['function']['name'],
                      'arguments': jsonDecode(c['function']['arguments']),
                    },
                  },
              ],
            },
            'done': true,
          }
        : {
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': text,
                  'tool_calls': calls,
                },
                'finish_reason': calls.isEmpty ? 'stop' : 'tool_calls',
              },
            ],
          },
  ),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
AgentTaskEngine runner(
  RepositoryMemory store,
  Future<http.Response> Function(http.Request) respond, {
  ModelProfile? profile,
  Future<bool> Function(String, Map<String, dynamic>)? approve,
  List<AgentEvent>? events,
}) => AgentTaskEngine(
  profile: profile ?? localProfile(),
  store: store,
  git: AgentGit(),
  root: Uri.parse('memory:///project/'),
  apiKey: '',
  hooks: NoHooks(),
  onEvent: (e) => events?.add(e),
  approve: approve ?? (_, _) async => true,
  clientFactory: () => ModelClient(client: MockClient(respond)),
);
const native = AgentRunOptions(
  toolCalling: 'native',
  maxConsecutiveMistakes: 4,
);
const app = 'frontend/src/app/app.ts',
    routes = 'frontend/src/app/app.routes.ts',
    help = 'frontend/src/app/help/help.component.ts';
const appSource = '''import { Component } from '@angular/core';
import { RouterLink, RouterOutlet } from '@angular/router';
@Component({selector: 'app-root', standalone: true, imports: [RouterLink, RouterOutlet], template: `<nav><a routerLink="/">Home</a><button (click)="signOut()">Sign out</button></nav><router-outlet />`})
export class App { selectedPage = 'home'; signOut() {} }
''';
const routeSource =
    "import { Routes } from '@angular/router';\nexport const routes: Routes = [];";
const helpSource = '''import { Component } from '@angular/core';
@Component({selector: 'app-help', standalone: true, template: `<h1>About ParcelBoard</h1><p>ParcelBoard coordinates shipping orders and delivery schedules. Dispatchers track shipments, customers and warehouse operations. This public overview explains the shipping workflow without requiring an account.</p>`})
export class HelpComponent {}
''';
Future<void> seed(RepositoryMemory store) async {
  await store.writeText(
    'README.md',
    '# ParcelBoard\nParcelBoard coordinates shipping orders and delivery schedules for dispatchers and warehouses.',
  );
  await store.writeText(app, appSource);
  await store.writeText(routes, routeSource);
  await store.writeText('backend/auth.cs', 'class Auth {}');
}

Map<String, dynamic> toolResult(Map body, String id) => jsonDecode(
  (body['messages'] as List).firstWhere(
    (m) => m['role'] == 'tool' && m['tool_call_id'] == id,
  )['content'],
);

void main() {
  for (final task in [
    'Change frontend. Do not modify backend.',
    'Frontend only: change navigation. Read backend for reference.',
    'Change code only inside frontend. Do not modify anything outside frontend.',
    'Inspect README. Do not touch backend.',
  ]) {
    test('explicit scope authorization: $task', () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      var approvals = 0;
      final turns = [
        [
          call('read', 'read_file', {'path': 'backend/auth.cs'}),
        ],
        [
          call('edit', 'replace_in_file', {
            'path': 'backend/auth.cs',
            'oldText': 'class Auth {}',
            'newText': 'class Auth { bool Disabled = true; }',
          }),
        ],
        [
          call('end', 'finish', {
            'summary': 'Backend denied.',
            'unresolved': ['Frontend remains'],
          }),
        ],
      ];
      final run = runner(
        store,
        (_) async => reply(turns[requests++]),
        approve: (_, _) async {
          approvals++;
          return false;
        },
      );
      expect((await run.run(task, native)).success, false);
      expect(approvals, 1);
      expect(await store.readText('backend/auth.cs'), 'class Auth {}');
    });
  }

  test(
    'context compaction preserves complete tool-call/result groups and findings',
    () {
      final session = NativeToolSession(
        'System rules',
        'Large initial index',
        'Original task, first paragraph.\n\nSecond paragraph with requirements.',
      );
      for (var i = 0; i < 20; i++) {
        session.accept(
          ModelReply(
            '',
            toolCalls: [
              ModelToolCall(
                id: 'id_$i',
                name: 'read_file',
                arguments: {'path': 'frontend/file$i.ts'},
              ),
            ],
          ),
        );
        final invocation = session.pending.removeAt(0);
        session.result(
          invocation,
          jsonEncode({
            'ok': true,
            'paths': ['frontend/file$i.ts'],
            'result':
                'Read frontend/file$i.ts\n${List.filled(5000, 'x').join()}',
          }),
        );
        session.messages('chat-completions');
      }
      final messages = session.messages('chat-completions');
      final requests = <String>{}, results = <String>{};
      for (final message in messages) {
        if (message['tool_calls'] is List) {
          requests.addAll(
            (message['tool_calls'] as List).map((c) => c['id'] as String),
          );
        }
        if (message['role'] == 'tool') {
          results.add(message['tool_call_id'] as String);
        }
      }
      expect(results, requests);
      expect(messages.length, lessThan(41));
      expect(
        jsonEncode(messages),
        contains('Second paragraph with requirements'),
      );
      expect(jsonEncode(messages), contains('Earlier host outcomes'));
      expect(jsonEncode(messages), isNot(contains('Large initial index')));
    },
  );

  test(
    'duplicate call IDs stop before any call in that batch executes',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      final events = <AgentEvent>[];
      final run = runner(
        store,
        (_) async => reply([
          call('duplicate', 'read_file', {'path': app}),
          call('duplicate', 'read_file', {'path': routes}),
        ]),
        events: events,
      );
      await expectLater(
        run.run('Explain frontend', native),
        throwsA(isA<ModelApiException>()),
      );
      expect(events.where((e) => e.type == 'tool'), isEmpty);
    },
  );

  for (final mode in ['native', 'json']) {
    test(
      'diagnostic events omit source snapshots and secrets in $mode mode',
      () async {
        final store = RepositoryMemory();
        await seed(store);
        await store.writeText(
          app,
          '$appSource\nconst password = "do-not-log-this-secret";',
        );
        var requests = 0;
        final events = <AgentEvent>[];
        final run = runner(store, (_) async {
          if (requests++ == 0) {
            return mode == 'native'
                ? reply([
                    call('read', 'read_file', {'path': app}),
                  ])
                : answer(jsonEncode({'action': 'read_file', 'path': app}));
          }
          return mode == 'native'
              ? reply([
                  call('end', 'finish', {'summary': 'Inspected source.'}),
                ])
              : answer('{"action":"finish","summary":"Inspected source."}');
        }, events: events);
        await run.run('Explain frontend', AgentRunOptions(toolCalling: mode));
        expect(
          events
              .map((e) => jsonEncode({'text': e.text, 'data': e.data}))
              .join(),
          isNot(contains('do-not-log-this-secret')),
        );
      },
    );
  }

  test(
    'a natural final response after verified edits goes through host completion checks',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      final turns = [
        reply([
          call('read', 'read_file', {'path': app}),
        ]),
        reply([
          call('edit', 'replace_in_file', {
            'path': app,
            'oldText': "selectedPage = 'home'",
            'newText': "selectedPage = 'settings'",
          }),
        ]),
        reply([
          call('verify', 'read_file', {'path': app}),
        ]),
        reply(
          [],
          text: 'Updated and verified the default page. Build not run.',
        ),
      ];
      final events = <AgentEvent>[];
      final run = runner(store, (_) async => turns[requests++], events: events);
      expect(
        (await run.run('Change frontend default page', native)).success,
        true,
      );
      expect(events.where((e) => e.type == 'done'), hasLength(1));
      expect(requests, 4);
    },
  );

  test(
    'unsupported tool_choice is omitted once while retaining native tools',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      final run = runner(store, (r) async {
        final body = jsonDecode(r.body);
        if (requests++ == 0) {
          expect(body['tool_choice'], 'auto');
          return http.Response(
            '{"error":{"message":"tool_choice is not supported"}}',
            400,
          );
        }
        expect(body.containsKey('tool_choice'), false);
        expect(body['tools'], isNotEmpty);
        return reply([
          call('end', 'finish', {'summary': 'No modifications requested.'}),
        ]);
      });
      expect((await run.run('Explain this project', native)).success, true);
      expect(requests, 2);
    },
  );

  test(
    'malformed tool arguments return a genuine tool error without executing',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      final run = runner(store, (r) async {
        if (requests++ == 0) {
          return reply([
            {
              'id': 'bad-json',
              'type': 'function',
              'function': {'name': 'write_file', 'arguments': '{broken'},
            },
          ]);
        }
        expect(toolResult(jsonDecode(r.body), 'bad-json')['ok'], false);
        return reply([
          call('end', 'finish', {
            'summary': 'Invalid tool arguments were rejected.',
            'unresolved': ['No change applied'],
          }),
        ]);
      });
      expect((await run.run('Add frontend feature', native)).success, false);
      expect(await store.readText(app), appSource);
    },
  );

  test(
    'native tools work for an explicitly configured non-Ollama compatible provider',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      final run = runner(
        store,
        (r) async {
          if (requests++ == 0) {
            return reply([
              call('read', 'read_file', {'path': app}),
            ]);
          }
          expect(toolResult(jsonDecode(r.body), 'read')['ok'], true);
          return reply([
            call('end', 'finish', {'summary': 'Read app source.'}),
          ]);
        },
        profile: ModelProfile(
          id: 'compatible',
          name: 'Compatible',
          provider: 'compatible',
          model: 'model',
          endpoint: 'https://example.test/v1/chat/completions',
        ),
      );
      expect((await run.run('Explain frontend', native)).success, true);
    },
  );

  test(
    'numbered requirements need actual current source evidence before completion',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      final turns = [
        [
          call('read', 'read_file', {'path': app}),
        ],
        [
          call('premature', 'finish', {'summary': 'Both requirements done.'}),
        ],
        [
          call('done', 'finish', {
            'summary': 'Verified both requested facts.',
            'requirements': [
              {'id': 0, 'path': app, 'excerpt': '<a routerLink="/">Home</a>'},
              {'id': 1, 'path': app, 'excerpt': '(click)="signOut()"'},
            ],
          }),
        ],
      ];
      final run = runner(store, (r) async {
        if (requests == 2) {
          expect(
            toolResult(jsonDecode(r.body), 'premature')['error'],
            contains('source evidence'),
          );
          expect(r.body, contains('1. Inspect the Home link'));
          expect(r.body, contains('2. Inspect the Sign out handler'));
        }
        return reply(turns[requests++]);
      });
      expect(
        (await run.run(
          'Inspect the frontend:\n1. Inspect the Home link\n2. Inspect the Sign out handler',
          native,
        )).success,
        true,
      );
    },
  );

  test(
    'a guarded parent route cannot be claimed as a public Help page',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      final guarded =
          "import { HelpComponent } from './help/help.component';\nexport const routes = [{path: '', canActivate: [authGuard], children: [{path: 'help', component: HelpComponent}]}];";
      final turns = [
        [
          call('docs', 'read_file', {'path': 'README.md'}),
          call('route', 'read_file', {'path': routes}),
          call('app', 'read_file', {'path': app}),
        ],
        [
          call('help', 'write_file', {'path': help, 'content': helpSource}),
        ],
        [
          call('guarded', 'replace_in_file', {
            'path': routes,
            'oldText': routeSource,
            'newText': guarded,
          }),
        ],
        [
          call('verify', 'read_files', {
            'paths': [help, routes],
          }),
        ],
        [
          call('premature', 'finish', {'summary': 'Public Help done!'}),
        ],
        [
          call('end', 'finish', {
            'summary': 'Help exists but remains guarded.',
            'unresolved': ['Public route and navigation missing'],
          }),
        ],
      ];
      final run = runner(store, (r) async {
        if (requests == 5) {
          expect(
            toolResult(jsonDecode(r.body), 'premature')['error'],
            contains('public_help_route'),
          );
        }
        return reply(turns[requests++]);
      });
      expect(
        (await run.run(
          'Add a public Help page to the Angular frontend',
          native,
        )).success,
        false,
      );
    },
  );

  test(
    'OpenAI native calls preserve IDs, execute a batch, and complete a real public Angular Help page',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      final bodies = <Map<String, dynamic>>[];
      final turns = [
        [
          call('read-docs', 'read_file', {'path': 'README.md'}),
          call('read-routes', 'read_file', {'path': routes}),
          call('read-app', 'read_file', {'path': app}),
        ],
        [
          call('create-help', 'write_file', {
            'path': help,
            'content': helpSource,
          }),
        ],
        [
          call('integrate', 'replace_in_file', {
            'path': routes,
            'oldText': 'export const routes: Routes = [];',
            'newText':
                "import { HelpComponent } from './help/help.component';\nexport const routes: Routes = [{path: 'help', component: HelpComponent}];",
          }),
          call('navigation', 'replace_in_file', {
            'path': app,
            'oldText': '<a routerLink="/">Home</a>',
            'newText':
                '<a routerLink="/">Home</a><a routerLink="/help">Help</a>',
          }),
        ],
        [
          call('verify-help', 'read_file', {'path': help}),
          call('verify-routes', 'read_file', {'path': routes}),
          call('verify-app', 'read_file', {'path': app}),
        ],
        [
          call('finish', 'finish', {
            'summary':
                'Implemented public Help page with project content, route and navigation. Source verified; Angular build not run.',
          }),
        ],
      ];
      var request = 0;
      final run = runner(store, (r) async {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        bodies.add(body);
        expect(body['tool_choice'], 'auto');
        expect(body.containsKey('response_format'), false);
        expect(body['tools'], isNotEmpty);
        if (request == 1) {
          expect(toolResult(body, 'read-docs')['ok'], true);
          expect(
            toolResult(body, 'read-routes')['result'],
            contains('export const routes'),
          );
          expect(toolResult(body, 'read-app')['result'], contains('signOut()'));
        }
        return reply(turns[request++]);
      });
      final result = await run.run(
        'Add a public Help page to the Angular frontend accessible without authentication and explaining the project.',
        native,
      );
      expect(result.success, true);
      expect(request, 5);
      expect(await store.readText(app), contains('(click)="signOut()"'));
      expect(await store.readText(help), helpSource);
      expect(await store.readText('backend/auth.cs'), 'class Auth {}');
      expect(
        (await store.listFiles(
          '',
        )).where((p) => !p.startsWith('.tamtoot/')).toSet(),
        {'README.md', app, routes, help, 'backend/auth.cs'},
      );
      final toolMessages = (bodies.last['messages'] as List).where(
        (m) => m['role'] == 'tool',
      );
      expect(
        toolMessages.map((m) => m['tool_call_id']).toSet().length,
        toolMessages.length,
      );
    },
  );

  test(
    'auto probes the actual Ollama model and uses native tool_name results',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      final run = runner(store, (r) async {
        final body = jsonDecode(r.body);
        if (requests++ == 0) {
          expect(r.url.path, '/api/show');
          expect(body['model'], 'local-model');
          return http.Response(
            '{"capabilities":["completion","tools","insert"]}',
            200,
          );
        }
        expect(r.url.path, '/api/chat');
        expect(body.containsKey('tool_choice'), false);
        expect(body.containsKey('format'), false);
        if (requests == 2) {
          return reply([
            call('ignored', 'read_file', {'path': app}),
          ], ollama: true);
        }
        expect(
          (body['messages'] as List).firstWhere(
            (m) => m['role'] == 'tool',
          )['tool_name'],
          'read_file',
        );
        return reply([
          call('ignored', 'finish', {
            'summary': 'Read the app; no changes requested.',
          }),
        ], ollama: true);
      });
      expect(
        (await run.run(
          'Explain this frontend',
          const AgentRunOptions(toolCalling: 'auto'),
        )).success,
        true,
      );
      expect(requests, 3);
    },
  );

  test(
    'unsupported models use JSON fallback without inventing support',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      final run = runner(store, (r) async {
        final body = jsonDecode(r.body);
        if (requests++ == 0) {
          return http.Response('{"capabilities":["completion"]}', 200);
        }
        expect(body.containsKey('tools'), false);
        expect(body['tool_choice'], 'none');
        return answer('{"action":"finish","summary":"JSON fallback"}');
      });
      expect(
        (await run.run(
          'Explain project',
          const AgentRunOptions(toolCalling: 'auto'),
        )).success,
        true,
      );
    },
  );

  test('provider tool rejection switches to JSON once', () async {
    final store = RepositoryMemory();
    await seed(store);
    var requests = 0;
    final run = runner(store, (r) async {
      final body = jsonDecode(r.body);
      if (requests++ == 0) {
        return http.Response(
          '{"error":{"message":"model does not support tools"}}',
          400,
        );
      }
      expect(body.containsKey('tools'), false);
      return answer('{"action":"finish","summary":"Fallback completed"}');
    });
    expect((await run.run('Explain project', native)).success, true);
    expect(requests, 2);
  });

  test(
    'failed replacement returns the actual error, then a single verified retry succeeds',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      final turns = [
        [
          call('read', 'read_file', {'path': app}),
        ],
        [
          call('bad', 'replace_in_file', {
            'path': app,
            'oldText': 'not in source',
            'newText': 'x',
          }),
        ],
        [
          call('good', 'replace_in_file', {
            'path': app,
            'oldText': "selectedPage = 'home'",
            'newText': "selectedPage = 'settings'",
          }),
        ],
        [
          call('verify', 'read_file', {'path': app}),
        ],
        [
          call('done', 'finish', {
            'summary': 'Changed selected page; verified.',
          }),
        ],
      ];
      final run = runner(store, (r) async {
        if (requests == 2) {
          final result = toolResult(jsonDecode(r.body), 'bad');
          expect(result['ok'], false);
          expect(result['error'], contains('oldText was not found'));
        }
        return reply(turns[requests++]);
      });
      expect(
        (await run.run(
          'Change the default page in the frontend app',
          native,
        )).success,
        true,
      );
    },
  );

  test(
    'repeated identical native reads are rejected with a tool error',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      final run = runner(store, (r) async {
        if (requests == 3) {
          final result = toolResult(jsonDecode(r.body), 'read2');
          expect(result['ok'], false);
          expect(result['error'], contains('already read twice'));
        }
        return reply([
          requests < 3
              ? call('read${requests++}', 'read_file', {'path': app})
              : call('end', 'finish', {
                  'summary': 'Read source; stopped repeating.',
                }),
        ]);
      });
      expect((await run.run('Explain frontend app', native)).success, true);
    },
  );

  test(
    'edit and revert cycle is blocked and final result reports unresolved work',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      final turns = [
        [
          call('read', 'read_file', {'path': app}),
        ],
        [
          call('edit', 'replace_in_file', {
            'path': app,
            'oldText': "selectedPage = 'home'",
            'newText': "selectedPage = 'settings'",
          }),
        ],
        [
          call('verify', 'read_file', {'path': app}),
        ],
        [
          call('reverse', 'replace_in_file', {
            'path': app,
            'oldText': "selectedPage = 'settings'",
            'newText': "selectedPage = 'home'",
          }),
        ],
        [
          call('end', 'finish', {
            'summary': 'Stopped after rejected reversal.',
            'unresolved': ['Remaining design decision'],
          }),
        ],
      ];
      final run = runner(store, (r) async {
        if (requests == 4) {
          expect(
            toolResult(jsonDecode(r.body), 'reverse')['error'],
            contains('reversal detected'),
          );
        }
        return reply(turns[requests++]);
      });
      expect((await run.run('Change frontend page', native)).success, false);
      expect(await store.readText(app), contains("selectedPage = 'settings'"));
    },
  );

  test(
    'reading a backend file does not authorize modifying it for a frontend task',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      final approvals = <String>[];
      final turns = [
        [
          call('read', 'read_file', {'path': 'backend/auth.cs'}),
        ],
        [
          call('edit', 'replace_in_file', {
            'path': 'backend/auth.cs',
            'oldText': 'class Auth {}',
            'newText': 'class Auth { public bool Disabled = true; }',
          }),
        ],
        [
          call('end', 'finish', {
            'summary': 'Backend modification denied.',
            'unresolved': ['Frontend work remains'],
          }),
        ],
      ];
      final run = runner(
        store,
        (r) async {
          if (requests == 2) {
            expect(toolResult(jsonDecode(r.body), 'edit')['ok'], false);
          }
          return reply(turns[requests++]);
        },
        approve: (name, _) async {
          approvals.add(name);
          return false;
        },
      );
      expect(
        (await run.run('Change frontend navigation', native)).success,
        false,
      );
      expect(approvals, ['replace_in_file']);
      expect(await store.readText('backend/auth.cs'), 'class Auth {}');
    },
  );

  test('menu selection alone cannot complete a requested Help page', () async {
    final store = RepositoryMemory();
    await seed(store);
    var requests = 0;
    final turns = [
      [
        call('read', 'read_file', {'path': app}),
      ],
      [
        call('menu', 'replace_in_file', {
          'path': app,
          'oldText': "selectedPage = 'home'",
          'newText': "selectedPage = 'help'",
        }),
      ],
      [
        call('verify', 'read_file', {'path': app}),
      ],
      [
        call('premature', 'finish', {'summary': 'Help page implemented!'}),
      ],
      [
        call('end', 'finish', {
          'summary': 'Only selected menu item changed.',
          'unresolved': [
            'Actual Help page, integration and public access remain',
          ],
        }),
      ],
    ];
    final run = runner(store, (r) async {
      if (requests == 4) {
        expect(
          toolResult(jsonDecode(r.body), 'premature')['error'],
          contains('Task incomplete'),
        );
      }
      return reply(turns[requests++]);
    });
    expect(
      (await run.run(
        'Add a public Help page to the Angular frontend',
        native,
      )).success,
      false,
    );
    expect(await store.exists(help), false);
  });

  test(
    'text without tool calls cannot fabricate execution or imply completion',
    () async {
      final store = RepositoryMemory();
      await seed(store);
      var requests = 0;
      final run = runner(store, (_) async {
        requests++;
        return reply(
          [],
          text: 'I ran tools and changed backend/auth.cs successfully.',
        );
      });
      await expectLater(
        run.run('Change frontend navigation', native),
        throwsA(isA<ModelApiException>()),
      );
      expect(requests, 2);
      expect(await store.readText('backend/auth.cs'), 'class Auth {}');
    },
  );

  test('missing-file operation returns a genuine failed tool result', () async {
    final store = RepositoryMemory();
    await seed(store);
    var requests = 0;
    final run = runner(store, (r) async {
      if (requests++ == 0) {
        return reply([
          call('missing', 'read_file', {'path': 'no-file.ts'}),
        ]);
      }
      final result = toolResult(jsonDecode(r.body), 'missing');
      expect(result['ok'], false);
      expect(result['error'], contains('does not exist'));
      return reply([
        call('end', 'finish', {
          'summary': 'File is missing.',
          'unresolved': ['Missing input file'],
        }),
      ]);
    });
    expect((await run.run('Inspect no-file.ts', native)).success, false);
  });

  test('external modifications invalidate a previous read', () async {
    final store = RepositoryMemory();
    await seed(store);
    var requests = 0;
    final run = runner(store, (r) async {
      if (requests++ == 0) {
        return reply([
          call('read', 'read_file', {'path': app}),
        ]);
      }
      if (requests == 2) {
        await store.writeText(app, '$appSource\n// external edit');
        return reply([
          call('stale', 'replace_in_file', {
            'path': app,
            'oldText': "selectedPage = 'home'",
            'newText': "selectedPage = 'help'",
          }),
        ]);
      }
      expect(
        toolResult(jsonDecode(r.body), 'stale')['error'],
        contains('Stale or unread'),
      );
      return reply([
        call('end', 'finish', {
          'summary': 'Stopped because source changed.',
          'unresolved': ['Review external edit'],
        }),
      ]);
    });
    expect(
      (await run.run('Change frontend navigation', native)).success,
      false,
    );
    expect(await store.readText(app), contains('// external edit'));
  });
}
