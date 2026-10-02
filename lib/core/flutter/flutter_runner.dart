import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../platform/flutter_process.dart';
import 'dap_client.dart';

bool get supportsFlutterTools =>
    !kIsWeb &&
    const {
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    }.contains(defaultTargetPlatform);
String get defaultFlutterDevice => switch (defaultTargetPlatform) {
  TargetPlatform.windows => 'windows',
  TargetPlatform.linux => 'linux',
  _ => 'macos',
};

enum FlutterRunState { idle, launching, running, paused, stopping }

class FlutterRunner {
  FlutterRunner({
    required this.log,
    required this.changed,
    FlutterProcessStarter? starter,
  }) : starter = starter ?? startFlutterProcess;
  final void Function(String) log;
  final VoidCallback changed;
  final FlutterProcessStarter starter;
  FlutterRunState state = FlutterRunState.idle;
  bool checking = false;
  bool debugging = false;
  bool disposed = false;
  String? sdkResult;
  List<Map<String, dynamic>> devices = [];
  final Map<String, Set<int>> breakpoints = {};
  List<Map<String, dynamic>> frames = [];
  List<Map<String, dynamic>> variables = [];
  int? selectedFrame;
  int? threadId;
  int _pauseRevision = 0;
  int _generation = 0;
  FlutterToolProcess? _process, _probe;
  DapClient? _client;
  bool get active => state != FlutterRunState.idle;
  bool get paused => state == FlutterRunState.paused;
  void _changed() {
    if (!disposed) changed();
  }

  Future<String> _capture(String sdk, List<String> args) async {
    final process = await starter(sdk, args, null);
    if (disposed) {
      process.kill();
      throw StateError('Flutter tools closed');
    }
    _probe = process;
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    try {
      final values = await Future.wait<Object>([
        process.exitCode,
        out,
        err,
      ]).timeout(const Duration(seconds: 60));
      if (values[0] != 0) {
        throw StateError('${args.join(' ')}: ${values[2]} ${values[1]}');
      }
      return values[1] as String;
    } finally {
      process.kill();
      if (identical(_probe, process)) _probe = null;
    }
  }

  Future<void> testSdk(String sdk) async {
    if (!supportsFlutterTools) throw UnsupportedError('Desktop only');
    if (checking || active) {
      throw StateError('Stop the current session before testing the SDK');
    }
    checking = true;
    sdkResult = null;
    devices = [];
    _changed();
    try {
      final version =
          jsonDecode(await _capture(sdk, ['--version', '--machine'])) as Map;
      if (version['frameworkVersion'] is! String) {
        throw const FormatException('Unexpected Flutter version response');
      }
      sdkResult =
          'Flutter ${version['frameworkVersion']} · Dart ${version['dartSdkVersion']}';
      log(sdkResult!);
      try {
        final items =
            jsonDecode(await _capture(sdk, ['devices', '--machine'])) as List;
        devices = items
            .cast<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        log(
          'Available Flutter devices: ${devices.map((item) => item['id']).join(', ')}',
        );
      } catch (e) {
        sdkResult = '$sdkResult\nDevice detection failed: $e';
      }
    } catch (e) {
      sdkResult = 'SDK test failed: $e';
      log(sdkResult!);
    } finally {
      checking = false;
      _changed();
    }
  }

  Future<void> start({
    required String sdk,
    required Uri root,
    required String entryPoint,
    required String device,
    required bool debug,
  }) async {
    if (!supportsFlutterTools) throw UnsupportedError('Desktop only');
    if (disposed || active || checking) {
      throw StateError('Flutter tools are busy');
    }
    final generation = ++_generation;
    state = FlutterRunState.launching;
    debugging = debug;
    _changed();
    try {
      final program = await flutterProjectPath(root, entryPoint);
      if (generation != _generation || disposed) return;
      final process = await starter(sdk, ['debug-adapter'], root.toFilePath());
      if (generation != _generation || disposed) {
        process.kill();
        return;
      }
      _process = process;
      final initialized = Completer<void>();
      final client = DapClient(process, (event, body) {
        if (!identical(_process, process)) return;
        if (event == 'initialized' && !initialized.isCompleted) {
          initialized.complete();
        }
        _event(event, body);
      }, log);
      _client = client;
      unawaited(
        process.exitCode.then((code) {
          if (identical(_process, process)) {
            log('Flutter session ended ($code)');
            _reset();
            if (!initialized.isCompleted) {
              initialized.completeError(
                StateError('Adapter exited before initialization'),
              );
            }
          }
        }),
      );
      // Attach an error handler before initialize can fail/exit.
      final ready = initialized.future.timeout(const Duration(seconds: 30));
      unawaited(ready.catchError((Object _) {}));
      await client.request('initialize', {
        'clientID': 'tamtoot',
        'adapterID': 'flutter',
        'linesStartAt1': true,
        'columnsStartAt1': true,
        'pathFormat': 'path',
        'supportsRunInTerminalRequest': false,
      });
      await ready;
      if (debug) {
        for (final source in breakpoints.keys) {
          await _sendBreakpoints(source);
        }
        await client.request('setExceptionBreakpoints', {
          'filters': ['Unhandled'],
        });
      }
      await client.request('configurationDone');
      await client.request('launch', {
        'cwd': root.toFilePath(),
        'program': program,
        'noDebug': !debug,
        'toolArgs': ['-d', device.isEmpty ? defaultFlutterDevice : device],
        'console': 'internalConsole',
        'debugSdkLibraries': false,
      }, const Duration(minutes: 5));
      if (identical(_client, client) && state == FlutterRunState.launching) {
        state = FlutterRunState.running;
        _changed();
      }
    } catch (e) {
      if (generation == _generation) await stop();
      rethrow;
    }
  }

  void _event(String event, Map<String, dynamic> body) {
    if (event == 'output') {
      final text = body['output'];
      if (text is String && text.trim().isNotEmpty) log(text.trimRight());
    }
    if (event == 'flutter.appStarted' && state == FlutterRunState.launching) {
      state = FlutterRunState.running;
    }
    if (event == 'continued') {
      state = FlutterRunState.running;
      _clearPause();
    }
    if (event == 'stopped') {
      state = FlutterRunState.paused;
      threadId = body['threadId'] as int?;
      unawaited(
        _loadStack().catchError((Object e) {
          log('Debug stack: $e');
        }),
      );
    }
    if (event == 'terminated' && state != FlutterRunState.stopping) {
      unawaited(stop());
    }
    _changed();
  }

  Future<void> _loadStack() async {
    final revision = ++_pauseRevision;
    final client = _client;
    if (client == null || threadId == null) return;
    final body = await client.request('stackTrace', {
      'threadId': threadId,
      'levels': 30,
    });
    if (!paused || revision != _pauseRevision || !identical(client, _client)) {
      return;
    }
    frames = (body['stackFrames'] as List? ?? [])
        .cast<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    _changed();
    if (frames.isNotEmpty) await selectFrame(frames.first['id'] as int);
  }

  Future<void> selectFrame(int frameId) async {
    final client = _client;
    final revision = _pauseRevision;
    if (!paused || client == null) return;
    selectedFrame = frameId;
    variables = [];
    _changed();
    final scopes = await client.request('scopes', {'frameId': frameId});
    final collected = <Map<String, dynamic>>[];
    for (final scope in (scopes['scopes'] as List? ?? []).cast<Map>()) {
      if (scope['expensive'] == true) continue;
      final body = await client.request('variables', {
        'variablesReference': scope['variablesReference'],
      });
      collected.addAll(
        (body['variables'] as List? ?? []).cast<Map>().map(
          (v) => Map<String, dynamic>.from(v),
        ),
      );
    }
    if (paused && revision == _pauseRevision && selectedFrame == frameId) {
      variables = collected;
      _changed();
    }
  }

  Future<List<Map<String, dynamic>>> children(int reference) async {
    final body = await _client!.request('variables', {
      'variablesReference': reference,
    });
    return (body['variables'] as List? ?? [])
        .cast<Map>()
        .map((v) => Map<String, dynamic>.from(v))
        .toList();
  }

  Future<void> toggleBreakpoint(String path, int line) async {
    final lines = breakpoints.putIfAbsent(path, () => <int>{});
    if (!lines.remove(line)) lines.add(line);
    _changed();
    if (_client != null && debugging) await _sendBreakpoints(path);
    if (lines.isEmpty) breakpoints.remove(path);
  }

  Future<void> _sendBreakpoints(String path) async {
    final lines = (breakpoints[path] ?? {}).toList()..sort();
    final response = await _client!.request('setBreakpoints', {
      'source': {'path': path},
      'breakpoints': [
        for (final line in lines) {'line': line},
      ],
    });
    for (final point in (response['breakpoints'] as List? ?? []).cast<Map>()) {
      if (point['verified'] != true) {
        log(
          'Breakpoint pending: $path:${point['line'] ?? '?'} ${point['message'] ?? ''}',
        );
      }
    }
  }

  Future<void> control(String command) async {
    final client = _client;
    if (client == null) return;
    if (command == 'pause') {
      final body = await client.request('threads');
      final threads = body['threads'] as List? ?? [];
      if (threads.isEmpty) throw StateError('No running Dart thread');
      await client.request('pause', {'threadId': (threads.first as Map)['id']});
      return;
    }
    await client.request(command, switch (command) {
      'hotReload' || 'hotRestart' => {'reason': 'manual'},
      _ => {'threadId': threadId},
    });
  }

  void _clearPause() {
    _pauseRevision++;
    threadId = null;
    frames = [];
    variables = [];
    selectedFrame = null;
  }

  void _reset() {
    _client?.close(StateError('Flutter session closed'));
    _client = null;
    _process = null;
    state = FlutterRunState.idle;
    debugging = false;
    _clearPause();
    _changed();
  }

  Future<void> stop() async {
    if (state == FlutterRunState.stopping) return;
    _generation++;
    final process = _process;
    state = FlutterRunState.stopping;
    _changed();
    try {
      if (_client != null) {
        await _client!.request('disconnect', {
          'terminateDebuggee': true,
        }, const Duration(seconds: 5));
      }
      if (process != null) {
        await process.exitCode.timeout(const Duration(seconds: 5));
      }
    } catch (_) {
      process?.kill();
    } finally {
      _reset();
    }
  }

  Future<void> dispose() async {
    disposed = true;
    _probe?.kill();
    await stop();
  }
}
