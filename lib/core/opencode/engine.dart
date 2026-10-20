import 'config.dart';
import 'runner.dart';
import 'session.dart';

export 'runner.dart' show AgentMode;

/// In-process port of the opencode agent engine (model routing, session
/// loop, tools). Exposes the same surface the Tamtoot UI consumed from the
/// `opencode serve` HTTP API, so panels work unchanged against a local
/// engine — no external CLI required.

class OpencodeException implements Exception {
  const OpencodeException(this.message);
  final String message;
  @override
  String toString() => message;
}

class OpencodeEngine {
  OpencodeEngine._(this.projectRoot) : _store = SessionStore(projectRoot);

  final String projectRoot;
  final SessionStore _store;
  OpencodeConfig? _config;
  SessionRunner? _runner;

  static final _instances = <String, OpencodeEngine>{};

  /// One engine per project root, mirroring one opencode server per project.
  static OpencodeEngine forProject(String projectRoot) =>
      _instances.putIfAbsent(projectRoot, () => OpencodeEngine._(projectRoot));

  /// Drop the cached engine (the panel's "restart" action): configuration
  /// and sessions reload from disk on next use.
  static void restart(String projectRoot) => _instances.remove(projectRoot);

  Future<OpencodeConfig> readConfig() async =>
      _config ??= await OpencodeConfig.load(projectRoot);

  /// Persist a new configuration and drop the runner so the next prompt
  /// picks it up (the settings editor saves through here). Global saves
  /// apply to every project; a project file overrides the global one.
  Future<void> saveConfig(OpencodeConfig config, {bool global = false}) async {
    if (global) {
      await config.saveGlobal();
    } else {
      await config.save(projectRoot);
    }
    _config = null; // reload so the global/project overlay is re-merged
    _runner = null;
  }

  Future<SessionRunner> _resolveRunner() async {
    final existing = _runner;
    if (existing != null) return existing;
    final runner = SessionRunner(
      root: projectRoot,
      config: await readConfig(),
      store: _store,
    );
    _runner = runner;
    return runner;
  }

  Future<List<Map<String, dynamic>>> sessions() async => [
    for (final session in await _store.list()) session.summaryJson(),
  ];

  Future<String> createSession({String? title}) async =>
      (await _store.create(title: title ?? 'Tamtoot session')).id;

  Future<void> deleteSession(String id) async {
    await _runner?.stop(id);
    await _store.delete(id);
  }

  Future<List<Map<String, dynamic>>> messages(String sessionId) async {
    final session = await _store.get(sessionId);
    if (session == null) return const [];
    return [for (final message in session.messages) message.toJson()];
  }

  /// Fire-and-forget prompt; progress is observed by polling [messages] and
  /// [sessionStatus], exactly like opencode's `/session/:id/prompt_async`.
  Future<void> promptAsync(
    String sessionId,
    String text, {
    String? providerId,
    String? modelId,
    String? agent,
    AgentMode mode = AgentMode.agent,
  }) async {
    final session = await _store.get(sessionId);
    if (session == null) {
      throw OpencodeException('Session not found: $sessionId');
    }
    final runner = await _resolveRunner();
    try {
      await runner.prompt(session, text, mode: mode);
    } on Exception catch (e) {
      throw OpencodeException('$e');
    }
  }

  Future<void> abort(String sessionId) async {
    final runner = await _resolveRunner();
    runner.abort(sessionId);
  }

  /// Map of session id → status (`idle` | `busy`), the port of
  /// `GET /session/status`.
  Future<Map<String, dynamic>> sessionStatus() async {
    final runner = await _resolveRunner();
    final result = <String, dynamic>{};
    for (final session in await _store.list()) {
      result[session.id] = {
        'type': runner.isBusy(session.id) ? 'busy' : 'idle',
      };
    }
    return result;
  }

  /// Configured providers plus live Ollama model discovery, the port of
  /// `GET /config/providers`.
  Future<Map<String, dynamic>> providers() async {
    final config = await readConfig();
    final ollamaModels = await OpencodeConfig.discoverOllamaModels(
      config.providers['ollama'],
    );
    final providers = <Map<String, dynamic>>[
      for (final provider in config.providers.values)
        {
          'id': provider.id,
          'name': provider.displayName,
          'models': {
            for (final model
                in provider.type == 'ollama' ? ollamaModels : provider.models)
              model: {'name': model},
          },
        },
    ];
    final resolved = await config.resolveModel();
    return {
      'providers': providers,
      'default': {if (resolved != null) resolved.provider.id: resolved.model},
    };
  }

  /// MCP servers are not ported yet; report an empty status rather than
  /// failing the panel.
  Future<Map<String, dynamic>> mcpStatus() async => const {};
}
