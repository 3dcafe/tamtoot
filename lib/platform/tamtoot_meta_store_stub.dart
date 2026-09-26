import '../core/workspace/tamtoot_meta.dart';

Future<void> writeTamtootProjectMeta(Uri root, TamtootProjectMeta meta) async {
  // Web has no durable workspace FS yet; keep the API so call sites stay shared.
}

Future<TamtootProjectMeta?> readTamtootProjectMeta(Uri root) async => null;

Future<bool> hasGitDirectory(Uri root) async => false;

Future<String?> readGitHeadRef(Uri root) async => null;
