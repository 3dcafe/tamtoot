import 'dart:async';
import 'dart:convert';
import '../../platform/dotnet_process.dart';
import '../../platform/flutter_process_types.dart';
import '../flutter/flutter_runner.dart';
import '../projects/project_detection.dart';

class DotnetRunner {
  DotnetRunner({required this.log, required this.changed});
  final void Function(String) log;
  final void Function() changed;
  bool active = false, checking = false;
  String? sdkResult;
  FlutterToolProcess? _process;
  FlutterToolProcess? _checkProcess;
  final List<StreamSubscription<String>> _output = [];
  bool _disposed = false;
  int _generation = 0;
  void _notify() {
    if (!_disposed) changed();
  }

  Future<void> testSdk(String path) async {
    if (checking || active || !supportsFlutterTools) return;
    checking = true;
    sdkResult = null;
    _notify();
    FlutterToolProcess? process;
    try {
      final executable = await resolveDotnet(path);
      process = await startDotnetProcess(executable, ['--list-sdks'], null);
      _checkProcess = process;
      if (_disposed) {
        process.kill();
        return;
      }
      final stdout = utf8.decoder.bind(process.stdout).join();
      final stderr = utf8.decoder.bind(process.stderr).join();
      final code = await process.exitCode.timeout(const Duration(seconds: 30));
      final out = await stdout;
      final err = await stderr;
      if (code != 0 || out.trim().isEmpty) {
        throw StateError('No usable SDK found (exit $code). $err');
      }
      sdkResult = '.NET SDK ready: $executable\n${out.trim()}';
    } catch (e) {
      process?.kill();
      sdkResult = '.NET SDK test failed: $e';
    } finally {
      _checkProcess = null;
      checking = false;
      _notify();
    }
  }

  Future<void> start(
    String path,
    LaunchTarget target, {
    bool watch = false,
  }) async {
    if (active || checking || !supportsFlutterTools) return;
    if (target.kind != ProjectKind.dotnet || target.root.scheme != 'file') {
      return;
    }
    active = true;
    final generation = ++_generation;
    _notify();
    try {
      final executable = await resolveDotnet(path);
      if (generation != _generation || _disposed) return;
      final args = watch
          ? [
              'watch',
              '--project',
              target.file,
              'run',
              '--configuration',
              'Debug',
            ]
          : ['run', '--project', target.file, '--configuration', 'Debug'];
      log(
        '.NET: $executable ${args.join(' ')}\nProject: ${target.root.toFilePath()}',
      );
      final process = await startDotnetProcess(
        executable,
        args,
        target.root.toFilePath(),
      );
      if (generation != _generation || _disposed) {
        process.kill();
        return;
      }
      _process = process;
      final drained = <Future<void>>[];
      for (final stream in [process.stdout, process.stderr]) {
        final done = Completer<void>();
        drained.add(done.future);
        _output.add(
          utf8.decoder
              .bind(stream)
              .transform(const LineSplitter())
              .listen(
                (line) {
                  if (!_disposed) log(line);
                },
                onError: (Object e) {
                  if (!_disposed) log('.NET output: $e');
                },
                onDone: () => done.complete(),
              ),
        );
      }
      final code = await process.exitCode;
      await Future.wait(
        drained,
      ).timeout(const Duration(seconds: 5), onTimeout: () => <void>[]);
      if (!_disposed) log('.NET exited with code $code');
    } catch (e) {
      if (!_disposed) log('.NET launch failed: $e');
    } finally {
      if (generation == _generation) {
        for (final subscription in _output) {
          await subscription.cancel();
        }
        _output.clear();
        _process = null;
        active = false;
        _notify();
      }
    }
  }

  Future<void> stop() async {
    ++_generation;
    final process = _process;
    _process = null;
    active = false;
    _notify();
    if (process == null) return;
    if (!_disposed) log('Stopping .NET…');
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 6));
    } catch (_) {
      process.kill();
    }
    for (final subscription in List<StreamSubscription<String>>.from(_output)) {
      await subscription.cancel();
    }
    _output.clear();
  }

  Future<void> dispose() async {
    _disposed = true;
    _checkProcess?.kill();
    await stop();
  }
}
