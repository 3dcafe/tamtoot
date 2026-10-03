import 'dart:async';
import 'package:flutter/material.dart';
import 'git_diff.dart';
import 'git_history_dialog.dart';
import 'publish_project_dialog.dart';
import '../app/ide_session.dart';
import '../core/git/git_service.dart';

class GitChangesDialog extends StatefulWidget {
  const GitChangesDialog({
    super.key,
    required this.session,
    this.embedded = false,
    this.visible = true,
  });
  final IdeSession session;
  final bool embedded;
  final bool visible;
  @override
  State<GitChangesDialog> createState() => _GitChangesDialogState();
}

class _GitChangesDialogState extends State<GitChangesDialog> {
  late final Uri root = widget.session.workspaceRoot!;
  final message = TextEditingController();
  final name = TextEditingController(), email = TextEditingController();
  final username = TextEditingController(), token = TextEditingController();
  List<GitStatusEntry> entries = [];
  final selected = <String>{};
  final unsaved = <String>{};
  bool busy = true, ready = false, _identityLoaded = false;
  bool _credentialsLoaded = false;
  bool _loading = false;
  StreamSubscription<int>? _changes;
  Timer? _refreshTimer;
  late String _observedState;
  String branch = '', remote = '', feedback = '';
  GitService get git => widget.session.git;

  @override
  void initState() {
    super.initState();
    _observedState = _stateFingerprint();
    _load();
    if (widget.embedded) {
      _changes = widget.session.changes.listen((_) {
        final current = _stateFingerprint();
        if (current == _observedState) return;
        _observedState = current;
        _refreshTimer?.cancel();
        _refreshTimer = Timer(const Duration(milliseconds: 600), () {
          if (mounted &&
              widget.visible &&
              !_loading &&
              !busy &&
              !widget.session.gitBusy) {
            _load(background: true);
          }
        });
      });
    }
  }

  @override
  void didUpdateWidget(GitChangesDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.visible && widget.visible && !busy && !_loading) _load();
  }

  @override
  void dispose() {
    _changes?.cancel();
    _refreshTimer?.cancel();
    for (final controller in [message, name, email, username, token]) {
      controller.dispose();
    }
    super.dispose();
  }

  String safeError(Object error) {
    var text = error.toString();
    if (token.text.isNotEmpty) text = text.replaceAll(token.text, '[redacted]');
    if (text.contains('(401)')) {
      return 'Authentication failed (HTTP 401). Open Git settings and enter a valid access token with repository write permission.';
    }
    if (text.contains('(403)')) {
      return 'Push was forbidden (HTTP 403). The saved token does not have repository write permission.';
    }
    return text;
  }

  String _stateFingerprint() {
    final documents =
        widget.session.documents.documents
            .where(
              (document) =>
                  document.uri?.toString().startsWith(root.toString()) ?? false,
            )
            .map(
              (document) =>
                  '${document.id}:${document.uri}:${document.dirty ? 1 : 0}',
            )
            .toList()
          ..sort();
    return '${widget.session.gitStatusRevision}|${documents.join('|')}';
  }

  Future<void> _load({bool background = false}) async {
    if (!mounted || _loading) return;
    _loading = true;
    if (!background) {
      setState(() {
        busy = true;
        ready = false;
      });
    }
    try {
      final identity = git;
      if (identity is GitIdentityProvider) {
        final value = await (identity as GitIdentityProvider).identity(root);
        branch = value.branch;
        if (!_identityLoaded) {
          name.text = value.name;
          email.text = value.email;
          _identityLoaded = true;
        }
      }
      final url = await git.remoteUrl(root);
      remote = url.ok ? url.stdout.trim() : '';
      // Never display credentials embedded in a pre-existing remote URL.
      if (remote.isNotEmpty) {
        remote = Uri.parse(remote).replace(userInfo: '').toString();
        if (!_credentialsLoaded) {
          final saved = widget.session.gitCredentials(remote);
          username.text = saved.username;
          token.text = saved.token;
          _credentialsLoaded = true;
        }
      }
      entries = [...await git.statusEntries(root)];
      unsaved.clear();
      for (final doc in widget.session.documents.documents) {
        final uri = doc.uri;
        if (!doc.dirty ||
            uri == null ||
            !uri.toString().startsWith(root.toString())) {
          continue;
        }
        final path = Uri.decodeComponent(
          uri.toString().substring(root.toString().length),
        );
        final sharedRequestFile =
            path == '.tamtoot/environment.json' ||
            path.startsWith('.tamtoot/requests/');
        if ((!sharedRequestFile && path.startsWith('.tamtoot/')) ||
            path.startsWith('.git/')) {
          continue;
        }
        unsaved.add(path);
        if (!entries.any((entry) => entry.path == path)) {
          entries.add(GitStatusEntry(' ', 'M', path));
        }
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      selected.retainAll(entries.map((e) => e.path));
      ready = true;
    } catch (error) {
      feedback = safeError(error);
    } finally {
      _loading = false;
      _observedState = _stateFingerprint();
      if (mounted) {
        setState(() {
          if (!background) busy = false;
        });
      }
    }
  }

  Future<void> _commit() async {
    if (widget.session.gitBusy) return;
    if (selected.isEmpty || message.text.trim().isEmpty) {
      setState(() => feedback = 'Select files and enter a commit message.');
      return;
    }
    widget.session.gitBusy = true;
    widget.session.changed(persist: false);
    setState(() {
      busy = true;
      feedback = '';
    });
    try {
      // Only selected files are saved; never silently commit stale editor text.
      for (final doc in widget.session.documents.documents.toList()) {
        if (!doc.dirty || doc.uri == null) continue;
        final chosen = selected.any(
          (path) =>
              root.resolve(
                path.split('/').map(Uri.encodeComponent).join('/'),
              ) ==
              doc.uri,
        );
        final originalUri = doc.uri;
        if (chosen &&
            (!await widget.session.documents.save(doc) ||
                doc.uri != originalUri)) {
          throw GitException('Save cancelled. No commit was created.');
        }
      }
      final identity = git;
      if (identity is GitIdentityProvider) {
        await (identity as GitIdentityProvider).setIdentity(
          root,
          name.text,
          email.text,
        );
      }
      (await git.add(root, paths: selected.toList())).ensureOk();
      final result = await git.commit(root, message.text.trim());
      result.ensureOk();
      feedback =
          'Commit created: ${result.stdout.trim()}\nYou can now push it.';
      widget.session.log('[Git] Commit created: ${result.stdout.trim()}');
      message.clear();
      selected.clear();
      await widget.session.refreshGitIndicators();
      await _load();
    } catch (error) {
      widget.session.log(
        '[Git] Commit failed: ${safeError(error)}',
        error: true,
      );
      if (mounted) {
        setState(() {
          feedback = safeError(error);
          busy = false;
        });
      }
    } finally {
      widget.session.gitBusy = false;
      widget.session.changed(persist: false);
    }
  }

  Future<void> _push() async {
    if (widget.session.gitBusy) return;
    if (!await _ensurePushCredentials()) return;
    widget.session.gitBusy = true;
    widget.session.changed(persist: false);
    setState(() {
      busy = true;
      feedback = '';
    });
    widget.session.log('[Git] Push started: origin/$branch');
    try {
      final result = await git.push(
        root,
        credentials: _credentials,
        setUpstream: true,
      );
      result.ensureOk();
      feedback = result.stdout.trim();
      widget.session.log('[Git] Push completed:\n${result.stdout.trim()}');
      await widget.session.refreshGitIndicators();
    } catch (error) {
      feedback = safeError(error);
      widget.session.log('[Git] Push failed: $feedback', error: true);
    } finally {
      widget.session.gitBusy = false;
      widget.session.changed(persist: false);
      if (mounted) setState(() => busy = false);
    }
  }

  GitCredentials? get _credentials => token.text.isEmpty
      ? null
      : GitCredentials(
          username: username.text.trim().isEmpty ? 'git' : username.text.trim(),
          token: token.text,
        );

  Future<bool> _ensurePushCredentials() async {
    if (token.text.trim().isNotEmpty) return true;
    setState(() {
      feedback =
          'Push requires an access token with repository write permission. Add it in Git settings.';
    });
    await _settings();
    return token.text.trim().isNotEmpty;
  }

  Future<void> _pull({bool pushAfter = false}) async {
    if (widget.session.gitBusy) return;
    if (pushAfter && !await _ensurePushCredentials()) return;
    if (widget.session.documents.documents.any(
      (document) =>
          document.dirty &&
          document.uri != null &&
          document.uri!.toString().startsWith(root.toString()),
    )) {
      setState(() {
        feedback =
            'Save, commit or discard open editor changes before pulling.';
      });
      return;
    }
    widget.session.gitBusy = true;
    widget.session.changed(persist: false);
    setState(() {
      busy = true;
      feedback = '';
    });
    widget.session.log(
      '[Git] ${pushAfter ? "Sync" : "Pull"} started: origin/$branch',
    );
    try {
      final result = await git.pull(root, credentials: _credentials);
      result.ensureOk();
      var resultText = result.stdout.trim();
      for (final document in widget.session.documents.documents.toList()) {
        final uri = document.uri;
        if (uri == null || !uri.toString().startsWith(root.toString())) {
          continue;
        }
        try {
          final text = await widget.session.documents.files.read(uri);
          document.editor.reloadFromDisk(text);
          document.savedText = document.editor.text;
        } catch (_) {
          await widget.session.documents.close(document);
        }
      }
      if (pushAfter) {
        final pushed = await git.push(
          root,
          credentials: _credentials,
          setUpstream: true,
        );
        pushed.ensureOk();
        resultText = '$resultText\n${pushed.stdout.trim()}'.trim();
      }
      feedback = resultText;
      widget.session.log(
        '[Git] ${pushAfter ? "Sync" : "Pull"} completed:\n$resultText',
      );
      await widget.session.refreshExplorer();
      await widget.session.persistNow();
      await _load();
    } catch (error) {
      feedback = safeError(error);
      widget.session.log(
        '[Git] ${pushAfter ? "Sync" : "Pull"} failed: $feedback',
        error: true,
      );
    } finally {
      widget.session.gitBusy = false;
      widget.session.changed(persist: false);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _settings() async {
    final remoteController = TextEditingController(text: remote);
    final nameController = TextEditingController(text: name.text);
    final emailController = TextEditingController(text: email.text);
    final usernameController = TextEditingController(text: username.text);
    final tokenController = TextEditingController(text: token.text);
    var obscure = true;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Git settings'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: remoteController,
                    decoration: const InputDecoration(
                      labelText: 'Remote URL (origin)',
                    ),
                  ),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Author name'),
                  ),
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Author email',
                    ),
                  ),
                  TextField(
                    controller: usernameController,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'HTTPS username',
                    ),
                  ),
                  TextField(
                    controller: tokenController,
                    obscureText: obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Access token / password',
                      helperText:
                          'Saved locally for this remote; never added to the project or Git.',
                      suffixIcon: IconButton(
                        tooltip: obscure ? 'Show token' : 'Hide token',
                        onPressed: () => update(() => obscure = !obscure),
                        icon: Icon(
                          obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      try {
        final remoteUri = Uri.parse(remoteController.text.trim());
        if (remoteUri.scheme != 'https' || remoteUri.userInfo.isNotEmpty) {
          throw const FormatException(
            'Remote must be an HTTPS URL without embedded credentials.',
          );
        }
        if (nameController.text.trim().isEmpty ||
            emailController.text.trim().isEmpty ||
            RegExp(
              r'[\r\n<>\x00#;"\\]',
            ).hasMatch('${nameController.text}${emailController.text}')) {
          throw const FormatException('Enter a valid author name and email.');
        }
        (await git.setRemoteUrl(root, remoteUri)).ensureOk();
        final identity = git;
        if (identity is GitIdentityProvider) {
          await (identity as GitIdentityProvider).setIdentity(
            root,
            nameController.text,
            emailController.text,
          );
        }
        name.text = nameController.text;
        email.text = emailController.text;
        username.text = usernameController.text;
        token.text = tokenController.text;
        widget.session.rememberGitCredentials(
          remoteUri.toString(),
          username: username.text,
          token: token.text,
        );
        await _load();
        widget.session.log('[Git] Settings updated for origin/$branch');
      } catch (error) {
        if (mounted) setState(() => feedback = safeError(error));
      }
    }
    // AlertDialog remains in the overlay during its closing animation.
    await Future<void>.delayed(kThemeAnimationDuration);
    for (final controller in [
      remoteController,
      nameController,
      emailController,
      usernameController,
      tokenController,
    ]) {
      controller.dispose();
    }
  }

  Future<void> _publish() async {
    final published = await showPublishProjectDialog(context, widget.session);
    if (published && mounted) await _load();
  }

  Future<void> _history() async {
    final provider = git;
    if (provider is! GitHistoryProvider) return;
    if (remote.isNotEmpty) {
      try {
        final result = await git.fetch(root, credentials: _credentials);
        result.ensureOk();
        widget.session.log('[Git] History refreshed from origin/$branch');
      } catch (error) {
        widget.session.log(
          '[Git] Remote history refresh failed; showing local history: ${safeError(error)}',
          error: true,
        );
      }
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => GitHistoryDialog(
        session: widget.session,
        root: root,
        branch: branch,
        safeError: safeError,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.embedded)
              SizedBox(
                height: 42,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      key: const ValueKey('git-dialog-pull'),
                      tooltip: 'Pull',
                      onPressed: busy || !ready || remote.isEmpty
                          ? null
                          : () => _pull(),
                      icon: const Icon(Icons.arrow_downward, size: 20),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      key: const ValueKey('git-dialog-push'),
                      tooltip: remote.isEmpty
                          ? 'Push first commit to empty GitHub repo'
                          : 'Push',
                      onPressed: busy || !ready
                          ? null
                          : (remote.isEmpty ? _publish : _push),
                      icon: Icon(
                        remote.isEmpty
                            ? Icons.upload_outlined
                            : Icons.arrow_upward,
                        size: 20,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      key: const ValueKey('git-dialog-sync'),
                      tooltip: 'Sync',
                      onPressed: busy || !ready || remote.isEmpty
                          ? null
                          : () => _pull(pushAfter: true),
                      icon: const Icon(Icons.sync, size: 20),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: 'Commit history',
                      onPressed: busy ? null : _history,
                      icon: const Icon(Icons.history, size: 20),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: 'Git settings',
                      onPressed: busy ? null : _settings,
                      icon: const Icon(Icons.settings_outlined, size: 20),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: busy ? null : _load,
                      icon: const Icon(Icons.refresh, size: 20),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
            if (busy) const LinearProgressIndicator(),
            if (ready && entries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No changes to commit.'),
              ),
            for (final entry in entries)
              GestureDetector(
                onSecondaryTapDown: (event) async {
                  await showFileGitMenu(
                    context,
                    widget.session,
                    root.resolve(Uri(path: entry.path).toString()),
                    event.globalPosition,
                  );
                  await _load();
                },
                onLongPressStart: (event) async {
                  await showFileGitMenu(
                    context,
                    widget.session,
                    root.resolve(Uri(path: entry.path).toString()),
                    event.globalPosition,
                  );
                  await _load();
                },
                child: CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: InkWell(
                    key: ValueKey('git-change-${entry.path}'),
                    onTap: busy
                        ? null
                        : () async {
                            await showFileChanges(
                              context,
                              widget.session,
                              root.resolve(Uri(path: entry.path).toString()),
                            );
                            await _load();
                          },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(entry.path),
                    ),
                  ),
                  subtitle: Text(
                    unsaved.contains(entry.path)
                        ? 'Unsaved — will save before commit'
                        : entry.isUntracked
                        ? 'New file'
                        : '${entry.index}${entry.workTree}',
                  ),
                  value: selected.contains(entry.path),
                  onChanged: busy
                      ? null
                      : (checked) => setState(() {
                          checked == true
                              ? selected.add(entry.path)
                              : selected.remove(entry.path);
                        }),
                ),
              ),
            const Divider(height: 20),
            TextField(
              controller: message,
              enabled: !busy,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Commit message'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy || !ready ? null : _commit,
                    icon: const Icon(Icons.commit, size: 18),
                    label: const Text('Commit'),
                  ),
                ),
                if (widget.embedded) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Git settings',
                    onPressed: busy ? null : _settings,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ],
            ),
            if (feedback.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SelectableText(feedback),
              ),
          ],
        ),
      ),
    );
    if (widget.embedded) {
      return Material(
        color: Color(widget.session.theme.color('panel')),
        child: Column(
          children: [
            SizedBox(
              height: 42,
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('git-pull'),
                    tooltip: 'Pull',
                    onPressed: busy || !ready || remote.isEmpty
                        ? null
                        : () => _pull(),
                    icon: const Icon(Icons.arrow_downward, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    key: const ValueKey('git-push'),
                    tooltip: remote.isEmpty
                        ? 'Push first commit to empty GitHub repo'
                        : 'Push',
                    onPressed: busy || !ready
                        ? null
                        : (remote.isEmpty ? _publish : _push),
                    icon: Icon(
                      remote.isEmpty
                          ? Icons.upload_outlined
                          : Icons.arrow_upward,
                      size: 18,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    key: const ValueKey('git-sync'),
                    tooltip: 'Sync (pull, then push)',
                    onPressed: busy || !ready || remote.isEmpty
                        ? null
                        : () => _pull(pushAfter: true),
                    icon: const Icon(Icons.sync, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    branch,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey('git-history'),
                    tooltip: 'Commit history',
                    onPressed: busy ? null : _history,
                    icon: const Icon(Icons.history, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: content,
              ),
            ),
          ],
        ),
      );
    }
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Text('Git · $branch'),
        content: content,
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
