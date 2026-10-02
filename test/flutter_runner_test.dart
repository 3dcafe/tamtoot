import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/flutter/dap_client.dart';
import 'package:tamtoot/core/flutter/flutter_runner.dart';
import 'package:tamtoot/core/settings/settings.dart';
import 'package:tamtoot/platform/flutter_process.dart';

class AdapterProcess implements FlutterToolProcess {
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final exit = Completer<int>();
  final decoder = DapDecoder();
  final requests = <Map<String, dynamic>>[];
  String? failCommand;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exit.future;
  void event(String name, [Map<String, dynamic> body = const {}]) => output.add(
    encodeDap({'seq': 0, 'type': 'event', 'event': name, 'body': body}),
  );
  @override
  void write(List<int> bytes) {
    for (final request in decoder.add(bytes)) {
      requests.add(request);
      final command = request['command'];
      final body = switch (command) {
        'threads' => {
          'threads': [
            {'id': 42, 'name': 'main'},
          ],
        },
        'stackTrace' => {
          'stackFrames': [
            {'id': 7, 'name': 'main', 'line': 3},
          ],
        },
        'scopes' => {
          'scopes': [
            {'name': 'Local', 'variablesReference': 1, 'expensive': false},
          ],
        },
        'variables' => {
          'variables': [
            {'name': 'counter', 'value': '2', 'variablesReference': 0},
          ],
        },
        'setBreakpoints' => {
          'breakpoints': [
            {'verified': true},
          ],
        },
        _ => <String, dynamic>{},
      };
      output.add(
        encodeDap({
          'seq': 1,
          'type': 'response',
          'request_seq': request['seq'],
          'command': command,
          'success': command != failCommand,
          'message': 'test rejection',
          'body': body,
        }),
      );
      if (command == 'initialize') event('initialized');
      if (command == 'launch' && failCommand != 'launch') {
        event('flutter.appStarted');
      }
      if (command == 'disconnect') kill();
    }
  }

  @override
  void kill() {
    if (!exit.isCompleted) {
      exit.complete(0);
      unawaited(output.close());
      unawaited(errors.close());
    }
  }
}

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  test(
    'DAP frames handle arbitrary chunks, multiple messages and UTF-8 lengths',
    () {
      final decoder = DapDecoder();
      final first = {
        'type': 'event',
        'event': 'output',
        'body': {'output': 'Привет 👋'},
      };
      final bytes = [
        ...encodeDap(first),
        ...encodeDap({'type': 'event', 'event': 'initialized'}),
      ];
      final results = <Map<String, dynamic>>[];
      for (final byte in bytes) {
        results.addAll(decoder.add([byte]));
      }
      expect(results, hasLength(2));
      expect(results.first, first);
      expect(
        () =>
            DapDecoder().add(ascii.encode('Content-Length: 20000000\r\n\r\n')),
        throwsFormatException,
      );
    },
  );
  test(
    'SDK settings restore without leaking machine paths into workspace settings',
    () {
      final settings = SettingsService();
      settings.set('flutterSdkPath', '/sdk');
      settings.set('flutterDeviceId', 'linux');
      settings.set('flutterSdkPath', '/other', forWorkspace: true);
      final restored = SettingsService()..restore(settings.encode());
      expect(restored.get('flutterSdkPath'), '/sdk');
      restored.set('flutterSdkPath', '');
      expect(restored.get('flutterSdkPath'), '');
    },
  );
  test('mobile platforms cannot invoke SDK processes', () async {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      debugDefaultTargetPlatformOverride = platform;
      final runner = FlutterRunner(
        log: (_) {},
        changed: () {},
        starter: (_, _, _) async => throw StateError('Must not execute'),
      );
      expect(supportsFlutterTools, false);
      await expectLater(runner.testSdk('/sdk'), throwsUnsupportedError);
      await expectLater(
        runner.start(
          sdk: '/sdk',
          root: Uri.directory('/tmp/'),
          entryPoint: 'lib/main.dart',
          device: '',
          debug: true,
        ),
        throwsUnsupportedError,
      );
      await runner.dispose();
    }
  });

  for (final debug in [true, false]) {
    test(
      'DAP launch, pause, variables, breakpoints and shutdown (debug=$debug)',
      () async {
        final temp = await Directory.systemTemp.createTemp('tamtoot-dap-');
        await File('${temp.path}/pubspec.yaml').writeAsString('name: example');
        await Directory('${temp.path}/lib').create();
        await File(
          '${temp.path}/lib/main.dart',
        ).writeAsString('void main() {}');
        final process = AdapterProcess();
        final logs = <String>[];
        final runner = FlutterRunner(
          log: logs.add,
          changed: () {},
          starter: (sdk, args, cwd) async {
            expect(sdk, '/sdk');
            expect(args, ['debug-adapter']);
            expect(cwd, temp.uri.toFilePath());
            return process;
          },
        );
        try {
          await runner.toggleBreakpoint('${temp.path}/lib/main.dart', 3);
          await runner.start(
            sdk: '/sdk',
            root: temp.uri,
            entryPoint: 'lib/main.dart',
            device: 'linux',
            debug: debug,
          );
          expect(runner.state, FlutterRunState.running);
          final launch = process.requests.firstWhere(
            (r) => r['command'] == 'launch',
          );
          expect(launch['arguments']['noDebug'], !debug);
          expect(launch['arguments']['toolArgs'], ['-d', 'linux']);
          expect(
            process.requests.where((r) => r['command'] == 'setBreakpoints'),
            debug ? hasLength(1) : isEmpty,
          );
          await runner.control('hotReload');
          await runner.control('hotRestart');
          if (debug) {
            await runner.control('pause');
            expect(process.requests.last['arguments']['threadId'], 42);
            process.event('stopped', {'threadId': 42});
            for (var i = 0; i < 20 && runner.variables.isEmpty; i++) {
              await Future<void>.delayed(Duration.zero);
            }
            expect(runner.paused, true);
            expect(runner.variables.single['value'], '2');
            await runner.control('next');
            expect(process.requests.last['arguments']['threadId'], 42);
            process.event('continued');
            await Future<void>.delayed(Duration.zero);
            expect(runner.frames, isEmpty);
          }
          await runner.stop();
          expect(runner.active, false);
          expect(process.exit.isCompleted, true);
        } finally {
          await runner.dispose();
          await temp.delete(recursive: true);
        }
      },
    );
  }
  test(
    'failed launch recovers and adapter errors fail pending requests',
    () async {
      final temp = await Directory.systemTemp.createTemp('tamtoot-dap-fail-');
      await File('${temp.path}/pubspec.yaml').writeAsString('name: example');
      await File('${temp.path}/main.dart').writeAsString('void main() {}');
      final process = AdapterProcess()..failCommand = 'launch';
      final runner = FlutterRunner(
        log: (_) {},
        changed: () {},
        starter: (_, _, _) async => process,
      );
      try {
        await expectLater(
          runner.start(
            sdk: '/sdk',
            root: temp.uri,
            entryPoint: 'main.dart',
            device: '',
            debug: true,
          ),
          throwsStateError,
        );
        expect(runner.active, false);
        await expectLater(
          flutterProjectPath(temp.uri, '../escape.dart'),
          throwsArgumentError,
        );
      } finally {
        await runner.dispose();
        await temp.delete(recursive: true);
      }
    },
  );
  final sdk = Platform.environment['TAMTOOT_TEST_FLUTTER_SDK'];
  test('real SDK version, devices and DAP handshake', () async {
    final runner = FlutterRunner(log: (_) {}, changed: () {});
    await runner.testSdk(sdk!);
    expect(runner.sdkResult, startsWith('Flutter '));
    final process = await startFlutterProcess(sdk, ['debug-adapter'], null);
    final initialized = Completer<void>();
    final client = DapClient(process, (event, body) {
      if (event == 'initialized' && !initialized.isCompleted) {
        initialized.complete();
      }
    }, (_) {});
    try {
      final capabilities = await client.request('initialize', {
        'adapterID': 'flutter',
        'clientID': 'tamtoot',
        'linesStartAt1': true,
        'columnsStartAt1': true,
      });
      expect(capabilities['supportsConfigurationDoneRequest'], true);
      await initialized.future.timeout(const Duration(seconds: 10));
      await client.request('configurationDone');
      await client.request('disconnect', {'terminateDebuggee': true});
    } finally {
      client.close(StateError('Finished'));
      process.kill();
      await runner.dispose();
    }
  }, skip: sdk == null);
}
