import '../persistence/schema.dart';

/// ARGB colors keep theme packages independent of Flutter.
class IdeTheme {
  const IdeTheme(
    this.id,
    this.name,
    this.version,
    this.dark,
    this.colors,
    this.fontFamily,
    this.iconTheme,
  );
  final String id, name, version, fontFamily, iconTheme;
  final bool dark;
  final Map<String, int> colors;
  int color(String token) => colors[token] ?? colors['foreground']!;
  factory IdeTheme.parse(String source) {
    final data = decodeVersioned(source, 'Theme');
    final raw = data['colors'];
    if (raw is! Map<String, dynamic>) {
      throw const SchemaException('Invalid theme colors');
    }
    final colors = <String, int>{};
    for (final e in raw.entries) {
      if (e.value is! String ||
          !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(e.value as String)) {
        throw SchemaException('Invalid color ${e.key}');
      }
      colors[e.key] =
          0xff000000 | int.parse((e.value as String).substring(1), radix: 16);
    }
    for (final key in [
      'shell',
      'panel',
      'editor',
      'foreground',
      'muted',
      'border',
      'accent',
      'selection',
      'currentLine',
    ]) {
      if (!colors.containsKey(key)) throw SchemaException('Missing color $key');
    }
    if (data['dark'] is! bool) {
      throw const SchemaException('Theme.dark must be a boolean');
    }
    return IdeTheme(
      requiredString(data, 'id'),
      requiredString(data, 'name'),
      requiredString(data, 'packageVersion'),
      data['dark'] as bool,
      colors,
      data['fontFamily'] as String? ?? 'monospace',
      data['iconTheme'] as String? ?? 'material',
    );
  }
}
