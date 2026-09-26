import 'dart:io';

import '../core/workspace/tamtoot_meta.dart';

Future<void> writeTamtootProjectMeta(Uri root, TamtootProjectMeta meta) async {
  final dir = Directory.fromUri(
    root.resolve('${TamtootProjectMeta.directoryName}/'),
  );
  await dir.create(recursive: true);
  final file = File.fromUri(root.resolve(TamtootProjectMeta.relativePath));
  await file.writeAsString(meta.encode(), flush: true);
}

Future<TamtootProjectMeta?> readTamtootProjectMeta(Uri root) async {
  final file = File.fromUri(root.resolve(TamtootProjectMeta.relativePath));
  if (!await file.exists()) return null;
  try {
    return TamtootProjectMeta.parse(await file.readAsString());
  } catch (_) {
    return null;
  }
}

Future<bool> hasGitDirectory(Uri root) async {
  final head = File.fromUri(root.resolve('.git/HEAD'));
  return head.exists();
}

Future<String?> readGitHeadRef(Uri root) async {
  final head = File.fromUri(root.resolve('.git/HEAD'));
  if (!await head.exists()) return null;
  final text = (await head.readAsString()).trim();
  if (text.startsWith('ref: ')) return text.substring(5);
  return text;
}
