import 'git_objects.dart';
import 'git_service.dart';
import 'git_store.dart';

/// Compares commit reachability, not just endpoint trees (handles reverts and
/// diverged branches without coloring remote-only edits as unpublished).
Future<GitPublicationState> readPublicationState(GitObjectDatabase db) async {
  final store = db.store;
  if (!await store.exists('.git/HEAD') || !await store.exists('.git/config')) {
    return const GitPublicationState(note: 'No upstream configured');
  }
  final headText = (await store.readText('.git/HEAD')).trim();
  if (!headText.startsWith('ref: refs/heads/')) {
    return const GitPublicationState(note: 'Detached HEAD: no upstream');
  }
  final branch = headText.substring('ref: refs/heads/'.length);
  final config = await store.readText('.git/config');
  final section = RegExp(
    '\\[branch "${RegExp.escape(branch)}"\\]([^\\[]*)',
  ).firstMatch(config)?.group(1);
  String? setting(String key) => section == null
      ? null
      : RegExp(
          '^\\s*$key\\s*=\\s*(.+)\$',
          multiLine: true,
        ).firstMatch(section)?.group(1)?.trim();
  final remote = setting('remote'), merge = setting('merge');
  if (remote == null || merge == null || !merge.startsWith('refs/heads/')) {
    return const GitPublicationState(note: 'No upstream configured');
  }
  final upstream = remote == '.'
      ? merge
      : 'refs/remotes/$remote/${merge.substring(11)}';
  final upstreamHash = await db.readRef(upstream), head = await db.readHead();
  if (upstreamHash == null || head == null) {
    return const GitPublicationState(
      note: 'Upstream history unavailable; fetch to update it',
    );
  }
  if (head == upstreamHash) return GitPublicationState(upstream: upstream);
  final commits = <String, CommitInfo>{};
  Future<CommitInfo> commit(String hash) async =>
      commits[hash] ??= parseCommit((await db.read(hash)).content);
  Future<Set<String>> reachable(String start, Set<String> stop) async {
    final seen = <String>{}, pending = [start];
    while (pending.isNotEmpty) {
      final hash = pending.removeLast();
      if (stop.contains(hash) || !seen.add(hash)) continue;
      if (seen.length > 10000) {
        throw GitException(
          'History exceeds the Explorer status limit (10000 commits)',
        );
      }
      pending.addAll((await commit(hash)).parents);
    }
    return seen;
  }

  final remoteCommits = await reachable(upstreamHash, {});
  final localOnly = await reachable(head, remoteCommits);
  final trees = <String, Map<String, String>>{};
  Future<Map<String, String>> files(String treeHash) async {
    if (trees.containsKey(treeHash)) return trees[treeHash]!;
    final out = <String, String>{};
    for (final entry in parseTree((await db.read(treeHash)).content)) {
      if (entry.isTree) {
        for (final child in (await files(entry.hash)).entries) {
          out['${entry.name}/${child.key}'] = child.value;
        }
      } else {
        out[entry.name] = '${entry.mode}:${entry.hash}';
      }
    }
    return trees[treeHash] = out;
  }

  final paths = <String>{};
  for (final hash in localOnly) {
    final info = await commit(hash),
        after = await files((await commit(hash)).tree);
    final before = info.parents.isEmpty
        ? <String, String>{}
        : await files((await commit(info.parents.first)).tree);
    for (final path in {...before.keys, ...after.keys}) {
      if (before[path] != after[path]) paths.add(path);
    }
  }
  return GitPublicationState(upstream: upstream, paths: paths);
}
