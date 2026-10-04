import 'dart:async';
import 'dart:io';

/// Terminates [process] and its descendants.
///
/// On Windows uses `taskkill /T /F`. On POSIX: SIGINT (graceful for CLIs),
/// then SIGTERM to the tree, then SIGKILL if still alive.
Future<void> terminateProcessTree(
  Process process, {
  bool interruptFirst = true,
}) async {
  final pid = process.pid;
  if (pid <= 0) return;

  if (Platform.isWindows) {
    try {
      final result = await Process.run(
        '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\taskkill.exe',
        ['/PID', '$pid', '/T', '/F'],
        runInShell: false,
      );
      if (result.exitCode == 0) return;
    } catch (_) {}
    process.kill();
    return;
  }

  if (interruptFirst) {
    Process.killPid(pid, ProcessSignal.sigint);
    if (await _exited(process, const Duration(milliseconds: 1500))) return;
  }

  var tree = await _processTree(pid);
  for (final p in tree) {
    Process.killPid(p, ProcessSignal.sigterm);
  }
  if (await _exited(process, const Duration(seconds: 2))) return;

  tree = await _processTree(pid);
  for (final p in tree) {
    Process.killPid(p, ProcessSignal.sigkill);
  }
}

Future<bool> _exited(Process process, Duration timeout) async {
  try {
    await process.exitCode.timeout(timeout);
    return true;
  } on TimeoutException {
    return false;
  } catch (_) {
    return true;
  }
}

/// [rootPid] plus descendants (children first for kill order).
Future<List<int>> _processTree(int rootPid) async {
  final descendants = <int>[];
  Future<void> walk(int pid) async {
    for (final child in await _directChildren(pid)) {
      await walk(child);
      descendants.add(child);
    }
  }

  await walk(rootPid);
  return [...descendants, rootPid];
}

Future<List<int>> _directChildren(int pid) async {
  try {
    final result = await Process.run('pgrep', [
      '-P',
      '$pid',
    ], runInShell: false);
    if (result.exitCode != 0) return const [];
    return (result.stdout as String)
        .split(RegExp(r'\s+'))
        .map((part) => int.tryParse(part.trim()))
        .whereType<int>()
        .where((child) => child > 0 && child != pid)
        .toList();
  } catch (_) {
    return const [];
  }
}
