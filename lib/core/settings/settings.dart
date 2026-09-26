import 'dart:convert';
import '../persistence/schema.dart';

class SettingsService {
  static const defaults = <String, Object>{
    'theme': 'night',
    'fontFamily': 'JetBrainsMono',
    'fontSize': 14.0,
    'tabSize': 2,
    'insertSpaces': true,
    'readOnly': false,
  };
  final Map<String, Object> user = {}, workspace = {};
  Object get(String key) => workspace[key] ?? user[key] ?? defaults[key]!;
  double get fontSize => (get('fontSize') as num).toDouble();
  String get theme => get('theme') as String;
  void set(String key, Object value, {bool forWorkspace = false}) {
    _validate(key, value);
    (forWorkspace ? workspace : user)[key] = value;
  }

  static void _validate(String key, Object value) {
    if (!defaults.containsKey(key)) return;
    final valid = switch (key) {
      'fontSize' => value is num && value >= 8 && value <= 40,
      'tabSize' => value is int && value >= 1 && value <= 8,
      'insertSpaces' || 'readOnly' => value is bool,
      _ => value is String && value.isNotEmpty,
    };
    if (!valid) throw SchemaException('Invalid setting $key: $value');
  }

  void restore(String source) {
    final data = decodeVersioned(source, 'Settings');
    Map<String, Object> normalize(Object? raw) {
      if (raw is! Map<String, dynamic>) {
        throw const SchemaException('Invalid settings layer');
      }
      final result = <String, Object>{};
      for (final entry in raw.entries) {
        if (entry.value == null) continue;
        _validate(entry.key, entry.value as Object);
        result[entry.key] = entry.value as Object;
      }
      return result;
    }

    final u = normalize(data['user'] ?? {}),
        w = normalize(data['workspace'] ?? {});
    user
      ..clear()
      ..addAll(u);
    workspace
      ..clear()
      ..addAll(w);
  }

  String encode() =>
      jsonEncode({'schemaVersion': 1, 'user': user, 'workspace': workspace});
}
