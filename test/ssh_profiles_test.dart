import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/ssh/ssh_profiles.dart';
import 'package:tamtoot/platform/ssh_secrets/native_ssh_secrets.dart';
import 'support.dart';

class SecureMemory extends SessionSshSecrets {
  bool enabled = true, failDelete = false;
  String? failId;
  final ids = <String>{};
  @override
  Future<bool> get available async => enabled;
  @override
  Future<void> write(String id, Uint8List value) async {
    await super.write(id, value);
    ids.add(id);
  }

  @override
  Future<void> delete(String id) async {
    if (failDelete || failId == id) throw StateError('unavailable');
    await super.delete(id);
    ids.remove(id);
  }
}

class FailingStore extends MemoryStore {
  bool fail = false;
  int writes = 0;
  int? failAt;
  @override
  Future<void> write(String key, String value) async {
    if (fail || ++writes == failAt) throw StateError('disk full');
    await super.write(key, value);
  }
}

// Synthetic format fixture; never used to connect or treated as a real key.
String keyFixture({
  bool encrypted = false,
  bool wrongPublic = false,
  bool badPadding = false,
  bool mismatchCheck = false,
  int count = 1,
  String algorithm = 'ssh-ed25519',
}) {
  List<int> uint32(int n) =>
      (ByteData(4)..setUint32(0, n)).buffer.asUint8List();
  List<int> string(List<int> value) => [...uint32(value.length), ...value];
  List<int> text(String value) => string(utf8.encode(value));
  final public = List<int>.generate(32, (i) => i);
  final private = <int>[
    ...uint32(42),
    ...uint32(mismatchCheck ? 43 : 42),
    ...text(algorithm),
    ...string(public),
    ...string([...List.filled(32, 17), ...public]),
    ...text('fixture'),
  ];
  var padding = 1;
  while (private.length % 8 != 0) {
    private.add(badPadding ? 0 : padding++);
  }
  final bytes = [
    ...ascii.encode('openssh-key-v1\x00'),
    ...text(encrypted ? 'aes256-ctr' : 'none'),
    ...text(encrypted ? 'bcrypt' : 'none'),
    ...string([]),
    ...uint32(count),
    ...string([
      ...text(algorithm),
      ...string(wrongPublic ? List.filled(32, 99) : public),
    ]),
    ...string(private),
  ];
  return '-----BEGIN OPENSSH PRIVATE KEY-----\n${base64Encode(bytes)}\n-----END OPENSSH PRIVATE KEY-----';
}

SshProfile profile(
  String id, {
  String name = 'Server',
  SshAuthentication auth = SshAuthentication.password,
}) => SshProfile(
  id: id,
  name: name,
  host: 'example.org',
  port: 22,
  username: 'alice',
  authentication: auth,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'profile CRUD survives restore; serialized profiles contain no secrets',
    () async {
      final store = MemoryStore();
      final secrets = SecureMemory();
      final repository = SshProfiles(store, secrets);
      final id = SshProfiles.newId();
      await repository.save(
        profile(id),
        secret: Uint8List.fromList(utf8.encode('password-marker')),
        persistSecret: true,
      );
      final reference = repository.profiles.single.secretId!;
      expect(await secrets.read(reference), utf8.encode('password-marker'));
      expect(
        await store.read('ssh.profiles'),
        isNot(contains('password-marker')),
      );
      await repository.save(profile(id, name: 'Renamed'));
      expect(repository.profiles.single.secretId, reference);
      final restored = SshProfiles(store, secrets);
      await restored.restore();
      expect(restored.profiles.single.name, 'Renamed');
      await restored.delete(id);
      expect(secrets.ids, isEmpty);
      expect(restored.profiles, isEmpty);
    },
  );
  test(
    'session secrets are never serialized and are forgotten on restart',
    () async {
      final store = MemoryStore();
      final secrets = SecureMemory()..enabled = false;
      final repository = SshProfiles(store, secrets);
      final p = profile(SshProfiles.newId());
      final value = Uint8List.fromList(utf8.encode('session-marker'));
      await repository.save(p, secret: value);
      value.fillRange(0, value.length, 0);
      expect(
        await repository.readSecret(repository.profiles.single),
        utf8.encode('session-marker'),
      );
      expect(repository.profiles.single.secretId, isNull);
      expect(
        await store.read('ssh.profiles'),
        isNot(contains('session-marker')),
      );
      final restored = SshProfiles(store, secrets);
      await restored.restore();
      expect(await restored.readSecret(restored.profiles.single), isNull);
      await expectLater(
        repository.save(
          p,
          secret: Uint8List.fromList([1]),
          persistSecret: true,
        ),
        throwsStateError,
      );
      expect(secrets.ids, isEmpty);
      repository.sessionSecrets.clear();
      expect(await repository.readSecret(repository.profiles.single), isNull);
    },
  );
  test(
    'failed profile persistence removes newly created secret and queue recovers',
    () async {
      final store = FailingStore();
      final secrets = SecureMemory();
      final repository = SshProfiles(store, secrets);
      final p = profile(SshProfiles.newId());
      store.fail = true;
      await expectLater(
        repository.save(
          p,
          secret: Uint8List.fromList([1]),
          persistSecret: true,
        ),
        throwsStateError,
      );
      expect(secrets.ids, isEmpty);
      expect(repository.profiles, isEmpty);
      store.fail = false;
      await Future.wait([
        repository.save(p),
        repository.save(profile(SshProfiles.newId())),
      ]);
      expect(repository.profiles.length, 2);
    },
  );
  test(
    'replacing, forgetting and switching authentication removes old secrets',
    () async {
      final store = MemoryStore();
      final secrets = SecureMemory();
      final repository = SshProfiles(store, secrets);
      final p = profile(SshProfiles.newId());
      await repository.save(
        p,
        secret: Uint8List.fromList([1]),
        persistSecret: true,
      );
      final old = repository.profiles.single.secretId!;
      await repository.save(
        p,
        secret: Uint8List.fromList([2]),
        persistSecret: true,
      );
      expect(await secrets.read(old), isNull);
      expect(secrets.ids.length, 1);
      await repository.save(p, forgetSecret: true);
      expect(secrets.ids, isEmpty);
      await repository.save(p, secret: Uint8List.fromList([3]));
      await repository.save(profile(p.id, auth: SshAuthentication.privateKey));
      expect(await repository.readSecret(repository.profiles.single), isNull);
    },
  );
  test(
    'failed replacement cleanup is retried after restoring profiles',
    () async {
      final store = MemoryStore();
      final secrets = SecureMemory();
      final repository = SshProfiles(store, secrets);
      final p = profile(SshProfiles.newId());
      await repository.save(
        p,
        secret: Uint8List.fromList([1]),
        persistSecret: true,
      );
      final old = repository.profiles.single.secretId!;
      secrets.failId = old;
      await repository.save(
        p,
        secret: Uint8List.fromList([2]),
        persistSecret: true,
      );
      expect(repository.hasPendingSecretCleanup, isTrue);
      final current = repository.profiles.single.secretId!;
      expect(current, isNot(old));
      expect(secrets.ids.length, 2);
      secrets.failId = null;
      final restored = SshProfiles(store, secrets);
      await restored.restore();
      expect(await secrets.read(old), isNull);
      expect(await restored.readSecret(restored.profiles.single), [2]);
      expect(secrets.ids, {current});
    },
  );
  test(
    'interrupted secret import is cleaned and failed commit keeps previous profiles',
    () async {
      final store = FailingStore()..failAt = 2;
      final secrets = SecureMemory();
      final repository = SshProfiles(store, secrets);
      final p = profile(SshProfiles.newId());
      await expectLater(
        repository.save(
          p,
          secret: Uint8List.fromList([1]),
          persistSecret: true,
        ),
        throwsStateError,
      );
      expect(secrets.ids, isEmpty);
      final restored = SshProfiles(store, secrets);
      await restored.restore();
      expect(restored.profiles, isEmpty);
      final orphan = SshProfiles.newId();
      await secrets.write(orphan, Uint8List.fromList([7]));
      await store.write(
        'ssh.profiles',
        jsonEncode({
          'version': 1,
          'profiles': [],
          'pendingDeletes': [orphan],
        }),
      );
      await restored.restore();
      expect(secrets.ids, isEmpty);
      expect(
        jsonDecode((await store.read('ssh.profiles'))!)['pendingDeletes'],
        isEmpty,
      );
    },
  );
  test(
    'unavailable cleanup never prevents using session-only secrets',
    () async {
      final store = MemoryStore();
      final secrets = SecureMemory();
      final pending = SshProfiles.newId();
      await secrets.write(pending, Uint8List.fromList([1]));
      await store.write(
        'ssh.profiles',
        jsonEncode({
          'version': 1,
          'profiles': [],
          'pendingDeletes': [pending],
        }),
      );
      secrets.enabled = false;
      secrets.failDelete = true;
      final repository = SshProfiles(store, secrets);
      await repository.restore();
      expect(repository.hasPendingSecretCleanup, isTrue);
      final p = profile(SshProfiles.newId());
      await repository.save(p, secret: Uint8List.fromList([2]));
      expect(await repository.readSecret(repository.profiles.single), [2]);
      expect(repository.hasPendingSecretCleanup, isTrue);
      secrets.failDelete = false;
      secrets.enabled = true;
      await repository.restore();
      expect(repository.hasPendingSecretCleanup, isFalse);
      expect(await secrets.read(pending), isNull);
    },
  );
  test('secure deletion failure preserves profile for retry', () async {
    final secrets = SecureMemory();
    final repository = SshProfiles(MemoryStore(), secrets);
    final p = profile(SshProfiles.newId());
    await repository.save(
      p,
      secret: Uint8List.fromList([1]),
      persistSecret: true,
    );
    secrets.failDelete = true;
    await expectLater(repository.delete(p.id), throwsStateError);
    expect(repository.profiles.length, 1);
    secrets.failDelete = false;
    await repository.delete(p.id);
    expect(secrets.ids, isEmpty);
  });
  test('imports only bounded unencrypted single Ed25519 OpenSSH keys', () {
    validateEd25519PrivateKey(keyFixture());
    for (final key in [
      keyFixture(encrypted: true),
      keyFixture(wrongPublic: true),
      keyFixture(badPadding: true),
      keyFixture(mismatchCheck: true),
      keyFixture(count: 2),
      keyFixture(algorithm: 'ssh-rsa'),
      'ssh-ed25519 AAAA',
      '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----',
      'x' * 65537,
    ]) {
      expect(() => validateEd25519PrivateKey(key), throwsFormatException);
    }
  });
  test('truncation and forged binary lengths fail without leaking input', () {
    final fixture = keyFixture();
    final bytes = base64Decode(fixture.split('\n')[1]);
    for (var length = 0; length < bytes.length; length++) {
      final text =
          '-----BEGIN OPENSSH PRIVATE KEY-----\n${base64Encode(bytes.sublist(0, length))}\n-----END OPENSSH PRIVATE KEY-----';
      expect(() => validateEd25519PrivateKey(text), throwsFormatException);
    }
    ByteData.sublistView(bytes).setUint32(15, 0xffffffff);
    expect(
      () => validateEd25519PrivateKey(
        '-----BEGIN OPENSSH PRIVATE KEY-----\n${base64Encode(bytes)}\n-----END OPENSSH PRIVATE KEY-----',
      ),
      throwsFormatException,
    );
  });
  test(
    'restore corruption is rejected without modifying persistent data',
    () async {
      final store = MemoryStore();
      await store.write('ssh.profiles', '{"password":"private-marker"}');
      final repository = SshProfiles(store, SecureMemory());
      try {
        await repository.restore();
        fail('must reject');
      } on FormatException catch (e) {
        expect(e.toString(), isNot(contains('private-marker')));
      }
      expect(await store.read('ssh.profiles'), contains('private-marker'));
    },
  );
  test(
    'native adapter treats missing channel as unavailable and transfers byte data',
    () async {
      final native = NativeSshSecrets();
      expect(await native.available, isFalse);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeSshSecrets.channel, (call) async {
            calls.add(call);
            return call.method == 'read' ? Uint8List.fromList([7, 8]) : null;
          });
      final id = SshProfiles.newId();
      await native.write(id, Uint8List.fromList([7, 8]));
      expect(await native.read(id), [7, 8]);
      await native.delete(id);
      expect(calls.map((c) => c.method), ['write', 'read', 'delete']);
      expect(() => native.read('../escape'), throwsArgumentError);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeSshSecrets.channel, null);
    },
  );
}
