import 'dart:async';

import 'package:flutter/material.dart';

import '../app/ide_session.dart';
import '../core/git/git_service.dart';
import '../core/git/github_api.dart';
import '../core/git/http_git_service.dart';
import '../core/workspace/tamtoot_meta.dart';
import '../platform/tamtoot_meta_store.dart';

/// Prepares a new/local project for the first push into an empty GitHub repo:
/// init if needed, set origin, create the first commit when missing, then push.
class PublishProjectDialog extends StatefulWidget {
  const PublishProjectDialog({super.key, required this.session});
  final IdeSession session;

  @override
  State<PublishProjectDialog> createState() => _PublishProjectDialogState();
}

class _PublishProjectDialogState extends State<PublishProjectDialog> {
  final repoName = TextEditingController();
  final remoteUrl = TextEditingController();
  final authorName = TextEditingController();
  final authorEmail = TextEditingController();
  final username = TextEditingController();
  final token = TextEditingController();
  bool createOnGithub = false;
  bool privateRepo = true;
  bool obscure = true;
  bool busy = false;
  String? error;

  IdeSession get session => widget.session;
  Uri get root => session.workspaceRoot!;

  @override
  void initState() {
    super.initState();
    final folder = root.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    repoName.text = folder ?? 'project';
    unawaited(_loadDefaults());
  }

  Future<void> _loadDefaults() async {
    final git = session.git;
    if (git is HttpGitService && await git.isRepository(root)) {
      try {
        final identity = await git.identity(root);
        if (!mounted) return;
        if (identity.name.isNotEmpty) authorName.text = identity.name;
        if (identity.email.isNotEmpty) authorEmail.text = identity.email;
        final url = await git.remoteUrl(root);
        if (url.ok) {
          final clean = Uri.parse(url.stdout.trim()).replace(userInfo: '');
          remoteUrl.text = clean.toString();
          final saved = session.gitCredentials(clean.toString());
          username.text = saved.username;
          token.text = saved.token;
        }
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final controller in [
      repoName,
      remoteUrl,
      authorName,
      authorEmail,
      username,
      token,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String safeError(Object error) {
    var text = '$error';
    if (token.text.isNotEmpty) text = text.replaceAll(token.text, '[redacted]');
    return text;
  }

  Future<void> _publish() async {
    final git = session.git;
    if (git is! HttpGitService) {
      setState(() => error = 'Git publishing is unavailable on this platform.');
      return;
    }
    if (session.gitBusy) return;
    final name = authorName.text.trim();
    final email = authorEmail.text.trim();
    final tokenValue = token.text.trim();
    if (name.isEmpty ||
        email.isEmpty ||
        RegExp(r'[\r\n<>\x00#;"\\]').hasMatch('$name$email')) {
      setState(() => error = 'Enter a valid author name and email.');
      return;
    }
    if (tokenValue.isEmpty) {
      setState(
        () => error = createOnGithub
            ? 'Enter a GitHub token that can create repositories and push.'
            : 'Enter a GitHub access token with repository write permission.',
      );
      return;
    }
    final credentials = GitCredentials(
      username: username.text.trim().isEmpty ? 'git' : username.text.trim(),
      token: tokenValue,
    );

    setState(() {
      busy = true;
      error = null;
    });
    session.gitBusy = true;
    session.changed(persist: false);
    session.log('[Git] First push started');
    try {
      if (!await git.isRepository(root)) {
        (await git.init(root)).ensureOk();
        session.log('[Git] Initialized local repository on main');
      }

      late final Uri remote;
      if (createOnGithub) {
        final created = await createGithubRepository(
          git.transport,
          name: repoName.text,
          credentials: credentials,
          private: privateRepo,
        );
        remote = created.cloneUrl.replace(userInfo: '');
        session.log('[Git] Created GitHub repository ${created.fullName}');
      } else {
        final text = remoteUrl.text.trim();
        if (text.isEmpty) {
          throw const FormatException(
            'Enter the HTTPS URL of the empty GitHub repository.',
          );
        }
        remote = Uri.parse(text);
        if (remote.scheme != 'https' || remote.userInfo.isNotEmpty) {
          throw const FormatException(
            'Remote must be an HTTPS URL without embedded credentials.',
          );
        }
      }

      (await git.setRemoteUrl(root, remote)).ensureOk();
      await git.setIdentity(root, name, email);
      session.rememberGitCredentials(
        remote.toString(),
        username: credentials.username ?? 'git',
        token: tokenValue,
      );

      final now = DateTime.now().toUtc();
      final meta = TamtootProjectMeta(
        remoteUrl: remote.toString(),
        branch: 'main',
        head: '',
        clonedAt: now,
        lastOpenedAt: now,
      );
      try {
        await writeTamtootProjectMeta(root, meta);
        session.projectMeta = meta;
      } catch (_) {
        session.projectMeta = meta;
      }

      session.workspaceHasGit = true;
      session.changed(persist: false);

      var commitHash = '';
      final existing = await git.history(root, limit: 1);
      if (existing.isEmpty) {
        final entries = await git.statusEntries(root);
        final paths = entries
            .where((entry) => entry.isChanged)
            .map((entry) => entry.path)
            .toList();
        (await git.add(root, paths: paths.isEmpty ? const ['.'] : paths))
            .ensureOk();
        final committed = await git.commit(root, 'Initial commit');
        committed.ensureOk();
        commitHash = committed.stdout.trim();
        session.log('[Git] Initial commit $commitHash');
      } else {
        commitHash = existing.first.hash;
      }

      final pushed = await git.push(
        root,
        credentials: credentials,
        setUpstream: true,
      );
      pushed.ensureOk();
      final summary =
          'Pushed first commit to empty remote $remote\n'
          '$commitHash\n${pushed.stdout.trim()}';
      session.log('[Git] Push completed:\n${pushed.stdout.trim()}');
      session.projectMeta = meta.copyWith(head: commitHash, branch: 'main');
      try {
        await writeTamtootProjectMeta(root, session.projectMeta!);
      } catch (_) {}

      await session.refreshGitIndicators();
      session.log('[Git] $summary');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      final message = safeError(e);
      session.log('[Git] First push failed: $message', error: true);
      if (mounted) setState(() => error = message);
    } finally {
      session.gitBusy = false;
      session.changed(persist: false);
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('Push to empty GitHub repo'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Initializes local Git if needed, attaches your empty GitHub '
                'repository, creates the first commit when missing, and pushes it.',
              ),
              const SizedBox(height: 12),
              if (!createOnGithub)
                TextField(
                  controller: remoteUrl,
                  enabled: !busy,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Empty repository HTTPS URL',
                    hintText: 'https://github.com/you/project.git',
                    helperText:
                        'Create an empty repo on GitHub first (no README/license).',
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Create repository via GitHub API'),
                subtitle: const Text(
                  'Optional. Leave off if the empty repo already exists.',
                ),
                value: createOnGithub,
                onChanged: busy
                    ? null
                    : (value) => setState(() => createOnGithub = value),
              ),
              if (createOnGithub) ...[
                TextField(
                  controller: repoName,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'Repository name',
                    helperText: 'my-app or org/my-app',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Private repository'),
                  value: privateRepo,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => privateRepo = value),
                ),
              ],
              TextField(
                controller: authorName,
                enabled: !busy,
                decoration: const InputDecoration(labelText: 'Author name'),
              ),
              TextField(
                controller: authorEmail,
                enabled: !busy,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Author email'),
              ),
              TextField(
                controller: username,
                enabled: !busy,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'HTTPS username (optional)',
                  helperText: 'Defaults to git',
                ),
              ),
              TextField(
                controller: token,
                enabled: !busy,
                obscureText: obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'GitHub access token',
                  helperText:
                      'Saved locally for this remote; never added to the project or Git.',
                  suffixIcon: IconButton(
                    tooltip: obscure ? 'Show token' : 'Hide token',
                    onPressed: busy
                        ? null
                        : () => setState(() => obscure = !obscure),
                    icon: Icon(
                      obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy ? null : _publish,
          child: const Text('Push first commit'),
        ),
      ],
    ),
  );
}

Future<bool> showPublishProjectDialog(
  BuildContext context,
  IdeSession session,
) async {
  if (session.workspaceRoot == null) return false;
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => PublishProjectDialog(session: session),
  );
  return result == true;
}
