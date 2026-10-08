import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import '../core/ssh/ssh_client.dart';
import 'ssh_terminal_view.dart';
import 'sftp_browser_view.dart';
import '../core/ssh/auth/ssh_private_key.dart';
import '../core/ssh/crypto/ssh_crypto.dart';
import '../platform/ssh_key_file.dart';
import 'package:flutter/material.dart';
import '../app/ide_session.dart';
import '../core/ssh/host_keys/ssh_host_keys.dart';
import '../core/ssh/ssh_error.dart';
import '../core/ssh/ssh_profiles.dart';
import '../core/ssh/transport/ssh_transport.dart';
import '../platform/ssh_crypto/ssh_crypto.dart';
import '../platform/ssh_wire.dart';

Future<SshHostKeyDecision> showSshHostKeyTrust(
  BuildContext context,
  SshHostKeyChallenge challenge, {
  SshCancellation? cancellation,
}) async =>
    await showDialog<SshHostKeyDecision>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        if (cancellation != null) {
          unawaited(
            cancellation.whenCancelled.then((_) {
              if (ctx.mounted && ModalRoute.of(ctx)?.isCurrent == true) {
                Navigator.pop(ctx, SshHostKeyDecision.reject);
              }
            }),
          );
        }
        return AlertDialog(
          title: Text(
            challenge.changed ? 'SSH server key changed' : 'Trust SSH server?',
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${challenge.host}:${challenge.port}'),
                  const SizedBox(height: 12),
                  if (challenge.changed)
                    const Text(
                      'This server presented a different key. Verify the new fingerprint before continuing.',
                    ),
                  Text('Algorithm: ${challenge.key.algorithm}'),
                  const SizedBox(height: 8),
                  const Text('New fingerprint'),
                  SelectableText(challenge.key.fingerprint),
                  for (final previous in challenge.previousFingerprints) ...[
                    const SizedBox(height: 12),
                    const Text('Previously trusted fingerprint'),
                    SelectableText(previous),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, SshHostKeyDecision.reject),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, SshHostKeyDecision.once),
              child: const Text('Trust once'),
            ),
            if (challenge.changed)
              TextButton(
                onPressed: () => Navigator.pop(ctx, SshHostKeyDecision.replace),
                child: const Text('Replace saved keys'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, SshHostKeyDecision.save),
              child: Text(
                challenge.changed ? 'Add trusted key' : 'Trust and save',
              ),
            ),
          ],
        );
      },
    ) ??
    SshHostKeyDecision.reject;

class SshConnectionDialog extends StatefulWidget {
  const SshConnectionDialog({
    super.key,
    required this.session,
    required this.profile,
    this.createTransport,
  });
  final IdeSession session;
  final SshProfile profile;
  final SshTransport Function()? createTransport;
  @override
  State<SshConnectionDialog> createState() => _SshConnectionDialogState();
}

class _SshConnectionDialogState extends State<SshConnectionDialog> {
  SshTransport? transport;
  SshClient? client;
  StreamSubscription<SshTransportState>? subscription;
  StreamSubscription<SshClientState>? clientSubscription;
  final command = TextEditingController();
  final _stdout = _SshOutputPreview(), _stderr = _SshOutputPreview();
  SshCancellation? _commandCancellation;
  String? error;
  String banner = '';
  SshCommandResult? result;
  bool signingIn = false, running = false, _usedStoredPassword = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    final generation = ++_generation;
    try {
      await client?.close();
      await subscription?.cancel();
      await clientSubscription?.cancel();
      if (!mounted || generation != _generation) return;
      final connection =
          widget.createTransport?.call() ??
          SshTransport(
            crypto: createSshCrypto(),
            hostKeys: widget.session.sshHostKeys,
            openWire: openSshWire,
          );
      final protocol = SshClient(connection);
      transport = connection;
      client = protocol;
      _usedStoredPassword = false;
      banner = '';
      error = null;
      signingIn = false;
      running = false;
      result = null;
      _stdout.clear();
      _stderr.clear();
      subscription = connection.states.listen((_) {
        if (mounted && generation == _generation) {
          setState(() {
            if (connection.error != null) error = connection.error;
          });
        }
      });
      clientSubscription = protocol.states.listen((_) {
        if (mounted && generation == _generation) setState(() {});
      });
      if (mounted) setState(() {});
      await connection.connect(
        widget.profile.host,
        widget.profile.port,
        confirm: (challenge) async {
          if (!mounted || generation != _generation) {
            return SshHostKeyDecision.reject;
          }
          return showSshHostKeyTrust(
            context,
            challenge,
            cancellation: connection.cancellation,
          );
        },
      );
      if (mounted && generation == _generation) await _login();
    } on SshException catch (e) {
      if (mounted && generation == _generation) {
        setState(() => error = e.message);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () => error = 'Unable to start native SSH. Rebuild the application.',
        );
      }
    }
  }

  Future<List<Uint8List>?> _credentials(
    String title,
    String instruction,
    List<SshKeyboardPrompt> prompts,
  ) async {
    if (!mounted || transport!.cancellation.cancelled) return null;
    return showDialog<List<Uint8List>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SshCredentialsDialog(
        title: title,
        instruction: instruction,
        prompts: prompts,
        cancellation: transport!.cancellation,
      ),
    );
  }

  Future<Uint8List?> _password() async {
    if (widget.profile.authentication == SshAuthentication.password &&
        !_usedStoredPassword) {
      _usedStoredPassword = true;
      final secret = await widget.session.sshProfiles.readSecret(
        widget.profile,
      );
      if (secret != null) return secret;
    }
    final entered = await _credentials(
      'SSH password',
      '${widget.profile.username}@${widget.profile.host}',
      [const SshKeyboardPrompt('Password', false)],
    );
    return entered?.single;
  }

  Future<SshIdentity?> _identity() async {
    Uint8List? secret, phrase;
    OpenSshPrivateKey? key;
    try {
      secret = await widget.session.sshProfiles.readSecret(widget.profile);
      if (secret == null) {
        if (!mounted) return null;
        final file = await widget.session.documents.dialogs.open();
        if (file == null) return null;
        final pem = file.uri.scheme == 'memory'
            ? await widget.session.documents.files.read(file.uri)
            : await readSshKeyFile(file.uri);
        secret = Uint8List.fromList(utf8.encode(pem));
      }
      key = OpenSshPrivateKey.parse(utf8.decode(secret));
      if (key.encrypted) {
        final entered = await _credentials(
          'Unlock SSH private key',
          'The passphrase is used for this connection and is not saved.',
          [const SshKeyboardPrompt('Key passphrase', false)],
        );
        if (entered == null) return null;
        phrase = entered.single;
      }
      final crypto = transport!.crypto;
      if (crypto is! SshSigningCrypto) {
        throw const SshException('Native SSH signing is unavailable.');
      }
      return await key.unlock(crypto, passphrase: phrase);
    } finally {
      key?.dispose();
      secret?.fillRange(0, secret.length, 0);
      phrase?.fillRange(0, phrase.length, 0);
    }
  }

  Future<void> _login() async {
    if (signingIn || client == null) return;
    final generation = _generation;
    setState(() {
      signingIn = true;
      error = null;
    });
    try {
      await client!.login(
        widget.profile.username,
        preferKey:
            widget.profile.authentication == SshAuthentication.privateKey,
        password: _password,
        identity: widget.profile.authentication == SshAuthentication.privateKey
            ? _identity
            : null,
        keyboard: (challenge) => _credentials(
          challenge.name.isEmpty ? 'SSH authentication' : challenge.name,
          challenge.instruction,
          challenge.prompts,
        ),
        onBanner: (text) {
          if (mounted && generation == _generation) {
            setState(
              () => banner = (banner + text).substring(
                0,
                min(32768, banner.length + text.length),
              ),
            );
          }
        },
      );
    } on SshException catch (e) {
      if (mounted && generation == _generation) {
        setState(() => error = e.message);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => error = 'SSH sign-in failed.');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => signingIn = false);
      }
    }
  }

  Future<void> _run() async {
    final protocol = client, generation = _generation;
    if (protocol == null || running) return;
    final cancellation = SshCancellation();
    _commandCancellation = cancellation;
    setState(() {
      running = true;
      error = null;
      result = null;
      _stdout.clear();
      _stderr.clear();
    });
    try {
      final channel = await protocol.openExec(
        command.text,
        cancellation: cancellation,
        onOutput: (output) {
          if (!mounted || generation != _generation) return;
          setState(() => (output.stderr ? _stderr : _stdout).add(output.data));
        },
      );
      await channel.finishStdin();
      final completed = await channel.result;
      if (mounted && generation == _generation) {
        setState(() => result = completed);
      }
    } on SshException catch (e) {
      if (mounted && generation == _generation) {
        setState(() => error = e.message);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => error = 'SSH command failed.');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          running = false;
          _commandCancellation = null;
        });
      }
    }
  }

  Future<void> _disconnect() async {
    _generation++;
    _commandCancellation?.cancel();
    await client?.close();
    if (mounted) {
      setState(() {
        signingIn = false;
        running = false;
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    _commandCancellation?.cancel();
    unawaited(subscription?.cancel());
    unawaited(clientSubscription?.cancel());
    unawaited(client?.close());
    command.clear();
    command.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = transport?.state ?? SshTransportState.closed;
    final ready = client?.state == SshClientState.ready;
    final active = state != SshTransportState.closed;
    final status = !active
        ? 'Disconnected'
        : ready
        ? 'Signed in as ${widget.profile.username}'
        : signingIn
        ? 'Signing in…'
        : switch (state) {
            SshTransportState.awaitingTrust =>
              'Waiting for server key confirmation…',
            SshTransportState.exchangingKeys => 'Verifying server signature…',
            SshTransportState.ready => 'Server verified; sign-in required',
            SshTransportState.rekeying => 'Exchanging new encryption keys…',
            _ => 'Connecting…',
          };
    return AlertDialog(
      title: Text(widget.profile.name),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${widget.profile.host}:${widget.profile.port}'),
              const SizedBox(height: 12),
              Text(status),
              if (active && (signingIn || state != SshTransportState.ready))
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                ),
              if (banner.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(banner),
                ),
              if (ready) ...[
                OutlinedButton.icon(
                  onPressed: running
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SshTerminalView(
                              client: client!,
                              title: widget.profile.name,
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.terminal),
                  label: const Text('Open terminal'),
                ),
                OutlinedButton.icon(
                  onPressed: running
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SftpBrowserView(
                              client: client!,
                              title: widget.profile.name,
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Open SFTP'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: command,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 8192,
                  enabled: !running,
                  decoration: const InputDecoration(
                    labelText: 'Remote command',
                    hintText: 'uname -a',
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: running ? null : _run,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Run command'),
                    ),
                    if (running)
                      TextButton(
                        onPressed: () => _commandCancellation?.cancel(),
                        child: const Text('Cancel command'),
                      ),
                  ],
                ),
              ],
              if (running)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                ),
              if (_stdout.total > 0) _output('stdout', _stdout),
              if (_stderr.total > 0) _output('stderr', _stderr),
              if (result != null)
                Text(
                  result!.exitSignal != null
                      ? 'Terminated by signal: ${result!.exitSignal}'
                      : 'Exit code: ${result!.exitStatus}',
                ),
              if (transport?.serverKey != null) ...[
                const SizedBox(height: 12),
                Text('Server key: ${transport!.serverKey!.algorithm}'),
                SelectableText(transport!.serverKey!.fingerprint),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (active && state == SshTransportState.ready && !ready && !signingIn)
          TextButton(onPressed: _login, child: const Text('Sign in')),
        if (!active)
          TextButton(onPressed: _connect, child: const Text('Reconnect')),
        if (active)
          TextButton(onPressed: _disconnect, child: const Text('Disconnect')),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _output(String name, _SshOutputPreview preview) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
        if (preview.total > _SshOutputPreview.limit)
          const Text('Preview shows the first 256 KiB.'),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: SingleChildScrollView(
            child: SelectableText(
              preview.text,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ),
        if (result != null)
          TextButton(
            onPressed: () => Clipboard.setData(
              ClipboardData(
                text: utf8.decode(
                  name == 'stdout' ? result!.stdout : result!.stderr,
                  allowMalformed: true,
                ),
              ),
            ),
            child: Text('Copy $name'),
          ),
      ],
    ),
  );
}

class _SshOutputPreview {
  static const limit = 256 * 1024;
  final bytes = BytesBuilder(copy: false);
  int total = 0;
  void add(List<int> data) {
    total += data.length;
    final left = limit - bytes.length;
    if (left > 0) bytes.add(Uint8List.fromList(data.take(left).toList()));
  }

  String get text => utf8.decode(bytes.toBytes(), allowMalformed: true);
  void clear() {
    bytes.clear();
    total = 0;
  }
}

class _SshCredentialsDialog extends StatefulWidget {
  const _SshCredentialsDialog({
    required this.title,
    required this.instruction,
    required this.prompts,
    required this.cancellation,
  });
  final String title, instruction;
  final List<SshKeyboardPrompt> prompts;
  final SshCancellation cancellation;
  @override
  State<_SshCredentialsDialog> createState() => _SshCredentialsDialogState();
}

class _SshCredentialsDialogState extends State<_SshCredentialsDialog> {
  late final controllers = [
    for (final _ in widget.prompts) TextEditingController(),
  ];
  @override
  void initState() {
    super.initState();
    unawaited(
      widget.cancellation.whenCancelled.then((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.pop(context);
        }
      }),
    );
  }

  @override
  void dispose() {
    for (final controller in controllers) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (widget.cancellation.cancelled) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, [
      for (final controller in controllers)
        Uint8List.fromList(utf8.encode(controller.text)),
    ]);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.instruction.isNotEmpty) Text(widget.instruction),
            for (var i = 0; i < controllers.length; i++)
              TextField(
                controller: controllers[i],
                obscureText: !widget.prompts[i].echo,
                enableSuggestions: false,
                autocorrect: false,
                maxLength: 4096,
                decoration: InputDecoration(labelText: widget.prompts[i].text),
                onSubmitted: controllers.length == 1 ? (_) => _submit() : null,
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Continue')),
    ],
  );
}

class SshKnownHostsDialog extends StatefulWidget {
  const SshKnownHostsDialog({super.key, required this.session});
  final IdeSession session;
  @override
  State<SshKnownHostsDialog> createState() => _SshKnownHostsDialogState();
}

class _SshKnownHostsDialogState extends State<SshKnownHostsDialog> {
  final entries = <({SshKnownHost host, SshHostKey key})>[];
  String? error;
  bool busy = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.session.sshHostKeys.restore();
      final hosts = widget.session.sshHostKeys.hosts;
      final list = <({SshKnownHost host, SshHostKey key})>[];
      if (hosts.isNotEmpty) {
        final crypto = createSshCrypto();
        for (final host in hosts) {
          for (final blob in host.keys) {
            list.add((host: host, key: SshHostKey(blob, crypto)));
          }
        }
      }
      entries
        ..clear()
        ..addAll(list);
    } on SshException catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Unable to load SSH server trust records.';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _forget(({SshKnownHost host, SshHostKey key}) entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget trusted server key?'),
        content: Text(
          '${entry.host.host}:${entry.host.port}\n${entry.key.fingerprint}\nThe next connection will require explicit trust again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Forget'),
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
      await widget.session.sshHostKeys.forget(
        entry.host.host,
        entry.host.port,
        entry.key.blob,
      );
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() {
          error = 'Unable to remove SSH server trust.';
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Trusted SSH servers'),
    content: SizedBox(
      width: 620,
      height: 360,
      child: busy
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? Text(error!)
          : entries.isEmpty
          ? const Text('No server keys saved yet.')
          : ListView.builder(
              itemCount: entries.length,
              itemBuilder: (_, index) {
                final entry = entries[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${entry.host.host}:${entry.host.port}'),
                  subtitle: Text(
                    '${entry.key.algorithm}\n${entry.key.fingerprint}',
                  ),
                  isThreeLine: true,
                  trailing: IconButton(
                    tooltip: 'Forget server key',
                    onPressed: () => _forget(entry),
                    icon: const Icon(Icons.delete_outline),
                  ),
                );
              },
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
