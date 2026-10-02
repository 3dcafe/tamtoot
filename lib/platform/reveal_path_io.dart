import 'dart:io';

/// Reveals [path] in Finder (macOS), Explorer (Windows), or the parent folder
/// via xdg-open (Linux).
Future<void> revealInFileManager(String path) async {
  if (path.trim().isEmpty) return;
  if (Platform.isMacOS) {
    await Process.run('open', ['-R', path], runInShell: false);
    return;
  }
  if (Platform.isWindows) {
    await Process.run('explorer', ['/select,', path], runInShell: false);
    return;
  }
  if (Platform.isLinux) {
    final parent = File(path).parent.path;
    await Process.run('xdg-open', [parent], runInShell: false);
  }
}
