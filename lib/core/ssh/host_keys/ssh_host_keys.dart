import 'dart:convert';
import 'dart:typed_data';
import '../../filesystem/filesystem.dart';
import '../crypto/ssh_crypto.dart';
import '../ssh_error.dart';
import '../transport/ssh_codec.dart';

String normalizeSshHost(String value) {
  var host = value.trim();
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  if (host.isEmpty ||
      host.length > 253 ||
      RegExp(r'[\s/\x00-\x1f]').hasMatch(host)) {
    throw const SshException('Invalid SSH server name.');
  }
  if (!host.contains(':')) {
    final parts = host.split('.');
    if (parts.length == 4 &&
        parts.every(
          (p) => RegExp(r'^\d{1,3}$').hasMatch(p) && int.parse(p) <= 255,
        )) {
      return parts.map(int.parse).join('.');
    }
    return host.toLowerCase().replaceAll(RegExp(r'\.+$'), '');
  }
  final zone = host.split('%');
  if (zone.length > 2 ||
      (zone.length == 2 &&
          !RegExp(r'^[a-zA-Z0-9_.-]{1,32}$').hasMatch(zone[1]))) {
    throw const SshException('Invalid IPv6 scope.');
  }
  var address = zone[0];
  if (address.contains('.')) {
    final split = address.lastIndexOf(':');
    final v4 = address.substring(split + 1).split('.');
    if (v4.length != 4 ||
        v4.any((p) => !RegExp(r'^\d{1,3}$').hasMatch(p) || int.parse(p) > 255)) {
      throw const SshException('Invalid IPv6 address.');
    }
    final nums = v4.map(int.parse).toList();
    address =
        '${address.substring(0, split + 1)}${(nums[0] * 256 + nums[1]).toRadixString(16)}:${(nums[2] * 256 + nums[3]).toRadixString(16)}';
  }
  final halves = address.split('::');
  if (halves.length > 2) throw const SshException('Invalid IPv6 address.');
  List<String> parts(String text) => text.isEmpty ? [] : text.split(':');
  final left = parts(halves.first),
      right = halves.length == 2 ? parts(halves.last) : <String>[];
  if ([
        ...left,
        ...right,
      ].any((p) => !RegExp(r'^[a-fA-F0-9]{1,4}$').hasMatch(p)) ||
      (halves.length == 1 ? left.length != 8 : left.length + right.length >= 8)) {
    throw const SshException('Invalid IPv6 address.');
  }
  final all = [
    ...left,
    if (halves.length == 2) ...List.filled(8 - left.length - right.length, '0'),
    ...right,
  ];
  return all.map((p) => int.parse(p, radix: 16).toRadixString(16)).join(':') +
      (zone.length == 2 ? '%${zone[1]}' : '');
}

class SshHostKey {
  SshHostKey(List<int> blob, SshCrypto crypto)
    : blob = Uint8List.fromList(blob) {
    final reader = SshReader(this.blob);
    algorithm = reader.asciiText(limit: 128);
    if (algorithm != 'ssh-ed25519') {
      throw const SshException('Unsupported SSH server key algorithm.');
    }
    publicKey = Uint8List.fromList(reader.string(limit: 32));
    reader.end();
    if (publicKey.length != 32) {
      throw const SshException('Malformed SSH server key.');
    }
    fingerprint =
        'SHA256:${base64Encode(crypto.sha256(this.blob)).replaceAll('=', '')}';
  }
  final Uint8List blob;
  late final Uint8List publicKey;
  late final String algorithm, fingerprint;
}

enum SshHostKeyDecision { reject, once, save, replace }

class SshHostKeyChallenge {
  SshHostKeyChallenge(
    this.host,
    this.port,
    this.key,
    this.previousFingerprints,
  );
  final String host;
  final int port;
  final SshHostKey key;
  final List<String> previousFingerprints;
  bool get changed => previousFingerprints.isNotEmpty;
}

class SshKnownHost {
  SshKnownHost(this.host, this.port, List<List<int>> keys)
    : keys = keys.map(Uint8List.fromList).toList();
  final String host;
  final int port;
  final List<Uint8List> keys;
  Map<String, Object> toJson() => {
    'host': host,
    'port': port,
    'keys': keys.map(base64Encode).toList(),
  };
}

class SshHostKeys {
  SshHostKeys(this.store);
  final PersistenceStore store;
  List<SshKnownHost> _hosts = [];
  List<SshKnownHost> get hosts => List.unmodifiable(
    _hosts.map((h) => SshKnownHost(h.host, h.port, h.keys)),
  );
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() operation) {
    final task = _tail.then((_) => operation());
    _tail = task.then((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<void> restore() => _serial(() async {
    final source = await store.read('ssh.knownHosts');
    if (source == null) return;
    try {
      if (source.length > 2 * 1024 * 1024) throw const FormatException();
      final json = jsonDecode(source) as Map<String, dynamic>;
      if (json['version'] != 1) throw const FormatException();
      final records = json['hosts'] as List;
      if (records.length > 1000) throw const FormatException();
      final hosts = <SshKnownHost>[];
      final unique = <String>{};
      for (final item in records) {
        final host = normalizeSshHost(item['host'] as String),
            port = item['port'] as int;
        final encoded = item['keys'] as List;
        if (port < 1 ||
            port > 65535 ||
            encoded.isEmpty ||
            encoded.length > 8 ||
            !unique.add('$host|$port')) {
          throw const FormatException();
        }
        final keys = <Uint8List>[];
        for (final key in encoded) {
          if (key is! String || key.length > 1024) {
            throw const FormatException();
          }
          final blob = base64Decode(key);
          final reader = SshReader(blob);
          if (reader.asciiText() != 'ssh-ed25519' ||
              reader.string(limit: 32).length != 32) {
            throw const FormatException();
          }
          reader.end();
          if (keys.any((existing) => sshBytesEqual(existing, blob))) {
            throw const FormatException();
          }
          keys.add(blob);
        }
        hosts.add(SshKnownHost(host, port, keys));
      }
      _hosts = hosts;
    } catch (_) {
      throw const SshException(
        'Unable to load SSH server trust records. Stored data was preserved.',
      );
    }
  });
  Future<void> _persist(List<SshKnownHost> hosts) async {
    await store.write(
      'ssh.knownHosts',
      jsonEncode({
        'version': 1,
        'hosts': hosts.map((h) => h.toJson()).toList(),
      }),
    );
    _hosts = hosts;
  }

  Future<void> verify(
    String address,
    int port,
    SshHostKey key,
    SshCrypto crypto,
    Future<SshHostKeyDecision> Function(SshHostKeyChallenge) confirm,
  ) => _serial(() async {
    final host = normalizeSshHost(address);
    final old = _hosts
        .where((h) => h.host == host && h.port == port)
        .firstOrNull;
    if (old != null && old.keys.any((blob) => sshBytesEqual(blob, key.blob))) {
      return;
    }
    final challenge = SshHostKeyChallenge(host, port, key, [
      for (final blob in old?.keys ?? <Uint8List>[])
        SshHostKey(blob, crypto).fingerprint,
    ]);
    final decision = await confirm(challenge);
    if (decision == SshHostKeyDecision.reject) {
      throw const SshException('SSH server key was not trusted.');
    }
    if (decision == SshHostKeyDecision.once) return;
    final keys = decision == SshHostKeyDecision.replace
        ? <Uint8List>[]
        : [...?old?.keys];
    if (keys.length >= 8 || (old == null && _hosts.length >= 1000)) {
      throw const SshException('SSH server trust record limit reached.');
    }
    await _persist([
      ..._hosts.where((h) => h.host != host || h.port != port),
      SshKnownHost(host, port, [...keys, key.blob]),
    ]);
  });
  Future<void> forget(String host, int port, List<int> key) => _serial(
    () async {
      final normalized = normalizeSshHost(host);
      final result = <SshKnownHost>[];
      for (final item in _hosts) {
        if (item.host == normalized && item.port == port) {
          final keys = item.keys.where((k) => !sshBytesEqual(k, key)).toList();
          if (keys.isNotEmpty) {
            result.add(SshKnownHost(item.host, item.port, keys));
          }
        } else {
          result.add(item);
        }
      }
      await _persist(result);
    },
  );
}
