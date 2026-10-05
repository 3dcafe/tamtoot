import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../core/ssh/ssh_profiles.dart';
import '../app/ide_session.dart';
import '../platform/ssh_key_file.dart';
import 'ssh_connection_dialog.dart';

class SshProfilesSettings extends StatefulWidget {
  const SshProfilesSettings({super.key, required this.session});
  final IdeSession session;
  @override
  State<SshProfilesSettings> createState() => _SshProfilesSettingsState();
}

class _SshProfilesSettingsState extends State<SshProfilesSettings> {
  late final repository = widget.session.sshProfiles;
  bool loading = true, available = false, busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await repository.restore();
      available = await repository.secrets.available;
    } catch (_) {
      error = 'Unable to load SSH profiles. Stored data was preserved.';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _edit([SshProfile? profile]) async {
    final result = await showDialog<_ProfileDraft>(
      context: context,
      builder: (_) => _ProfileEditor(
        session: widget.session,
        profile: profile,
        available: available,
      ),
    );
    if (result == null) return;
    if (!mounted) {
      result.secret?.fillRange(0, result.secret!.length, 0);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await repository.save(
        result.profile,
        secret: result.secret,
        persistSecret: result.persistSecret,
        forgetSecret: result.forgetSecret,
      );
    } catch (_) {
      error =
          'Could not save SSH profile or secret. Check secure storage availability and retry.';
    } finally {
      result.secret?.fillRange(0, result.secret!.length, 0);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _delete(SshProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete SSH profile?'),
        content: Text('Delete ${profile.name} and its stored secret?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await repository.delete(profile.id);
    } catch (_) {
      error = 'Could not delete SSH profile or secret. Retry the deletion.';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'SSH profiles, keys and server verification. Sign-in and commands will be available in the next stage.',
      ),
      const SizedBox(height: 12),
      Text(
        available
            ? 'Native secure storage is available. Saving secrets requires an explicit choice.'
            : 'Secure storage is unavailable. Secrets are kept only for this app session; reimport keys after restarting.',
      ),
      if (repository.hasPendingSecretCleanup)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'Some old secrets could not be deleted. Cleanup will be retried when this section is reopened. Session storage remains available.',
          ),
        ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (loading) const LinearProgressIndicator(),
      for (final profile in repository.profiles)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(profile.name),
          subtitle: Text(
            '${profile.username}@${profile.host}:${profile.port}\n${profile.authentication == SshAuthentication.password ? 'Password' : 'Ed25519 key'} · ${profile.secretId == null ? 'No saved secret' : 'Secret in secure storage'}',
          ),
          isThreeLine: true,
          onTap: loading || busy || error != null ? null : () => _edit(profile),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Connect to SSH server',
                icon: const Icon(Icons.link),
                onPressed: loading || busy || error != null
                    ? null
                    : () => showDialog<void>(
                        context: context,
                        builder: (_) => SshConnectionDialog(
                          session: widget.session,
                          profile: profile,
                        ),
                      ),
              ),
              IconButton(
                tooltip: 'Delete profile',
                icon: const Icon(Icons.delete_outline),
                onPressed: loading || busy || error != null
                    ? null
                    : () => _delete(profile),
              ),
            ],
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: loading || busy || error != null ? null : () => _edit(),
          icon: const Icon(Icons.add),
          label: const Text('Add SSH profile'),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: loading || busy
              ? null
              : () => showDialog<void>(
                  context: context,
                  builder: (_) => SshKnownHostsDialog(session: widget.session),
                ),
          icon: const Icon(Icons.verified_user_outlined),
          label: const Text('Trusted servers'),
        ),
      ),
      if (error != null)
        TextButton(
          onPressed: busy
              ? null
              : () {
                  setState(() {
                    error = null;
                    loading = true;
                  });
                  _load();
                },
          child: const Text('Reload profiles'),
        ),
    ],
  );
}

class _ProfileDraft {
  _ProfileDraft(
    this.profile,
    this.secret,
    this.persistSecret,
    this.forgetSecret,
  );
  final SshProfile profile;
  final Uint8List? secret;
  final bool persistSecret, forgetSecret;
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({
    required this.session,
    required this.profile,
    required this.available,
  });
  final IdeSession session;
  final SshProfile? profile;
  final bool available;
  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  late final name = TextEditingController(text: widget.profile?.name);
  late final host = TextEditingController(text: widget.profile?.host);
  late final port = TextEditingController(
    text: '${widget.profile?.port ?? 22}',
  );
  late final user = TextEditingController(text: widget.profile?.username);
  final password = TextEditingController();
  late SshAuthentication authentication =
      widget.profile?.authentication ?? SshAuthentication.password;
  Uint8List? key;
  bool persist = false, forget = false, importing = false;
  String? error;
  void _clearKey() {
    key?.fillRange(0, key!.length, 0);
    key = null;
  }

  @override
  void dispose() {
    for (final field in [name, host, port, user, password]) {
      field.clear();
      field.dispose();
    }
    _clearKey();
    super.dispose();
  }

  Future<void> _import() async {
    setState(() {
      importing = true;
      error = null;
    });
    Uint8List? bytes;
    try {
      final file = await widget.session.documents.dialogs.open();
      if (file == null) return;
      // Read through the existing platform picker, including Android SAF.
      final text = file.uri.scheme == 'memory'
          ? await widget.session.documents.files.read(file.uri)
          : await readSshKeyFile(file.uri);
      validateEd25519PrivateKey(text);
      bytes = Uint8List.fromList(utf8.encode(text.trim()));
      if (!mounted) return;
      _clearKey();
      key = bytes;
      bytes = null;
    } on FormatException catch (e) {
      if (mounted) error = e.message;
    } catch (_) {
      if (mounted) error = 'Could not read the selected key file.';
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      if (mounted) setState(() => importing = false);
    }
  }

  void _save() {
    try {
      final profile = SshProfile(
        id: widget.profile?.id ?? SshProfiles.newId(),
        name: name.text.trim(),
        host: host.text.trim(),
        port: int.tryParse(port.text) ?? 0,
        username: user.text.trim(),
        authentication: authentication,
      );
      final secret = authentication == SshAuthentication.privateKey
          ? (key == null ? null : Uint8List.fromList(key!))
          : (password.text.isEmpty
                ? null
                : Uint8List.fromList(utf8.encode(password.text)));
      Navigator.pop(context, _ProfileDraft(profile, secret, persist, forget));
    } catch (_) {
      setState(
        () => error = 'Enter a name, server, user and a port from 1 to 65535.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.profile == null ? 'Add SSH profile' : 'Edit SSH profile',
    ),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final field in [
              (name, 'Name'),
              (host, 'Server'),
              (port, 'Port'),
              (user, 'User'),
            ])
              TextField(
                controller: field.$1,
                decoration: InputDecoration(labelText: field.$2),
              ),
            const SizedBox(height: 12),
            DropdownButton<SshAuthentication>(
              value: authentication,
              isExpanded: true,
              items: const [
                DropdownMenuItem(
                  value: SshAuthentication.password,
                  child: Text('Password'),
                ),
                DropdownMenuItem(
                  value: SshAuthentication.privateKey,
                  child: Text('Ed25519 private key'),
                ),
              ],
              onChanged: importing
                  ? null
                  : (value) => setState(() {
                      authentication = value!;
                      password.clear();
                      _clearKey();
                      persist = false;
                    }),
            ),
            if (authentication == SshAuthentication.password) ...[
              const Text(
                'By default, the password will be requested when connecting. Leave blank to keep an existing saved secret.',
              ),
              TextField(
                controller: password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Optional password',
                ),
              ),
            ] else ...[
              const Text(
                'Import an unencrypted OpenSSH Ed25519 key. Encrypted keys and other formats are not yet supported.',
              ),
              OutlinedButton.icon(
                onPressed: importing ? null : _import,
                icon: const Icon(Icons.key),
                label: Text(
                  key == null ? 'Import private key' : 'Ed25519 key imported',
                ),
              ),
              const Text(
                'Without an imported or saved key, the profile can be saved and the key added later.',
              ),
            ],
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: persist,
              onChanged: widget.available
                  ? (value) => setState(() => persist = value!)
                  : null,
              title: const Text('Save new secret in native secure storage'),
              subtitle: Text(
                widget.available
                    ? 'Unchecked: keep only until the app closes.'
                    : 'Unavailable on this device. Session storage only.',
              ),
            ),
            if (widget.profile != null)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: forget,
                onChanged: (value) => setState(() => forget = value!),
                title: const Text('Remove existing secret'),
              ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: importing ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: importing ? null : _save,
        child: const Text('Save'),
      ),
    ],
  );
}
