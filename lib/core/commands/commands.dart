import 'dart:async';
import '../persistence/schema.dart';

/// Public command contribution. Handlers receive command-specific arguments.
class CommandDescriptor {
  const CommandDescriptor({
    required this.id,
    required this.title,
    required this.handler,
    this.category = 'IDE',
    this.enabled,
    this.visible,
  });
  final String id, title, category;
  final FutureOr<Object?> Function(Object?) handler;
  final bool Function()? enabled, visible;
}

class CommandRegistry {
  final Map<String, CommandDescriptor> _commands = {};
  Iterable<CommandDescriptor> get commands =>
      _commands.values.where((c) => c.visible?.call() ?? true);
  void register(CommandDescriptor command) {
    if (_commands.containsKey(command.id)) {
      throw StateError('Duplicate command: ${command.id}');
    }
    _commands[command.id] = command;
  }

  void unregister(String id) => _commands.remove(id);
  bool contains(String id) => _commands.containsKey(id);
  bool isEnabled(String id) =>
      _commands[id]?.enabled?.call() ?? _commands.containsKey(id);
  Future<Object?> execute(String id, [Object? argument]) async {
    final command = _commands[id];
    if (command == null) throw StateError('Unknown command: $id');
    if (!(command.enabled?.call() ?? true)) return null;
    return await command.handler(argument);
  }
}

class KeybindingRegistry {
  KeybindingRegistry([Map<String, String>? overrides])
    : bindings = {...defaults, ...?overrides};
  static const defaults = {
    'ctrl+s': 'file.save',
    'meta+s': 'file.save',
    'ctrl+shift+s': 'file.saveAll',
    'meta+shift+s': 'file.saveAll',
    'ctrl+o': 'file.open',
    'meta+o': 'file.open',
    'ctrl+z': 'editor.undo',
    'meta+z': 'editor.undo',
    'ctrl+shift+z': 'editor.redo',
    'meta+shift+z': 'editor.redo',
    'ctrl+y': 'editor.redo',
    'ctrl+a': 'editor.selectAll',
    'meta+a': 'editor.selectAll',
    'ctrl+c': 'editor.copy',
    'meta+c': 'editor.copy',
    'ctrl+x': 'editor.cut',
    'meta+x': 'editor.cut',
    'ctrl+v': 'editor.paste',
    'meta+v': 'editor.paste',
    'ctrl+f': 'editor.find',
    'meta+f': 'editor.find',
    'ctrl+h': 'editor.replace',
    'meta+alt+f': 'editor.replace',
    'ctrl+shift+p': 'view.commands',
    'meta+shift+p': 'view.commands',
    'arrow left': 'editor.left',
    'arrow right': 'editor.right',
    'arrow up': 'editor.up',
    'arrow down': 'editor.down',
    'home': 'editor.home',
    'end': 'editor.end',
    'shift+arrow left': 'editor.selectLeft',
    'shift+arrow right': 'editor.selectRight',
    'shift+arrow up': 'editor.selectUp',
    'shift+arrow down': 'editor.selectDown',
    'shift+home': 'editor.selectHome',
    'shift+end': 'editor.selectEnd',
    'backspace': 'editor.backspace',
    'delete': 'editor.delete',
    'enter': 'editor.newline',
    'tab': 'editor.tab',
  };
  final Map<String, String> bindings;
  String? resolve(String chord) => bindings[chord.toLowerCase()];
  factory KeybindingRegistry.parse(String json) {
    final data = decodeVersioned(json, 'Keybindings');
    final items = data['bindings'];
    if (items is! List) throw const SchemaException('bindings must be a list');
    final result = <String, String>{};
    for (final item in items) {
      if (item is! Map<String, dynamic>) {
        throw const SchemaException('Invalid binding');
      }
      result[requiredString(item, 'key').toLowerCase()] = requiredString(
        item,
        'command',
      );
    }
    return KeybindingRegistry(result);
  }
  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'bindings': [
      for (final e in bindings.entries) {'key': e.key, 'command': e.value},
    ],
  };
}
