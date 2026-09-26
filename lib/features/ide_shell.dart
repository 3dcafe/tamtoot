import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/ide_session.dart';
import '../app/providers.dart';
import '../app/session_commands.dart';
import '../editor/widgets/code_editor.dart';
import '../editor/input/keyboard_mapping.dart';
import 'dialogs.dart';
import 'dock_view.dart';

class IdeShell extends ConsumerStatefulWidget {
  const IdeShell({super.key});
  @override
  ConsumerState<IdeShell> createState() => _IdeShellState();
}

class _IdeShellState extends ConsumerState<IdeShell> {
  final _find = TextEditingController(), _replace = TextEditingController();
  late IdeSession session;
  @override
  void initState() {
    super.initState();
    session = ref.read(sessionProvider);
    if (!session.commands.contains('file.open')) {
      registerSessionCommands(session, ShellActions(() => context, session));
    }
  }

  @override
  void dispose() {
    _find.dispose();
    _replace.dispose();
    super.dispose();
  }

  Color color(String token) => Color(session.theme.color(token));
  Widget action(IconData icon, String tooltip, String command) => IconButton(
    tooltip: tooltip,
    onPressed: session.commands.isEnabled(command)
        ? () => session.run(command)
        : null,
    icon: Icon(icon, size: 18),
    visualDensity: VisualDensity.compact,
  );
  @override
  Widget build(BuildContext context) {
    ref.watch(sessionChangesProvider);
    return Focus(
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        // Native text inputs in dialogs/find retain their own editing shortcuts.
        if (FocusManager.instance.primaryFocus?.context
                ?.findAncestorStateOfType<EditableTextState>() !=
            null) {
          return KeyEventResult.ignored;
        }
        final chord = keyChord(event);
        final command = session.keys.resolve(chord);
        if (command == null || !chord.contains('+')) {
          return KeyEventResult.ignored;
        }
        session.run(command);
        return KeyEventResult.handled;
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _menu(),
              _toolbar(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                  child: DockView(
                    session: session,
                    node: session.layout.root,
                    documents: (_) => _documents(),
                    panel: _panel,
                  ),
                ),
              ),
              _status(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menu() => SizedBox(
    height: 42,
    child: Row(
      children: [
        const SizedBox(width: 16),
        Container(
          width: 23,
          height: 23,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color('accent'),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            't',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 19,
              color: color('editor'),
            ),
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          'TAMTOOT',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 12,
            letterSpacing: 1.8,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _menuItem('File', [
                  'file.new',
                  'file.open',
                  'workspace.open',
                  'file.save',
                  'file.saveAs',
                  'file.saveAll',
                  'file.close',
                ]),
                _menuItem('Edit', [
                  'editor.undo',
                  'editor.redo',
                  'editor.copy',
                  'editor.cut',
                  'editor.paste',
                  'editor.find',
                  'editor.replace',
                ]),
                _menuItem('View', [
                  'view.solutionExplorer',
                  'view.problems',
                  'view.output',
                  'view.terminal',
                  'view.debug',
                  'view.theme',
                  'layout.reset',
                  'view.commands',
                ]),
                _menuItem('Tools', ['settings.open', 'extensions.manage']),
              ],
            ),
          ),
        ),
        action(Icons.search, 'Commands (Ctrl/⌘ Shift P)', 'view.commands'),
        action(
          session.theme.dark
              ? Icons.light_mode_outlined
              : Icons.dark_mode_outlined,
          'Switch theme',
          'view.theme',
        ),
        const SizedBox(width: 8),
      ],
    ),
  );
  Widget _menuItem(String title, List<String> ids) => PopupMenuButton<String>(
    tooltip: title,
    onSelected: (id) => session.run(id),
    itemBuilder: (_) => [
      for (final id in ids)
        PopupMenuItem(
          value: id,
          enabled: session.commands.isEnabled(id),
          child: Text(
            session.commands.commands.firstWhere((c) => c.id == id).title,
          ),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Text(title, style: const TextStyle(fontSize: 12)),
    ),
  );
  Widget _toolbar() => Container(
    height: 44,
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: color('panel'),
      border: Border.symmetric(horizontal: BorderSide(color: color('border'))),
    ),
    child: Row(
      children: [
        const SizedBox(width: 8),
        action(Icons.note_add_outlined, 'New document', 'file.new'),
        action(Icons.folder_open, 'Open file', 'file.open'),
        action(Icons.save_outlined, 'Save (Ctrl/⌘ S)', 'file.save'),
        const VerticalDivider(indent: 10, endIndent: 10),
        action(Icons.undo, 'Undo', 'editor.undo'),
        action(Icons.redo, 'Redo', 'editor.redo'),
        const VerticalDivider(indent: 10, endIndent: 10),
        Expanded(
          child: Text(
            session.workspaceRoot?.path ?? 'Welcome workspace',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: color('muted')),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            'FOUNDATION  0.1',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1,
              color: color('accent'),
            ),
          ),
        ),
      ],
    ),
  );
  Widget _documents() {
    final active = session.documents.active;
    return ColoredBox(
      color: color('editor'),
      child: Column(
        children: [
          Container(
            height: 38,
            color: color('shell'),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final doc in session.documents.documents)
                  Container(
                    decoration: BoxDecoration(
                      color: doc == active ? color('editor') : color('panel'),
                      border: Border(
                        top: BorderSide(
                          width: 2,
                          color: doc == active
                              ? color('accent')
                              : Colors.transparent,
                        ),
                        right: BorderSide(color: color('border')),
                      ),
                    ),
                    child: Row(
                      children: [
                        InkWell(
                          onTap: () => session.run('document.activate', doc.id),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.code,
                                  size: 15,
                                  color: color(
                                    doc.name.endsWith('.cs')
                                        ? 'keyword'
                                        : 'type',
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  doc.name,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                if (doc.dirty)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8),
                                    child: Icon(
                                      Icons.circle,
                                      size: 6,
                                      color: color('accent'),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close ${doc.name}',
                          onPressed: () => session.run('file.close', doc.id),
                          icon: const Icon(Icons.close, size: 14),
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (session.findVisible) _findBar(),
          if (active != null)
            Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: color('border'))),
              ),
              child: Text(
                'Workspace  ›  ${active.name}',
                style: TextStyle(fontSize: 11, color: color('muted')),
              ),
            ),
          Expanded(
            child: active == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.code, size: 48, color: color('muted')),
                        const SizedBox(height: 12),
                        const Text('A place for your next idea'),
                        TextButton(
                          onPressed: () => session.run('file.open'),
                          child: const Text('Open a file'),
                        ),
                      ],
                    ),
                  )
                : CodeEditor(
                    key: const ValueKey('editor'),
                    controller: active.editor,
                    session: session,
                    language: session.languages.forPath(active.name),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _findBar() => Padding(
    padding: const EdgeInsets.all(8),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 190,
          child: TextField(
            controller: _find,
            decoration: const InputDecoration(
              hintText: 'Find',
              contentPadding: EdgeInsets.all(10),
            ),
            onSubmitted: (v) => session.run('editor.findNext', v),
          ),
        ),
        TextButton(
          onPressed: () => session.run('editor.findNext', _find.text),
          child: const Text('Next'),
        ),
        if (session.replaceVisible) ...[
          SizedBox(
            width: 160,
            child: TextField(
              controller: _replace,
              decoration: const InputDecoration(
                hintText: 'Replace',
                contentPadding: EdgeInsets.all(10),
              ),
            ),
          ),
          TextButton(
            onPressed: () =>
                session.run('editor.replaceAll', [_find.text, _replace.text]),
            child: const Text('Replace all'),
          ),
        ],
        action(Icons.close, 'Close find', 'editor.find'),
      ],
    ),
  );
  Widget _panel(String id) {
    if (id == 'explorer') return _explorer();
    final lines = switch (id) {
      'output' => session.output,
      'problems' =>
        session.errors.isEmpty
            ? [
                'No application errors.',
                'Language diagnostics: provider not connected.',
              ]
            : session.errors,
      'terminal' => [
        'Terminal sessions',
        '',
        'PTY / process adapter is not connected in v0.1.',
        'This panel is ready for a platform terminal provider.',
      ],
      'debug' => ['Debug adapter is not connected in v0.1.'],
      _ => ['Panel unavailable: $id'],
    };
    return ColoredBox(
      color: color('panel'),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: SelectableText(
                line,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: color(
                    id == 'problems' && session.errors.isNotEmpty
                        ? 'error'
                        : 'muted',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _explorer() => ColoredBox(
    color: color('panel'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: color('border'))),
          ),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Solution Explorer',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              action(
                Icons.create_new_folder_outlined,
                'Open workspace folder',
                'workspace.open',
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Text(
                  'OPEN DOCUMENTS',
                  style: TextStyle(
                    color: color('muted'),
                    fontSize: 10,
                    letterSpacing: 1,
                  ),
                ),
              ),
              for (final d in session.documents.documents)
                _entry(
                  d.name,
                  Icons.description_outlined,
                  () => session.run('document.activate', d.id),
                  selected: session.documents.active == d,
                ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Text(
                  'WORKSPACE',
                  style: TextStyle(
                    color: color('muted'),
                    fontSize: 10,
                    letterSpacing: 1,
                  ),
                ),
              ),
              if (session.workspaceRoot == null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Open a folder to explore a project.\n\nOn tablets, use Open file to choose a document.',
                    style: TextStyle(
                      color: color('muted'),
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                ),
              if (session.workspaceRoot != null) ...[
                _entry(
                  '..',
                  Icons.drive_folder_upload_outlined,
                  () => session.run(
                    'workspace.browse',
                    session.workspaceRoot!.resolve('../'),
                  ),
                ),
                for (final e in session.entries)
                  _entry(
                    e.name,
                    e.directory
                        ? Icons.folder_outlined
                        : Icons.description_outlined,
                    () => session.run(
                      e.directory ? 'workspace.browse' : 'file.openEntry',
                      e.directory ? e.uri : e,
                    ),
                  ),
              ],
              if (session.recentWorkspaces.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'RECENT FOLDERS',
                    style: TextStyle(color: color('muted'), fontSize: 10),
                  ),
                ),
                for (final path in session.recentWorkspaces)
                  _entry(
                    Uri.parse(
                          path,
                        ).pathSegments.where((s) => s.isNotEmpty).lastOrNull ??
                        path,
                    Icons.history,
                    () => session.run('workspace.browse', Uri.parse(path)),
                  ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.extension_outlined, size: 15, color: color('accent')),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '${session.languages.languages.length} languages',
                  style: TextStyle(fontSize: 11, color: color('muted')),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _entry(
    String name,
    IconData icon,
    VoidCallback onTap, {
    bool selected = false,
  }) => Material(
    color: selected ? color('selection') : Colors.transparent,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color('muted')),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _status() {
    final editor = session.documents.active?.editor;
    final point = editor?.buffer.positionAt(editor.selection.extent);
    return Container(
      height: 28,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: color('selection'),
      child: Row(
        children: [
          Icon(
            session.errors.isEmpty
                ? Icons.check_circle_outline
                : Icons.error_outline,
            size: 13,
            color: color(session.errors.isEmpty ? 'accent' : 'error'),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              session.message,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ),
          if (point != null)
            Text(
              'Ln ${point.line + 1}, Col ${point.column + 1}   |   ${editor!.readOnly ? 'READ ONLY' : 'UTF-8'}   |   ${session.languages.forPath(session.documents.active!.name)?.name ?? 'Plain text'}',
              style: const TextStyle(fontSize: 11),
            ),
        ],
      ),
    );
  }
}
