import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import '../filesystem/filesystem.dart';
import 'auth/ssh_private_key.dart';

enum SshAuthentication { password, privateKey }

class SshProfile {
  SshProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authentication,
    this.secretId,
  }) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        (secretId != null && !RegExp(r'^[a-f0-9]{32}$').hasMatch(secretId!)) ||
        name.trim().isEmpty ||
        name.length > 200 ||
        host.trim().isEmpty ||
        host.length > 253 ||
        RegExp(r'[\s/\x00-\x1f]').hasMatch(host) ||
        username.trim().isEmpty ||
        username.length > 256 ||
        RegExp(r'[\x00-\x1f]').hasMatch(username) ||
        port < 1 ||
        port > 65535) {
      throw const FormatException('Invalid SSH profile fields.');
    }
  }
  final String id, name, host, username;
  final int port;
  final SshAuthentication authentication;
  final String? secretId;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'authentication': authentication.name,
    'secretId': secretId,
  };
  factory SshProfile.fromJson(Map<String, dynamic> json) => SshProfile(
    id: json['id'] as String,
    name: json['name'] as String,
    host: json['host'] as String,
    port: json['port'] as int,
    username: json['username'] as String,
    authentication: SshAuthentication.values.byName(
      json['authentication'] as String,
    ),
    secretId: json['secretId'] as String?,
  );
}

abstract interface class SshSecretStore {
  Future<bool> get available;
  Future<void> write(String id, Uint8List value);
  Future<Uint8List?> read(String id);
  Future<void> delete(String id);
}

/// Explicit session fallback. Never writes secrets to files or preferences.
class SessionSshSecrets implements SshSecretStore {
  final _values = <String, Uint8List>{};
  @override
  Future<bool> get available async => false;
  @override
  Future<void> write(String id, Uint8List value) async {
    await delete(id);
    _values[id] = Uint8List.fromList(value);
  }

  @override
  Future<Uint8List?> read(String id) async =>
      _values[id] == null ? null : Uint8List.fromList(_values[id]!);
  @override
  Future<void> delete(String id) async {
    final value = _values.remove(id);
    value?.fillRange(0, value.length, 0);
  }

  void clear() {
    for (final value in _values.values) {
      value.fillRange(0, value.length, 0);
    }
    _values.clear();
  }
}

class SshProfiles {
  SshProfiles(this.store, this.secrets);
  final PersistenceStore store;
  final SshSecretStore secrets;
  final sessionSecrets = SessionSshSecrets();
  List<SshProfile> _profiles = [];
  List<String> _pendingDeletes = [];
  bool get hasPendingSecretCleanup => _pendingDeletes.isNotEmpty;
  List<SshProfile> get profiles => List.unmodifiable(_profiles);
  Future<void> _tail = Future.value();
  static String newId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> _serial(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> restore() => _serial(() async {
    final text = await store.read('ssh.profiles');
    if (text == null) return;
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      if (json['version'] != 1) throw const FormatException();
      final list = json['profiles'] as List;
      if (list.length > 1000) throw const FormatException();
      final loaded = list
          .map((item) => SshProfile.fromJson(item as Map<String, dynamic>))
          .toList();
      if (loaded.map((p) => p.id).toSet().length != loaded.length ||
          loaded
                  .where((p) => p.secretId != null)
                  .map((p) => p.secretId)
                  .toSet()
                  .length !=
              loaded.where((p) => p.secretId != null).length) {
        throw const FormatException();
      }
      final pending = (json['pendingDeletes'] as List? ?? []).cast<String>();
      if (pending.length > 2000 ||
          pending.any(
            (id) =>
                !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
                loaded.any((p) => p.secretId == id),
          )) {
        throw const FormatException();
      }
      _profiles = loaded;
      _pendingDeletes = pending.toSet().toList();
    } catch (_) {
      throw const FormatException('Unable to restore SSH profiles.');
    }
    await _tryCleanup();
  });
  Future<void> _persist(
    List<SshProfile> profiles, {
    List<String>? pendingDeletes,
  }) async {
    await store.write(
      'ssh.profiles',
      jsonEncode({
        'version': 1,
        'profiles': profiles.map((p) => p.toJson()).toList(),
        'pendingDeletes': pendingDeletes ?? _pendingDeletes,
      }),
    );
    _profiles = profiles;
    if (pendingDeletes != null) _pendingDeletes = pendingDeletes;
  }

  Future<void> _tryCleanup() async {
    try {
      await _cleanup();
    } catch (_) {
      // Retain cleanup references and expose a warning; unavailable storage
      // must not prevent profiles from using session-only secrets.
    }
  }

  Future<void> _cleanup() async {
    if (_pendingDeletes.isEmpty) return;
    for (final id in _pendingDeletes) {
      await secrets.delete(id);
    }
    await _persist(_profiles, pendingDeletes: []);
  }

  Future<void> save(
    SshProfile profile, {
    Uint8List? secret,
    bool persistSecret = false,
    bool forgetSecret = false,
  }) {
    final copied = secret == null ? null : Uint8List.fromList(secret);
    return _serial(() async {
      String? newSecretId;
      SshSecretStore? target;
      try {
        final old = _profiles.where((p) => p.id == profile.id).firstOrNull;
        if (old == null && _profiles.length >= 1000) {
          throw StateError('SSH profile limit reached.');
        }
        var reference =
            old?.authentication == profile.authentication && !forgetSecret
            ? old?.secretId
            : null;
        if (copied != null) {
          if (copied.isEmpty || copied.length > 65536) {
            throw const FormatException('Invalid secret size.');
          }
          if (profile.authentication == SshAuthentication.privateKey) {
            validateOpenSshPrivateKey(utf8.decode(copied));
          }
          target = persistSecret ? secrets : sessionSecrets;
          if (persistSecret && !await secrets.available) {
            throw StateError(
              'Secure storage is unavailable. Choose session storage.',
            );
          }
          newSecretId = newId();
          if (persistSecret) {
            // Record cleanup intent before writing, so interrupted imports can be cleaned on restore.
            await _persist(
              _profiles,
              pendingDeletes: [..._pendingDeletes, newSecretId],
            );
          }
          await target.write(newSecretId, copied);
          reference = persistSecret ? newSecretId : null;
        }
        final updated = SshProfile(
          id: profile.id,
          name: profile.name.trim(),
          host: profile.host.trim(),
          port: profile.port,
          username: profile.username.trim(),
          authentication: profile.authentication,
          secretId: reference,
        );
        try {
          final pending = _pendingDeletes
              .where((id) => id != newSecretId)
              .toSet();
          if (old?.secretId != null && old!.secretId != reference) {
            pending.add(old.secretId!);
          }
          await _persist([
            ..._profiles.where((p) => p.id != profile.id),
            updated,
          ], pendingDeletes: pending.toList());
        } catch (_) {
          if (newSecretId != null) await target!.delete(newSecretId);
          rethrow;
        }
        if (copied != null ||
            forgetSecret ||
            old?.authentication != profile.authentication) {
          await sessionSecrets.delete(profile.id);
        }
        if (copied != null && !persistSecret) {
          await sessionSecrets.write(profile.id, copied);
          await sessionSecrets.delete(newSecretId!);
        }
        await _tryCleanup();
      } finally {
        copied?.fillRange(0, copied.length, 0);
      }
    });
  }

  Future<Uint8List?> readSecret(SshProfile profile) async {
    final current = _profiles.where((p) => p.id == profile.id).firstOrNull;
    if (current == null) return null;
    return await sessionSecrets.read(current.id) ??
        (current.secretId == null
            ? null
            : await secrets.read(current.secretId!));
  }

  Future<void> delete(String id) => _serial(() async {
    final profile = _profiles.where((p) => p.id == id).firstOrNull;
    if (profile == null) return;
    if (profile.secretId != null) await secrets.delete(profile.secretId!);
    await sessionSecrets.delete(id);
    await _persist(_profiles.where((p) => p.id != id).toList());
  });
}

/// Bounded structural import validation, not cryptographic verification.
void validateEd25519PrivateKey(String pem) {
  const begin = '-----BEGIN OPENSSH PRIVATE KEY-----';
  const end = '-----END OPENSSH PRIVATE KEY-----';
  if (pem.length > 65536) {
    throw const FormatException('SSH key exceeds 64 KiB.');
  }
  final text = pem.trim();
  if (!text.startsWith(begin) || !text.endsWith(end)) {
    throw const FormatException(
      'Expected an OpenSSH private key. PEM, PKCS#8 and public keys are unsupported.',
    );
  }
  Uint8List bytes;
  try {
    bytes = base64Decode(
      text
          .substring(begin.length, text.length - end.length)
          .replaceAll(RegExp(r'\s'), ''),
    );
  } catch (_) {
    throw const FormatException('Invalid OpenSSH base64 data.');
  }
  try {
    final reader = _KeyReader(bytes);
    final magic = ascii.encode('openssh-key-v1\x00');
    if (!_equal(reader.take(magic.length), magic)) {
      throw const FormatException();
    }
    final cipher = reader.text();
    final kdf = reader.text();
    final options = reader.string();
    if (cipher != 'none' || kdf != 'none') {
      throw const FormatException(
        'Encrypted OpenSSH keys are not supported yet.',
      );
    }
    if (options.isNotEmpty || reader.uint32() != 1) {
      throw const FormatException();
    }
    final public = _KeyReader(reader.string());
    if (public.text() != 'ssh-ed25519') {
      throw const FormatException('Only Ed25519 keys are supported.');
    }
    final publicBytes = public.string();
    if (publicBytes.length != 32 || public.remaining != 0) {
      throw const FormatException();
    }
    final privateData = reader.string();
    if (reader.remaining != 0 || privateData.length % 8 != 0) {
      throw const FormatException();
    }
    final private = _KeyReader(privateData);
    if (private.uint32() != private.uint32()) throw const FormatException();
    if (private.text() != 'ssh-ed25519') throw const FormatException();
    final innerPublic = private.string();
    final key = private.string();
    if (!_equal(publicBytes, innerPublic) ||
        key.length != 64 ||
        !_equal(publicBytes, key.sublist(32))) {
      throw const FormatException();
    }
    private.string(); // Comment: never expose it in errors or logs.
    if (private.remaining > 8) throw const FormatException();
    var padding = 1;
    while (private.remaining > 0) {
      if (private.take(1)[0] != padding++) throw const FormatException();
    }
  } on FormatException catch (error) {
    if (error.message.isNotEmpty) rethrow;
    throw const FormatException('Malformed OpenSSH Ed25519 private key.');
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

class _KeyReader {
  _KeyReader(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  int get remaining => bytes.length - offset;
  Uint8List take(int count) {
    if (count < 0 || count > remaining) throw const FormatException();
    final value = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return value;
  }

  int uint32() => ByteData.sublistView(take(4)).getUint32(0);
  Uint8List string() => take(uint32());
  String text() {
    try {
      return ascii.decode(string());
    } catch (_) {
      throw const FormatException();
    }
  }
}
