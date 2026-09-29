import 'dart:async';
import 'package:flutter/material.dart';
import 'git_diff.dart';
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
  StreamSubscription<int>? _changes;
  Timer? _refreshTimer;
  String branch = '', remote = '', feedback = '';
  GitService get git => widget.session.git;

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.embedded) {
      _changes = widget.session.changes.listen((_) {
        _refreshTimer?.cancel();
        _refreshTimer = Timer(const Duration(milliseconds: 600), () {
          if (mounted && widget.visible && !busy && !widget.session.gitBusy) {
            _load();
          }
        });
      });
    }
  }

  @override
  void didUpdateWidget(GitChangesDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.visible && widget.visible && !busy) _load();
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
    return text;
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      busy = true;
      ready = false;
    });
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
      if (mounted) setState(() => busy = false);
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
      message.clear();
      selected.clear();
      await widget.session.refreshGitIndicators();
      await _load();
    } catch (error) {
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
    widget.session.gitBusy = true;
    widget.session.changed(persist: false);
    setState(() {
      busy = true;
      feedback = '';
    });
    try {
      final result = await git.push(
        root,
        credentials: token.text.isEmpty
            ? null
            : GitCredentials(
                username: username.text.trim().isEmpty
                    ? 'git'
                    : username.text.trim(),
                token: token.text,
              ),
        setUpstream: true,
      );
      result.ensureOk();
      feedback = result.stdout.trim();
      await widget.session.refreshGitIndicators();
    } catch (error) {
      feedback = safeError(error);
    } finally {
      widget.session.gitBusy = false;
      widget.session.changed(persist: false);
      if (mounted) setState(() => busy = false);
    }
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
            Text(
              'Branch: $branch\nRemote (origin): ${remote.isEmpty ? "Not configured" : remote}',
            ),
            const SizedBox(height: 12),
            const Text(
              'Select files to commit. Selected editor changes will be saved first. New files are never selected automatically; check them against .gitignore.',
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
            TextField(
              controller: name,
              enabled: !busy,
              decoration: const InputDecoration(labelText: 'Author name'),
            ),
            TextField(
              controller: email,
              enabled: !busy,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Author email'),
            ),
            TextField(
              controller: message,
              enabled: !busy,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Commit message'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy || !ready ? null : _commit,
              icon: const Icon(Icons.commit),
              label: const Text('Commit selected'),
            ),
            const Divider(height: 28),
            TextField(
              controller: username,
              enabled: !busy,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'HTTPS username'),
            ),
            TextField(
              controller: token,
              enabled: !busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Access token / password',
                helperText: 'Kept only while this Git view is open.',
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Push sends existing local commits on this branch. Uncommitted files are not sent.',
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: busy || !ready || remote.isEmpty ? null : _push,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Push commits'),
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
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Refresh Git changes',
                onPressed: busy ? null : _load,
                icon: const Icon(Icons.refresh, size: 18),
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
        title: const Text('Commit and push'),
        content: content,
        actions: [
          TextButton(
            onPressed: busy ? null : _load,
            child: const Text('Refresh'),
          ),
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
