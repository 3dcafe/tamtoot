import '../core/commands/commands.dart';
import '../core/filesystem/filesystem.dart';
import '../workspace/layout/dock_layout.dart';
import 'ide_session.dart';
import '../languages/package_service.dart';

abstract interface class PresentationActions {
  Future<String?> readClipboard();
  Future<void> writeClipboard(String value);
  Future<bool> confirmDiscard(String name);
  Future<void> showCommands();
  Future<void> showSettings();
  Future<void> showExtensions();
}

void registerSessionCommands(IdeSession s, PresentationActions ui) {
  void add(
    String id,
    String title,
    dynamic Function(Object?) action, {
    bool Function()? enabled,
  }) => s.commands.register(
    CommandDescriptor(
      id: id,
      title: title,
      category: id.split('.').first,
      enabled: enabled,
      handler: (arg) async {
        final result = await action(arg);
        s.changed();
        return result;
      },
    ),
  );
  bool editor() => s.documents.active != null;
  add('file.new', 'New document', (_) {
    s.observe(s.documents.create('untitled.dart', ''));
  });
  add('file.open', 'Open file…', (_) async {
    final entry = await s.documents.dialogs.open();
    if (entry != null) s.observe(await s.documents.open(entry));
  });
  add('file.openEntry', 'Open workspace file', (arg) async {
    s.observe(await s.documents.open(arg as FileEntry));
  });
  add('file.save', 'Save', (_) async {
    if (await s.documents.save(s.documents.active!)) {
      s.log('Saved ${s.documents.active!.name}');
    }
  }, enabled: editor);
  add('file.saveAs', 'Save as…', (_) async {
    await s.documents.save(s.documents.active!, saveAs: true);
  }, enabled: editor);
  add('file.saveAll', 'Save all', (_) async {
    for (final d in s.documents.documents.where((d) => d.dirty).toList()) {
      if (!await s.documents.save(d)) break;
    }
  });
  add('file.close', 'Close document', (arg) async {
    final doc = arg is String
        ? s.documents.documents.where((d) => d.id == arg).firstOrNull
        : s.documents.active;
    if (doc == null) return;
    if (doc.dirty && !await ui.confirmDiscard(doc.name)) return;
    await s.documents.close(doc);
  });
  add('document.activate', 'Activate document', (arg) {
    s.documents.activeId = arg as String;
  });
  add(
    'workspace.open',
    'Open folder…',
    (_) async {
      final root = await s.documents.dialogs.openWorkspace();
      if (root == null) return;
      s.entries = await s.documents.files.list(root);
      s.workspaceRoot = root;
      s.recentWorkspaces
        ..remove(root.toString())
        ..insert(0, root.toString());
      if (s.recentWorkspaces.length > 10) s.recentWorkspaces.removeLast();
    },
    enabled: () => s.documents.dialogs.supportsDirectories,
  );
  add('workspace.browse', 'Browse folder', (arg) async {
    s.entries = await s.documents.files.list(arg as Uri);
    s.workspaceRoot = arg;
  });
  add('editor.undo', 'Undo', (_) {
    s.documents.active!.editor.undo();
  }, enabled: () => s.documents.active?.editor.canUndo ?? false);
  add('editor.redo', 'Redo', (_) {
    s.documents.active!.editor.redo();
  }, enabled: () => s.documents.active?.editor.canRedo ?? false);
  add('editor.insert', 'Insert text', (arg) {
    s.documents.active!.editor.replaceSelection(arg as String);
  }, enabled: editor);
  add('editor.select', 'Select text', (arg) {
    final range = arg as List<int>;
    s.documents.active!.editor.select(range[0], range[1]);
  }, enabled: editor);
  add('editor.selectAll', 'Select all', (_) {
    s.documents.active!.editor.select(
      0,
      s.documents.active!.editor.buffer.length,
    );
  }, enabled: editor);
  for (final direction in [
    'left',
    'right',
    'up',
    'down',
    'home',
    'end',
    'start',
    'finish',
  ]) {
    add('editor.$direction', 'Move $direction', (_) {
      s.documents.active!.editor.move(direction);
    }, enabled: editor);
    add(
      'editor.select${direction[0].toUpperCase()}${direction.substring(1)}',
      'Select $direction',
      (_) {
        s.documents.active!.editor.move(direction, extend: true);
      },
      enabled: editor,
    );
  }
  add('editor.backspace', 'Backspace', (_) {
    s.documents.active!.editor.delete();
  }, enabled: editor);
  add('editor.delete', 'Delete', (_) {
    s.documents.active!.editor.delete(backwards: false);
  }, enabled: editor);
  add('editor.newline', 'New line', (_) {
    s.documents.active!.editor.replaceSelection('\n');
  }, enabled: editor);
  add('editor.tab', 'Indent', (_) {
    final e = s.documents.active!.editor;
    e.replaceSelection(e.insertSpaces ? ' ' * e.tabSize : '\t');
  }, enabled: editor);
  add('editor.copy', 'Copy', (_) async {
    final e = s.documents.active!.editor;
    await ui.writeClipboard(
      e.buffer.getText(e.selection.start, e.selection.end),
    );
  }, enabled: editor);
  add('editor.cut', 'Cut', (_) async {
    final e = s.documents.active!.editor;
    if (e.readOnly) return;
    await ui.writeClipboard(
      e.buffer.getText(e.selection.start, e.selection.end),
    );
    e.replaceSelection('');
  }, enabled: editor);
  add('editor.paste', 'Paste', (_) async {
    final e = s.documents.active!.editor;
    final text = await ui.readClipboard();
    if (text != null) e.replaceSelection(text);
  }, enabled: editor);
  add('editor.find', 'Find', (_) {
    s.findVisible = !s.findVisible;
    s.replaceVisible = false;
  });
  add('editor.replace', 'Find and replace', (_) {
    s.findVisible = true;
    s.replaceVisible = true;
  });
  add('editor.findNext', 'Find next', (arg) {
    s.findQuery = arg as String;
    if (!s.documents.active!.editor.find(s.findQuery)) s.log('No matches');
  }, enabled: editor);
  add('editor.replaceAll', 'Replace all', (arg) {
    final values = arg as List<String>;
    s.documents.active!.editor.replaceAll(values[0], values[1]);
  }, enabled: editor);
  add('view.theme', 'Switch light / dark theme', (_) {
    s.settings.set('theme', s.theme.dark ? 'day' : 'night');
  });
  add('view.commands', 'Command palette', (_) => ui.showCommands());
  add('settings.open', 'Settings & keybindings', (_) => ui.showSettings());
  add('extensions.manage', 'Language packages', (_) => ui.showExtensions());
  add('extensions.install', 'Install language package', (arg) async {
    final values = arg as List<String>;
    final language = await PackageService(
      s.store,
      s.languages,
    ).install(values[0], values[1], values[2].isEmpty ? null : values[2]);
    s.log('Installed ${language.name}');
  });
  add('settings.set', 'Change setting', (arg) {
    final values = arg as MapEntry<String, Object>;
    s.settings.set(values.key, values.value);
    for (final d in s.documents.documents) {
      s.configure(d);
    }
  });
  add('keybindings.set', 'Apply keybindings JSON', (arg) {
    s.keys = KeybindingRegistry.parse(arg as String);
  });
  add('layout.resize', 'Resize panel', (arg) {
    final values = arg as MapEntry<String, double>;
    s.layout = s.layout.resize(values.key, values.value);
  });
  add('layout.activate', 'Select tool window', (arg) {
    final values = arg as MapEntry<String, String>;
    s.layout = s.layout.activate(values.key, values.value);
  });
  add('layout.reset', 'Restore default layout', (_) {
    s.layout = DockLayout.defaultLayout;
  });
  for (final panel in DockLayout.panelIds) {
    add(
      'view.${panel == 'explorer' ? 'solutionExplorer' : panel}',
      'Toggle $panel',
      (_) {
        s.layout = s.layout.toggle(panel);
      },
    );
  }
}
