import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/agents/agent_engine.dart';
import 'package:tamtoot/core/agents/model_profile.dart';
import 'explorer_test.dart' show RepositoryMemory;
import 'agent_engine_test.dart' show AgentGit, NoHooks;

void main() {
  test(
    'live Ollama C# scaffold in an isolated in-memory project',
    () async {
      final store = RepositoryMemory();
      final runner = AgentTaskEngine(
        profile: ModelProfile(
          id: 'local',
          name: 'Local',
          provider: 'ollama',
          model:
              Platform.environment['TAMTOOT_LIVE_OLLAMA_MODEL'] ??
              'local-model',
          apiFormat: 'ollama',
          endpoint:
              Platform.environment['TAMTOOT_LIVE_OLLAMA_URL'] ??
              'http://localhost:11434/api/chat',
        ),
        store: store,
        git: AgentGit(),
        root: Uri.parse('memory:///isolated/'),
        apiKey: '',
        hooks: NoHooks(),
        approve: (_, _) async => true,
        onEvent: (event) {
          // ignore: avoid_print
          print('${event.type}: ${event.text}');
        },
      );
      final result = await runner.run(
        'Создай минимальный консольный проект C# 8 для Debian: Program.cs и Hello.csproj. Выведи Привет мир. Используй LangVersion 8.0 и TargetFramework net8.0. Прочитай созданные файлы для проверки. Сборку не запускай.',
        const AgentRunOptions(
          yolo: false,
          maxIterations: 10,
          timeout: Duration(seconds: 120),
          localResponseFormat: 'json_schema',
        ),
      );
      expect(result.success, true);
      expect(await store.exists('Program.cs'), true);
      expect(
        (await store.listFiles('')).any((p) => p.endsWith('.csproj')),
        true,
      );
    },
    skip: Platform.environment['TAMTOOT_LIVE_OLLAMA_URL'] == null,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
