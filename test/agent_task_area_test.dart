import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tamtoot/core/agents/agent_engine.dart';
import 'package:tamtoot/core/agents/model_client.dart';

import 'agent_engine_test.dart' show AgentGit, NoHooks, agentProfile;
import 'agent_local_models_test.dart' show engine, answer;
import 'explorer_test.dart' show RepositoryMemory;

// Real-world regression fixture: Angular frontend + .NET backend. The word
// "logo" only exists as a partial match inside "logout" on the backend; the
// actual logo lives in the frontend component.
const logoHtml = '''<header class="app-header">
  <img src="assets/logo.svg" alt="Bego" class="app-logo" (click)="goToDashboard()" />
  <span class="app-title">Bego</span>
</header>
''';

const logoTs = '''import { Component } from '@angular/core';
import { Router } from '@angular/router';

@Component({ selector: 'app-root', templateUrl: './app.component.html' })
export class AppComponent {
  constructor(private readonly router: Router) {}

  goToDashboard(): void {
    this.router.navigate(['/dashboard']);
  }
}
''';

const routesTs = '''import { Routes } from '@angular/router';
import { DashboardComponent } from './features/dashboard/dashboard.component';
import { ShipmentJournalComponent } from './features/shipments/shipment-journal.component';

export const routes: Routes = [
  { path: 'dashboard', component: DashboardComponent },
  { path: 'shipments', component: ShipmentJournalComponent },
];
''';

const authEndpointsCs = '''public static class AuthEndpoints
{
    public static void MapAuth(this WebApplication app)
    {
        app.MapPost("/logout", () => Results.Ok()).WithName("Logout");
        app.MapPost("/login", () => Results.Ok()).WithName("Login");
    }
}
''';

const logoPath = 'frontend/src/app/app.component.html';
const logoTsPath = 'frontend/src/app/app.component.ts';
const routesPath = 'frontend/src/app/app.routes.ts';
const authPath = 'backend/Bego.Api/Features/Auth/AuthEndpoints.cs';

Future<void> writeBegoProject(RepositoryMemory store) async {
  await store.writeText(logoPath, logoHtml);
  await store.writeText(logoTsPath, logoTs);
  await store.writeText(routesPath, routesTs);
  await store.writeText(authPath, authEndpointsCs);
}

String bodyOf(http.Request request) =>
    (jsonDecode(request.body)['messages'] as List)
        .map((m) => m['content'])
        .join('\n');

void main() {
  test('logo click task ranks frontend exact matches above logout partial match '
      'and never touches the backend', () async {
    final store = RepositoryMemory();
    await writeBegoProject(store);
    final actions = [
      {'action': 'search_files', 'query': 'logo'},
      {
        'action': 'read_files',
        'paths': [logoPath, logoTsPath],
      },
      {'action': 'read_file', 'path': routesPath},
      {
        'action': 'replace_in_file',
        'path': logoTsPath,
        'oldText': "this.router.navigate(['/dashboard']);",
        'newText': "this.router.navigate(['/shipments']);",
      },
      {'action': 'read_file', 'path': logoTsPath},
      {
        'action': 'finish',
        'summary':
            'Logo click now navigates to the shipment journal route; backend untouched.',
      },
    ];
    final bodies = <String>[];
    var requests = 0;
    final run = engine(store, (request) async {
      bodies.add(bodyOf(request));
      return answer(jsonEncode(actions[requests++]));
    });
    final result = await run.run(
      'На фронте при клике на логотип перейти в журнал отгрузки',
      const AgentRunOptions(),
    );
    expect(result.success, isTrue);
    expect(requests, actions.length);

    // The task header declares the frontend working area.
    expect(bodies[0], contains('Working area: frontend'));
    expect(bodies[0], isNot(contains('Working area: backend')));

    // The search result ranks the exact frontend match first and marks the
    // backend "logout" hit as a partial-word match instead of leading with
    // it alphabetically (backend < frontend).
    final searchResult = bodies[1];
    final frontendHit = searchResult.indexOf('app.component.html');
    final backendHit = searchResult.indexOf('AuthEndpoints.cs');
    expect(frontendHit, greaterThanOrEqualTo(0));
    expect(backendHit, greaterThanOrEqualTo(0));
    expect(frontendHit, lessThan(backendHit));
    expect(searchResult, contains('Partial-word matches'));
    expect(searchResult, contains('logout'));
    // The weak backend hit must not be advertised as a read target.
    expect(
      searchResult.contains(
        'implementation file(s) (frontend/src/app/app.component.html, backend/',
      ),
      isFalse,
    );

    // Backend file is byte-identical; the click handler moved to the
    // existing shipments route.
    expect(await store.readText(authPath), authEndpointsCs);
    expect(
      await store.readText(logoTsPath),
      contains("this.router.navigate(['/shipments']);"),
    );
  });

  test(
    'a weak-only search does not block a refined retry in another path',
    () async {
      final store = RepositoryMemory();
      await store.writeText(authPath, authEndpointsCs);
      final actions = [
        {'action': 'search_files', 'query': 'logo'},
        {'action': 'search_files', 'query': 'logo', 'path': 'backend/Bego.Api'},
        {
          'action': 'finish',
          'summary':
              'No logo component exists; only a partial match inside "logout".',
        },
      ];
      final bodies = <String>[];
      var requests = 0;
      final events = <AgentEvent>[];
      final run = engine(store, (request) async {
        bodies.add(bodyOf(request));
        return answer(jsonEncode(actions[requests++]));
      }, events: events);
      final result = await run.run(
        'Change the logo click target',
        const AgentRunOptions(),
      );
      expect(result.success, isTrue);
      // The second search was executed, not rejected as a duplicate.
      expect(requests, actions.length);
      for (final body in bodies) {
        expect(body, isNot(contains('was already searched')));
      }
      expect(events.where((e) => e.type == 'denied'), isEmpty);
      // The model was told the matches were partial, not forced to read them.
      expect(bodies[1], contains('partial-word matches only'));
    },
  );

  test('read_file on a directory is rejected with a list_files hint', () async {
    final store = RepositoryMemory();
    await writeBegoProject(store);
    const directory = 'frontend/src/app';
    final actions = [
      {'action': 'read_file', 'path': directory},
      {'action': 'read_file', 'path': logoTsPath},
      {
        'action': 'finish',
        'summary': 'Read the component after listing the directory.',
      },
    ];
    final bodies = <String>[];
    var requests = 0;
    final events = <AgentEvent>[];
    final run = engine(store, (request) async {
      bodies.add(bodyOf(request));
      return answer(jsonEncode(actions[requests++]));
    }, events: events);
    final result = await run.run(
      'Inspect the logo component on the frontend',
      const AgentRunOptions(),
    );
    expect(result.success, isTrue);
    expect(bodies[1], contains('"$directory" is a directory'));
    expect(
      events.where((e) => e.type == 'error').map((e) => e.text).join(),
      contains('is a directory'),
    );
  });

  test('editing outside the detected working area needs confirmation even in '
      'YOLO mode', () async {
    final store = RepositoryMemory();
    await writeBegoProject(store);
    final approvals = <String>[];
    var requests = 0;
    ModelClient client() => ModelClient(
      client: MockClient((request) async {
        requests++;
        final action = requests == 1
            ? {
                'action': 'write_file',
                'path': authPath,
                'content': '// tampered',
              }
            : {
                'action': 'finish',
                'summary': 'Backend edit was denied; nothing changed.',
              };
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': jsonEncode(action)},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );
    final run = AgentTaskEngine(
      profile: agentProfile(),
      store: store,
      git: AgentGit(),
      root: Uri.parse('memory:///project/'),
      apiKey: '',
      hooks: NoHooks(),
      onEvent: (_) {},
      approve: (action, _) async {
        approvals.add(action);
        return false;
      },
      clientFactory: client,
    );
    final result = await run.run(
      'Перейти в журнал отгрузки по клику на логотип на фронте',
      const AgentRunOptions(yolo: true),
    );
    expect(result.success, isTrue);
    // The out-of-scope backend write hit the approval gate despite YOLO.
    expect(approvals, ['write_file']);
    expect(await store.readText(authPath), authEndpointsCs);
  });

  test(
    'recovery note restates goal, area and known files after a stall',
    () async {
      final store = RepositoryMemory();
      await store.writeText('lib/a.dart', 'const a = 1;\n');
      final actions = [
        {'action': 'read_file', 'path': 'missing/one.dart'},
        {'action': 'read_file', 'path': 'missing/two.dart'},
        {'action': 'finish', 'summary': 'Stalled on missing files; reporting.'},
      ];
      final bodies = <String>[];
      var requests = 0;
      final run = engine(store, (request) async {
        bodies.add(bodyOf(request));
        return answer(jsonEncode(actions[requests++]));
      });
      final result = await run.run(
        'Explain lib/a.dart',
        const AgentRunOptions(),
      );
      expect(result.success, isTrue);
      expect(
        bodies[2],
        contains('Recovery: 3 iterations without useful progress'),
      );
      expect(bodies[2], contains('Goal: Explain lib/a.dart'));
      expect(bodies[2], contains('finish stating the precise blocker'));
    },
  );

  test('"протестируй" is not mistaken for a tests-area task and short keywords '
      'do not match inside unrelated words', () async {
    final store = RepositoryMemory();
    await store.writeText('lib/button.dart', 'class Button {}\n');
    final bodies = <String>[];
    final run = engine(store, (request) async {
      bodies.add(bodyOf(request));
      return answer(
        jsonEncode({
          'action': 'finish',
          'summary': 'Area classification checked.',
        }),
      );
    });
    await run.run('Протестируй кнопку отправки', const AgentRunOptions());
    expect(bodies[0], isNot(contains('Working area: tests')));
    expect(bodies[0], contains('Working area: frontend'));
  });
}
