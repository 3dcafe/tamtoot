part of '../ssh_client.dart';

class SshAuthenticationRejected extends SshException {
  const SshAuthenticationRejected(super.message);
}

class SshKeyboardPrompt {
  const SshKeyboardPrompt(this.text, this.echo);
  final String text;
  final bool echo;
}

class SshKeyboardChallenge {
  const SshKeyboardChallenge(this.name, this.instruction, this.prompts);
  final String name, instruction;
  final List<SshKeyboardPrompt> prompts;
}

typedef SshPasswordProvider = Future<Uint8List?> Function();
typedef SshIdentityProvider = Future<SshIdentity?> Function();
typedef SshKeyboardResponder =
    Future<List<Uint8List>?> Function(SshKeyboardChallenge);

extension SshAuthenticationProtocol on SshClient {
  SshWriter _request(String method) => (SshWriter()
    ..byte(50)
    ..text(_username!)
    ..text('ssh-connection')
    ..text(method));
  void _attempt() {
    if (_attempts >= 6) {
      _fatal('SSH authentication attempt limit reached.');
      throw const SshAuthenticationRejected(
        'SSH authentication attempt limit reached. Reconnect to try again.',
      );
    }
    _attempts++;
  }

  Future<T> _ask<T>(Future<T> pending, void Function(T) cleanup) async {
    unawaited(
      pending.then((value) {
        if (transport.cancellation.cancelled) cleanup(value);
      }, onError: (Object _, StackTrace _) {}),
    );
    try {
      final value = await Future.any([
        pending,
        transport.cancellation.whenCancelled.then<T>(
          (_) => throw const SshException('SSH sign-in cancelled.'),
        ),
      ]).timeout(const Duration(minutes: 5));
      if (transport.cancellation.cancelled) {
        cleanup(value);
        throw const SshException('SSH sign-in cancelled.');
      }
      return value;
    } on TimeoutException {
      _fatal('SSH credential prompt timed out.');
      throw const SshException('SSH credential prompt timed out.');
    }
  }

  Future<bool> _response() async {
    final packet = await _nextAuth(), reader = SshReader(packet)..byte();
    if (packet[0] == 52) {
      reader.end();
      transport.authenticationSucceeded();
      _state(SshClientState.ready);
      return true;
    }
    if (packet[0] != 51) {
      throw const SshException('Unexpected SSH authentication result.');
    }
    _methods = reader.names();
    _partial = reader.boolean();
    reader.end();
    return false;
  }

  Future<bool> _password(SshPasswordProvider provider) async {
    final value = await _ask(
      provider(),
      (value) => value?.fillRange(0, value.length, 0),
    );
    if (value == null) {
      throw const SshAuthenticationRejected('SSH password entry cancelled.');
    }
    Uint8List? request;
    try {
      if (value.length > 16384) {
        throw const SshException('SSH password exceeds its limit.');
      }
      _attempt();
      request =
          (_request('password')
                ..byte(0)
                ..string(value))
              .take();
      await _send(request);
    } finally {
      value.fillRange(0, value.length, 0);
      request?.fillRange(0, request.length, 0);
    }
    final response = await _nextAuth();
    if (response[0] == 60) {
      throw const SshAuthenticationRejected(
        'The server requires a password change; change it outside this client.',
      );
    }
    _authPackets.addFirst(response);
    _authBytes += response.length;
    return _response();
  }

  Future<bool> _publicKey(SshIdentityProvider provider) async {
    final identity = await _ask(provider(), (identity) => identity?.dispose());
    if (identity == null) {
      throw const SshAuthenticationRejected('SSH private-key entry cancelled.');
    }
    try {
      final algorithms = identity.algorithm == 'ssh-ed25519'
          ? ['ssh-ed25519']
          : ['rsa-sha2-512', 'rsa-sha2-256'];
      final advertised = _extensions['server-sig-algs']?.split(',');
      for (final algorithm in algorithms) {
        if (advertised != null && !advertised.contains(algorithm)) continue;
        _attempt();
        await _send(
          (_request('publickey')
                ..byte(0)
                ..text(algorithm)
                ..string(identity.publicBlob))
              .take(),
        );
        final probe = await _nextAuth();
        if (probe[0] == 51) {
          _authPackets.addFirst(probe);
          _authBytes += probe.length;
          await _response();
          if (_partial) {
            throw const SshException(
              'Unexpected partial success for an unsigned SSH key.',
            );
          }
          continue;
        }
        final reader = SshReader(probe)..byte();
        if (probe[0] != 60 ||
            reader.asciiText(limit: 128) != algorithm ||
            !sshBytesEqual(reader.string(limit: 2048), identity.publicBlob)) {
          throw const SshException(
            'SSH server accepted a different public key.',
          );
        }
        reader.end();
        Uint8List? signed, signature, request;
        try {
          final body =
              (_request('publickey')
                    ..byte(1)
                    ..text(algorithm)
                    ..string(identity.publicBlob))
                  .take();
          signed =
              (SshWriter()
                    ..string(transport.sessionIdentifier)
                    ..raw(body))
                  .take();
          signature = await identity.signer.sign(signed, algorithm);
          _verified();
          final signatureBlob =
              (SshWriter()
                    ..text(algorithm)
                    ..string(signature))
                  .take();
          request =
              (SshWriter()
                    ..raw(body)
                    ..string(signatureBlob))
                  .take();
          _attempt();
          await _send(request);
        } finally {
          signed?.fillRange(0, signed.length, 0);
          signature?.fillRange(0, signature.length, 0);
          request?.fillRange(0, request.length, 0);
        }
        return _response();
      }
      return false;
    } finally {
      identity.dispose();
    }
  }

  Future<bool> _keyboard(SshKeyboardResponder responder) async {
    _attempt();
    await _send(
      (_request('keyboard-interactive')
            ..text('')
            ..text(''))
          .take(),
    );
    var prompts = 0;
    for (var round = 0; ; round++) {
      final response = await _nextAuth();
      if (response[0] != 60) {
        _authPackets.addFirst(response);
        _authBytes += response.length;
        return _response();
      }
      if (round >= 8) {
        throw const SshException(
          'SSH interactive challenge round limit reached.',
        );
      }
      final reader = SshReader(response)..byte();
      String text(int limit) =>
          utf8.decode(reader.string(limit: limit), allowMalformed: true);
      final name = text(1024), instruction = text(4096);
      reader.string(limit: 128);
      final count = reader.uint32();
      prompts += count;
      if (count > 16 || prompts > 64) {
        throw const SshException('SSH keyboard challenge exceeds its limit.');
      }
      final fields = [
        for (var i = 0; i < count; i++)
          SshKeyboardPrompt(text(1024), reader.boolean()),
      ];
      reader.end();
      final answers = count == 0
          ? <Uint8List>[]
          : await _ask(
              responder(SshKeyboardChallenge(name, instruction, fields)),
              (value) {
                if (value != null) {
                  for (final answer in value) {
                    answer.fillRange(0, answer.length, 0);
                  }
                }
              },
            );
      if (answers == null) {
        throw const SshAuthenticationRejected(
          'SSH interactive sign-in cancelled.',
        );
      }
      Uint8List? request;
      try {
        if (answers.length != count || answers.any((a) => a.length > 16384)) {
          throw const SshException('Invalid SSH interactive answers.');
        }
        final writer = SshWriter()
          ..byte(61)
          ..uint32(count);
        for (final answer in answers) {
          writer.string(answer);
        }
        request = writer.take();
        await _send(request);
      } finally {
        for (final answer in answers) {
          answer.fillRange(0, answer.length, 0);
        }
        request?.fillRange(0, request.length, 0);
      }
    }
  }

  Future<void> login(
    String username, {
    bool preferKey = false,
    SshPasswordProvider? password,
    SshIdentityProvider? identity,
    SshKeyboardResponder? keyboard,
    void Function(String)? onBanner,
  }) async {
    _verified();
    if (state != SshClientState.idle ||
        username.isEmpty ||
        utf8.encode(username).length > 512 ||
        RegExp(r'[\x00-\x1f]').hasMatch(username) ||
        (_username != null && _username != username)) {
      throw const SshException('Invalid SSH sign-in state or user.');
    }
    _username = username;
    _banner = onBanner;
    _state(SshClientState.authenticating);
    try {
      if (!_serviceStarted) {
        await _send(
          (SshWriter()
                ..byte(5)
                ..text('ssh-userauth'))
              .take(),
        );
        final reader = SshReader(await _nextAuth());
        if (reader.byte() != 6 ||
            reader.asciiText(limit: 128) != 'ssh-userauth') {
          throw const SshException(
            'SSH authentication service was not accepted.',
          );
        }
        reader.end();
        _serviceStarted = true;
      }
      if (_methods == null) {
        await _send(_request('none').take());
        if (await _response()) return;
      }
      final used = <String>{};
      for (var step = 0; step < 3; step++) {
        final available = _methods!;
        if (preferKey &&
            identity != null &&
            available.contains('publickey') &&
            used.add('publickey')) {
          if (await _publicKey(identity)) return;
          continue;
        }
        if (password != null &&
            available.contains('password') &&
            used.add('password')) {
          if (await _password(password)) return;
          continue;
        }
        if (!preferKey &&
            identity != null &&
            available.contains('publickey') &&
            used.add('publickey')) {
          if (await _publicKey(identity)) return;
          continue;
        }
        if (keyboard != null &&
            available.contains('keyboard-interactive') &&
            used.add('keyboard-interactive')) {
          if (await _keyboard(keyboard)) return;
          continue;
        }
        break;
      }
      throw SshAuthenticationRejected(
        _partial
            ? 'An additional authentication factor is required.'
            : 'SSH sign-in rejected. Check the user and credentials or the server authentication policy.',
      );
    } on TimeoutException {
      _fatal('SSH sign-in timed out.');
      throw const SshException('SSH sign-in timed out.');
    } on SshException catch (e) {
      if (e is! SshAuthenticationRejected) _fatal(e.message);
      rethrow;
    } catch (_) {
      throw const SshException('SSH sign-in failed.');
    } finally {
      if (state == SshClientState.authenticating) _state(SshClientState.idle);
    }
  }
}
