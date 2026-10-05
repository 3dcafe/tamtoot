import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/ssh/ssh_profiles.dart';

class NativeSshSecrets implements SshSecretStore {
  static const channel = MethodChannel('dev.tamtoot/ssh_secrets');
  @override
  Future<bool> get available async {
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.linux) return false;
    try {
      return await channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  void _validate(String id) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw ArgumentError('Invalid secret reference');
    }
  }

  @override
  Future<void> write(String id, Uint8List value) async {
    _validate(id);
    await channel.invokeMethod<void>('write', {'id': id, 'value': value});
  }

  @override
  Future<Uint8List?> read(String id) {
    _validate(id);
    return channel.invokeMethod<Uint8List>('read', {'id': id});
  }

  @override
  Future<void> delete(String id) async {
    _validate(id);
    await channel.invokeMethod<void>('delete', {'id': id});
  }
}
