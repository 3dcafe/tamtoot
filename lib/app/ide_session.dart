import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/commands/commands.dart';
import '../core/completion/project_completion.dart';
import '../core/filesystem/filesystem.dart';
import '../core/git/git_service.dart';
import '../core/git/http_git_service.dart';
import '../core/persistence/schema.dart';
import '../core/settings/settings.dart';
import '../core/themes/ide_theme.dart';
import '../core/workspace/tamtoot_meta.dart';
import '../languages/language_registry.dart';
import '../platform/tamtoot_meta_store.dart';
import '../workspace/documents/document_service.dart';
import '../workspace/layout/dock_layout.dart';
import '../workspace/explorer/explorer_tree.dart';
import '../workspace/explorer/file_indicators.dart';

/// Application orchestration. UI observes events through a Riverpod adapter.
class IdeSession {
  IdeSession({required this.store, required this.documents, required this.git});
  final PersistenceStore store;
  final DocumentService documents;
  final GitService git;
  final commands = CommandRegistry();
  KeybindingRegistry keys = KeybindingRegistry();
  final settings = SettingsService();
  final languages = LanguageRegistry();
  final Map<String, IdeTheme> themes = {};
  DockLayout layout = DockLayout.defaultLayout;
  final _events = StreamController<int>.broadcast(sync: true);
  Stream<int> get changes => _events.stream;
  int _revision = 0;
  final List<String> output = [];
  final List<String> errors = [];
  final List<String> recentWorkspaces = [];
  Uri? workspaceRoot;
  ProjectCompletionIndex? completionIndex;
  late final explorer = ExplorerTree(
    documents.files.list,
    () => changed(persist: false),
  );
  List<FileEntry> get entries => explorer.children[workspaceRoot] ?? [];
  Map<String, GitStatusEntry> _gitEntries = {};
  Set<String> _unpublished = {};
  String? gitStatusNote;
  int _gitStatusRevision = 0;
  int get gitStatusRevision => _gitStatusRevision;
  bool _refreshingGit = false;
  Timer? _gitTimer;

  bool _sameGitEntry(GitStatusEntry a, GitStatusEntry b) =>
      a.index == b.index &&
      a.workTree == b.workTree &&
      a.path == b.path &&
      a.renameFrom == b.renameFrom;

  bool _sameGitState(
    Map<String, GitStatusEntry> status,
    Set<String> unpublished,
    String? note,
  ) {
    if (gitStatusNote != note ||
        _gitEntries.length != status.length ||
        _unpublished.length != unpublished.length ||
        !_unpublished.every(unpublished.contains)) {
      return false;
    }
    for (final entry in status.entries) {
      final current = _gitEntries[entry.key];
      if (current == null || !_sameGitEntry(current, entry.value)) return false;
    }
    return true;
  }

  void _setGitState(
    Map<String, GitStatusEntry> status,
    Set<String> unpublished,
    String? note,
  ) {
    if (_sameGitState(status, unpublished, note)) return;
    _gitEntries = status;
    _unpublished = unpublished;
    gitStatusNote = note;
    _gitStatusRevision++;
    changed(persist: false);
  }

  FileIndicators indicators(
    Uri? uri, {
    bool directory = false,
    bool unsaved = false,
  }) {
    if (uri == null) return FileIndicators(unsaved: unsaved);
    bool matches(Uri candidate) =>
        candidate == uri ||
        (directory &&
            candidate.toString().startsWith(
              '${uri.toString().replaceAll(RegExp(r'/+$'), '')}/',
            ));
    final root = workspaceRoot;
    Uri pathUri(String path) =>
        root!.resolve(path.split('/').map(Uri.encodeComponent).join('/'));
    final states = root == null
        ? <GitStatusEntry>[]
        : _gitEntries.entries
              .where((e) => matches(pathUri(e.key)))
              .map((e) => e.value);
    return FileIndicators(
      unsaved:
          unsaved ||
          documents.documents.any(
            (d) => d.uri != null && matches(d.uri!) && d.dirty,
          ),
      modified: states.any((e) => !e.isUntracked && e.isChanged),
      untracked: states.any((e) => e.isUntracked),
      unpublished:
          root != null && _unpublished.any((path) => matches(pathUri(path))),
    );
  }

  Future<void> refreshGitIndicators() async {
    final root = workspaceRoot;
    if (root == null || !git.available || _refreshingGit) return;
    _refreshingGit = true;
    final status = <String, GitStatusEntry>{};
    var unpublished = <String>{};
    String? note;
    try {
      if (await git.isRepository(root)) {
        try {
          for (final entry in await git.statusEntries(root)) {
            final sharedRequestFile =
                entry.path == '.tamtoot/environment.json' ||
                entry.path.startsWith('.tamtoot/requests/');
            if (entry.isChanged &&
                (sharedRequestFile ||
                    (entry.path != '.tamtoot' &&
                        !entry.path.startsWith('.tamtoot/')))) {
              status[entry.path] = entry;
            }
          }
        } catch (error) {
          note = 'Git working-tree status unavailable: $error';
        }
        final provider = git;
        if (provider is GitPublicationProvider) {
          try {
            final state = await (provider as GitPublicationProvider)
                .publicationState(root);
            unpublished = state.paths;
            note ??= state.note;
          } catch (error) {
            note ??= 'Unpublished status unavailable: $error';
          }
        }
      }
      if (workspaceRoot != root || _disposed) return;
      _setGitState(status, unpublished, note);
    } catch (error) {
      if (workspaceRoot == root && !_disposed) {
        _setGitState({}, {}, 'Git status unavailable: $error');
      }
    } finally {
      _refreshingGit = false;
      if (workspaceRoot != root && !_disposed) {
        unawaited(refreshGitIndicators());
      }
    }
  }

  Future<void> refreshExplorer() async {
    await explorer.refresh();
    await refreshGitIndicators();
  }

  Future<void> selectTheme(String id) async {
    if (!themes.containsKey(id)) throw ArgumentError('Unknown theme: $id');
    settings.set('theme', id);
    changed(persist: false);
    // Store immediately; do not wait for the general session debounce.
    await persistNow();
  }

  TamtootProjectMeta? projectMeta;
  bool workspaceHasGit = false;
  bool gitBusy = false;
  String message = 'Ready';
  bool findVisible = false;
  bool replaceVisible = false;
  String findQuery = '', replacement = '';
  final Map<String, StreamSubscription<void>> _subscriptions = {};
  Timer? _saveTimer;
  Future<void> _pendingSave = Future.value();
  bool _disposed = false;
  IdeTheme get theme => themes[settings.theme] ?? themes.values.first;
  void changed({bool persist = true}) {
    if (_disposed) return;
    _events.add(++_revision);
    if (persist) {
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(milliseconds: 450), () {
        unawaited(persistNow());
      });
    }
  }

  void log(String value, {bool error = false}) {
    message = value;
    final now = DateTime.now().toLocal();
    final time = [
      now.hour,
      now.minute,
      now.second,
    ].map((part) => part.toString().padLeft(2, '0')).join(':');
    output.add('[$time] $value');
    if (output.length > 500) output.removeAt(0);
    if (error) errors.add(value);
    changed(persist: false);
  }

  void clearOutput() {
    if (output.isEmpty) return;
    output.clear();
    changed(persist: false);
  }

  /// Open [root] in Solution and remember it in recent workspaces.
  Future<void> openWorkspaceFolder(Uri root) async {
    if (gitBusy) {
      throw StateError(
        'Wait for the current Git operation before switching projects',
      );
    }
    root = Uri.parse('${root.toString().replaceAll(RegExp(r'/+$'), '')}/');
    workspaceRoot = root;
    completionIndex = null;
    _gitEntries = {};
    _unpublished = {};
    gitStatusNote = null;
    await explorer.open(root);
    if (workspaceRoot != root) return;
    if (explorer.errors.containsKey(root)) {
      throw StateError(explorer.errors[root]!);
    }
    recentWorkspaces
      ..remove(root.toString())
      ..insert(0, root.toString());
    if (recentWorkspaces.length > 10) recentWorkspaces.removeLast();

    workspaceHasGit = git.available && await git.isRepository(root);
    if (git is HttpGitService) {
      completionIndex = ProjectCompletionIndex(
        (git as HttpGitService).openStore(root),
      );
      unawaited(completionIndex!.initialize());
    }
    var meta = await readTamtootProjectMeta(root);
    if (meta != null) {
      meta = meta.copyWith(lastOpenedAt: DateTime.now().toUtc());
      final headRef = await readGitHeadRef(root);
      if (headRef != null && headRef.startsWith('refs/heads/')) {
        meta = meta.copyWith(branch: headRef.replaceFirst('refs/heads/', ''));
      }
      try {
        await writeTamtootProjectMeta(root, meta);
      } catch (_) {
        // Read-only locations still expose meta in-memory for this session.
      }
      projectMeta = meta;
      log(
        'Opened ${meta.remoteUrl} · ${meta.branch}'
        '${workspaceHasGit ? ' · git' : ''}',
      );
    } else {
      projectMeta = null;
      if (workspaceHasGit) {
        // Legacy / external clone — create .tamtoot so Tamtoot can track it.
        final headRef = await readGitHeadRef(root);
        final branch = headRef != null && headRef.startsWith('refs/heads/')
            ? headRef.replaceFirst('refs/heads/', '')
            : 'unknown';
        final remote = await git.remoteUrl(root);
        final created = TamtootProjectMeta(
          remoteUrl: remote.ok ? remote.stdout.trim() : root.toString(),
          branch: branch,
          head: headRef ?? '',
          clonedAt: DateTime.now().toUtc(),
          lastOpenedAt: DateTime.now().toUtc(),
        );
        try {
          await writeTamtootProjectMeta(root, created);
          projectMeta = created;
          log('Linked .tamtoot for ${created.remoteUrl} · ${created.branch}');
        } catch (_) {
          log('Opened ${root.path}${workspaceHasGit ? ' · git' : ''}');
        }
      } else {
        log('Opened ${root.path}');
      }
    }
    await refreshGitIndicators();
    _gitTimer?.cancel();
    _gitTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(refreshGitIndicators()),
    );
    changed();
  }

  void observe(OpenDocument doc) {
    if (_subscriptions.containsKey(doc.id)) return;
    configure(doc);
    _subscriptions[doc.id] = doc.editor.changes.listen((_) => changed());
  }

  void configure(OpenDocument doc) {
    doc.editor.tabSize = settings.get('tabSize') as int;
    doc.editor.insertSpaces = settings.get('insertSpaces') as bool;
    doc.editor.readOnly = false;
  }

  Future<void> run(String id, [Object? argument]) async {
    try {
      await commands.execute(id, argument);
    } catch (e) {
      log('$id: $e', error: true);
    }
  }

  // Drop only unchanged, never-saved examples from older installations.
  // Real files and edited drafts must survive migration.
  bool _isLegacyExample(Map<String, dynamic> document) {
    if (document['uri'] != null || document['savedText'] != null) return false;
    final expected = switch (document['name']) {
      'welcome.dart' =>
        '8a210fdf1c5eabca7f974cc93bc2af2171876b62f708dfccc1d059b31dc6fc15',
      'Program.cs' =>
        '14490452029d804d7fbc6632ab879a30e651fa9eda525ac53a19af12dc68c6a0',
      _ => null,
    };
    return expected != null &&
        sha256.convert(utf8.encode(document['text'] as String)).toString() ==
            expected;
  }

  Future<void> restore() async {
    Future<void> load(String key, void Function(String) apply) async {
      try {
        final data = await store.read(key);
        if (data != null) apply(data);
      } catch (e) {
        log('Could not restore $key: $e', error: true);
      }
    }

    await load('settings', settings.restore);
    await load('layout', (data) => layout = DockLayout.parse(data));
    await load('keybindings', (data) => keys = KeybindingRegistry.parse(data));
    await load('session', (source) {
      final data = decodeVersioned(source, 'Session');
      final raw = data['documents'];
      if (raw is! List) {
        throw const SchemaException('Invalid session documents');
      }
      // Validate completely before mutating the current workspace.
      final normalized = <Map<String, dynamic>>[];
      for (final d in raw) {
        if (d is! Map<String, dynamic>) {
          throw const SchemaException('Invalid document');
        }
        requiredString(d, 'name');
        if (d['text'] is! String ||
            (d['savedText'] != null && d['savedText'] is! String) ||
            (d['uri'] != null && d['uri'] is! String)) {
          throw const SchemaException('Invalid document fields');
        }
        normalized.add(d);
      }
      final recent = stringList(
        data['recentWorkspaces'] ?? [],
        'recentWorkspaces',
      );
      final active = data['activeIndex'];
      String? restoredActive;
      for (var i = 0; i < normalized.length; i++) {
        final d = normalized[i];
        if (_isLegacyExample(d)) continue;
        final doc = documents.create(
          d['name'] as String,
          d['text'] as String,
          uri: d['uri'] == null ? null : Uri.parse(d['uri'] as String),
          savedText: d['savedText'] as String?,
        );
        observe(doc);
        if (i == active) restoredActive = doc.id;
      }
      if (restoredActive != null) documents.activeId = restoredActive;
      recentWorkspaces.addAll(recent.take(10));
    });
    log('Foundation ready · API v1');
    if (recentWorkspaces.isNotEmpty) {
      try {
        final root = Uri.parse(recentWorkspaces.first);
        if (!root.hasScheme) throw const FormatException('Invalid project URI');
        await openWorkspaceFolder(root);
      } catch (error) {
        workspaceRoot = null;
        workspaceHasGit = false;
        projectMeta = null;
        _gitEntries = {};
        _unpublished = {};
        gitStatusNote = null;
        _gitTimer?.cancel();
        explorer.clear();
        log(
          'Last project is unavailable. Open a project to continue: $error',
          error: true,
        );
      }
    }
  }

  Future<void> persistNow() {
    _saveTimer?.cancel();
    final snapshot = {
      'settings': settings.encode(),
      'layout': layout.encode(),
      'keybindings': jsonEncode(keys.toJson()),
      'session': jsonEncode({
        'schemaVersion': 1,
        'activeIndex': documents.documents.indexWhere(
          (d) => d.id == documents.activeId,
        ),
        'recentWorkspaces': recentWorkspaces,
        'documents': [
          for (final d in documents.documents)
            {
              'name': d.name,
              'uri': d.uri?.toString(),
              'text': d.editor.text,
              'savedText': d.savedText,
            },
        ],
      }),
    };
    _pendingSave = _pendingSave.then((_) async {
      try {
        for (final e in snapshot.entries) {
          await store.write(e.key, e.value);
        }
      } catch (e) {
        log('Persistence failed: $e', error: true);
      }
    });
    return _pendingSave;
  }

  Future<void> dispose() async {
    _gitTimer?.cancel();
    _saveTimer?.cancel();
    await persistNow();
    _disposed = true;
    for (final s in _subscriptions.values) {
      await s.cancel();
    }
    for (final d in documents.documents) {
      await d.editor.dispose();
    }
    await _events.close();
  }
}
