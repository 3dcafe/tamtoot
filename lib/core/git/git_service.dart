/// Git client contract. Implemented via Smart HTTP (pure Dart) on mobile /
/// desktop — no system `git` binary required.
library;

/// Outcome of one git operation.
class GitResult {
  const GitResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.arguments,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final List<String> arguments;

  bool get ok => exitCode == 0;

  String get message {
    final err = stderr.trim();
    if (err.isNotEmpty) return err;
    final out = stdout.trim();
    if (out.isNotEmpty) return out;
    return 'git exited with code $exitCode';
  }

  void ensureOk() {
    if (!ok) {
      throw GitException(message, result: this);
    }
  }
}

class GitException implements Exception {
  GitException(this.message, {this.result});
  final String message;
  final GitResult? result;
  @override
  String toString() => 'GitException: $message';
}

/// Optional HTTPS credentials. Prefer a token; never log these values.
class GitCredentials {
  const GitCredentials({this.username, this.password, this.token});

  /// Basic auth user. Ignored when [token] is set.
  final String? username;

  /// Basic auth password. Ignored when [token] is set.
  final String? password;

  /// Personal access token. Sent as HTTPS password (user `git` or [username]).
  final String? token;

  bool get isEmpty =>
      (token == null || token!.isEmpty) &&
      (password == null || password!.isEmpty);
}

/// One line from porcelain-style status.
class GitStatusEntry {
  const GitStatusEntry(this.index, this.workTree, this.path, {this.renameFrom});

  final String index;
  final String workTree;
  final String path;
  final String? renameFrom;

  bool get isUntracked => index == '?' && workTree == '?';
  bool get isIgnored => index == '!' && workTree == '!';
  bool get isChanged => !isIgnored;
}

/// Parse `git status --porcelain` (non-`-z`) output into entries.
List<GitStatusEntry> parseGitStatusPorcelain(String stdout) {
  final entries = <GitStatusEntry>[];
  for (final raw in stdout.split('\n')) {
    if (raw.length < 4) continue;
    final index = raw.substring(0, 1);
    final workTree = raw.substring(1, 2);
    var rest = raw.substring(3);
    String? renameFrom;
    final arrow = rest.indexOf(' -> ');
    if (arrow >= 0 && (index == 'R' || index == 'C')) {
      renameFrom = rest.substring(0, arrow);
      rest = rest.substring(arrow + 4);
    }
    entries.add(GitStatusEntry(index, workTree, rest, renameFrom: renameFrom));
  }
  return entries;
}

/// Embed credentials into an HTTPS remote URL (tests / fallbacks).
Uri gitRemoteWithCredentials(Uri remote, GitCredentials credentials) {
  if (credentials.isEmpty) return remote;
  if (remote.scheme != 'https' && remote.scheme != 'http') {
    throw ArgumentError(
      'Credentials embedding is only supported for http(s) remotes',
    );
  }
  final token = credentials.token;
  final userInfo = token != null && token.isNotEmpty
      ? '${Uri.encodeComponent(credentials.username ?? 'git')}:'
            '${Uri.encodeComponent(token)}'
      : '${Uri.encodeComponent(credentials.username ?? '')}:'
            '${Uri.encodeComponent(credentials.password ?? '')}';
  return remote.replace(userInfo: userInfo);
}

/// Minimal git client: clone / fetch / pull / push / status over HTTPS.
abstract interface class GitDiagnosticsProvider {
  set diagnosticLog(void Function(String)? log);
  Future<GitResult> checkConnection(
    Uri remote, {
    GitCredentials? credentials,
    String? branch,
  });
}

class GitProgress {
  const GitProgress(
    this.stage, {
    this.completed = 0,
    this.total,
    this.unit = '',
  });
  final String stage;
  final int completed;
  final int? total;
  final String unit;
  double? get fraction =>
      total != null && total! > 0 ? (completed / total!).clamp(0.0, 1.0) : null;
}

abstract interface class GitProgressProvider {
  set onProgress(void Function(GitProgress)? callback);
}

abstract interface class GitService {
  /// `true` when this platform can run the HTTP git client.
  bool get available;

  Future<GitResult> version();

  Future<bool> isRepository(Uri directory);

  /// Creates a local `.git` directory with [branch] as HEAD (no commits yet).
  Future<GitResult> init(Uri directory, {String branch = 'main'});

  Future<GitResult> clone(
    Uri remote,
    Uri directory, {
    GitCredentials? credentials,
    String? branch,
    bool shallow = false,
  });

  Future<GitResult> fetch(
    Uri directory, {
    GitCredentials? credentials,
    String remote = 'origin',
  });

  Future<GitResult> pull(
    Uri directory, {
    GitCredentials? credentials,
    String remote = 'origin',
    String? branch,
  });

  Future<GitResult> push(
    Uri directory, {
    GitCredentials? credentials,
    String remote = 'origin',
    String? branch,
    bool setUpstream = false,
  });

  Future<GitResult> status(Uri directory, {bool porcelain = true});

  Future<List<GitStatusEntry>> statusEntries(Uri directory);

  Future<GitResult> add(Uri directory, {List<String> paths = const ['.']});

  Future<GitResult> commit(
    Uri directory,
    String message, {
    bool allowEmpty = false,
  });

  Future<GitResult> remoteUrl(Uri directory, {String name = 'origin'});

  Future<GitResult> setRemoteUrl(
    Uri directory,
    Uri url, {
    String name = 'origin',
    GitCredentials? credentials,
  });
}

/// Files touched by commits reachable from HEAD but not the locally known
/// upstream. A null [GitPublicationState.upstream] means status is unknown.
class GitPublicationState {
  const GitPublicationState({this.upstream, this.paths = const {}, this.note});
  final String? upstream;
  final Set<String> paths;
  final String? note;
}

/// Optional read-only capability; never fetches or pushes to determine colors.
abstract interface class GitPublicationProvider {
  Future<GitPublicationState> publicationState(Uri directory);
}

/// Optional repository identity configuration used by the commit dialog.
abstract interface class GitIdentityProvider {
  Future<({String name, String email, String branch})> identity(Uri directory);
  Future<void> setIdentity(Uri directory, String name, String email);
}

class GitCommitSummary {
  const GitCommitSummary({
    required this.hash,
    required this.message,
    required this.author,
    required this.committedAt,
    this.authorEmail = '',
    this.committer = '',
  });
  final String hash, message, author;
  final String authorEmail, committer;
  final DateTime? committedAt;
}

class GitCommitFileChange {
  const GitCommitFileChange({required this.path, required this.status});
  final String path;
  final String status;
}

class GitCommitFileSnapshot {
  const GitCommitFileSnapshot({
    required this.path,
    required this.before,
    required this.after,
  });
  final String path;
  final List<int>? before, after;
}

/// Optional local history capability. It never contacts the remote.
abstract interface class GitHistoryProvider {
  Future<List<GitCommitSummary>> history(
    Uri directory, {
    int limit = 50,
    String? startRef,
  });
  Future<List<GitCommitFileChange>> commitChanges(
    Uri directory,
    String commitHash,
  );
  Future<GitCommitFileSnapshot> commitFileSnapshot(
    Uri directory,
    String commitHash,
    String path,
  );
}

/// Snapshot used for review and optimistic concurrency checks when discarding.
class GitFileSnapshot {
  const GitFileSnapshot({
    required this.directory,
    required this.path,
    required this.head,
    required this.original,
    required this.working,
  });
  final Uri directory;
  final String path;
  final String? head;
  final List<int>? original, working;
}

abstract interface class GitFileChangesProvider {
  Future<GitFileSnapshot> fileSnapshot(Uri directory, String path);
  Future<void> discardFile(GitFileSnapshot snapshot);
}
