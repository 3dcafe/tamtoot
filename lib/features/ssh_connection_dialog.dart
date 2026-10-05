import 'dart:async';
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
  SshHostKeyChallenge challenge,
) async =>
    await showDialog<SshHostKeyDecision>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
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
      ),
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
  StreamSubscription<SshTransportState>? subscription;
  String? error;
  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      final connection =
          widget.createTransport?.call() ??
          SshTransport(
            crypto: createSshCrypto(),
            hostKeys: widget.session.sshHostKeys,
            openWire: openSshWire,
          );
      transport = connection;
      subscription = connection.states.listen((_) {
        if (mounted) setState(() => error = connection.error);
      });
      await connection.connect(
        widget.profile.host,
        widget.profile.port,
        confirm: (challenge) async {
          if (!mounted) return SshHostKeyDecision.reject;
          return showSshHostKeyTrust(context, challenge);
        },
      );
    } on SshException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted)
        setState(
          () => error =
              'Unable to start the native SSH transport. Rebuild the application.',
        );
    }
  }

  Future<void> _disconnect() async {
    await transport?.close();
    if (mounted) setState(() {});
  }

  Future<void> _rekey() async {
    try {
      await transport?.rekey();
    } on SshException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'SSH key exchange failed.');
    }
  }

  @override
  void dispose() {
    unawaited(subscription?.cancel());
    unawaited(transport?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = transport?.state ?? SshTransportState.closed;
    final ready = state == SshTransportState.ready;
    final active = state != SshTransportState.closed;
    final status = switch (state) {
      SshTransportState.idle || SshTransportState.connecting => 'Connecting…',
      SshTransportState.exchangingKeys => 'Verifying server signature…',
      SshTransportState.awaitingTrust => 'Waiting for server key confirmation…',
      SshTransportState.ready => 'Encrypted SSH transport ready',
      SshTransportState.rekeying => 'Exchanging new encryption keys…',
      SshTransportState.closed => 'Disconnected',
    };
    return AlertDialog(
      title: Text(widget.profile.name),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${widget.profile.host}:${widget.profile.port}'),
              const SizedBox(height: 12),
              Text(status),
              if (active && !ready)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                ),
              if (ready)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'The server is verified and encryption is active. Sign-in and command execution will be available in the next stage.',
                  ),
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
        if (ready) TextButton(onPressed: _rekey, child: const Text('Rekey')),
        if (active)
          TextButton(onPressed: _disconnect, child: const Text('Disconnect')),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
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
      if (mounted)
        setState(() {
          error = 'Unable to remove SSH server trust.';
          busy = false;
        });
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
