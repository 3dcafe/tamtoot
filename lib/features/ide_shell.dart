import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/ide_session.dart';
import '../workspace/explorer/file_indicators.dart';
import '../app/providers.dart';
import '../app/session_commands.dart';
import '../editor/widgets/code_editor.dart';
import '../editor/input/keyboard_mapping.dart';
import 'dialogs.dart';
import 'agent_dialog.dart';
import 'git_changes_dialog.dart';
import 'git_diff.dart';
import 'http_requests_dialog.dart';
import 'dock_view.dart';

class IdeShell extends ConsumerStatefulWidget {
  const IdeShell({super.key});
  @override
  ConsumerState<IdeShell> createState() => _IdeShellState();
}

class _IdeShellState extends ConsumerState<IdeShell> {
  final _find = TextEditingController(), _replace = TextEditingController();
  late IdeSession session;
  int _sidebar = 0;
  @override
  void initState() {
    super.initState();
    session = ref.read(sessionProvider);
    // Always ensure commands exist — hot reload can leave an older set.
    registerSessionCommands(session, ShellActions(() => context, session));
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
    // Safe with registerIfAbsent: picks up newly added commands after hot reload.
    registerSessionCommands(session, ShellActions(() => context, session));
    final systemPadding = MediaQuery.paddingOf(context);
    // Tablet window managers can include an external caption bar in the top
    // inset even though the Flutter surface already starts below that bar.
    final topPadding = systemPadding.top > 32 ? 0.0 : systemPadding.top;
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
      child: PopScope(
        canPop: session.documents.active == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) session.run('file.close');
        },
        child: Scaffold(
          // Some tablet window managers report their whole caption area as a
          // safe inset even though Flutter already starts below it.
          body: Padding(
            padding: EdgeInsets.only(
              top: topPadding,
              bottom: systemPadding.bottom,
            ),
            child: Column(
              children: [
                _menu(),
                _toolbar(),
                Expanded(
                  child: DockView(
                    session: session,
                    node: session.layout.root,
                    documents: (_) => _documents(),
                    panel: _panel,
                  ),
                ),
                _status(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menu() {
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _menuItem('File', const [
                    'file.new',
                    'file.open',
                    '—',
                    'workspace.open',
                    'workspace.openProject',
                    'git.clone',
                    '—',
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
                    'workspace.search',
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
                  _menuItem('Git', ['git.changes', 'git.clone']),
                  _menuItem('Tools', [
                    'requests.open',
                    'agent.open',
                    'agent.kanban',
                    'settings.open',
                    'extensions.manage',
                  ]),
                  _menuItem('Help', ['help.privacy']),
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
  }

  Widget _menuItem(String title, List<String> ids) => PopupMenuButton<String>(
    tooltip: title,
    onSelected: (id) {
      if (id == '—') return;
      session.run(id);
    },
    itemBuilder: (_) {
      final items = <PopupMenuEntry<String>>[];
      for (final id in ids) {
        if (id == '—') {
          if (items.isNotEmpty && items.last is! PopupMenuDivider) {
            items.add(const PopupMenuDivider());
          }
          continue;
        }
        if (!session.commands.isVisible(id)) continue;
        final command = session.commands.commands
            .where((c) => c.id == id)
            .firstOrNull;
        items.add(
          PopupMenuItem(
            value: id,
            enabled: session.commands.isEnabled(id),
            child: Text(command?.title ?? id),
          ),
        );
      }
      return items;
    },
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
        const SizedBox(width: 4),
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
            child: Row(
              children: [
                if (active != null) ...[
                  IconButton(
                    key: const ValueKey('editor-back'),
                    tooltip: 'Close editor',
                    onPressed: () => session.run('file.close', active.id),
                    icon: const Icon(Icons.arrow_back, size: 17),
                    visualDensity: VisualDensity.compact,
                  ),
                  const VerticalDivider(width: 1),
                ],
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final doc in session.documents.documents)
                        Container(
                          decoration: BoxDecoration(
                            color: doc == active
                                ? color('editor')
                                : color('panel'),
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
                                onTap: () => session.run(
                                  'document.activate',
                                  doc.id,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    8,
                                    8,
                                    8,
                                  ),
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
                                          padding: const EdgeInsets.only(
                                            left: 8,
                                          ),
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
                                onPressed: () =>
                                    session.run('file.close', doc.id),
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
    if (id == 'output') {
      return ColoredBox(
        color: color('panel'),
        child: Column(
          children: [
            SizedBox(
              height: 34,
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  const Text('Output', style: TextStyle(fontSize: 12)),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey('output-clear'),
                    tooltip: 'Clear Output',
                    onPressed: session.output.isEmpty
                        ? null
                        : session.clearOutput,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: SelectableText(
                    session.output.join('\n'),
                    key: const ValueKey('output-text'),
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: color('muted'),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final lines = switch (id) {
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
      children: [
        Container(
          height: 36,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: color('border'))),
          ),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      TextButton(
                        key: const ValueKey('sidebar-solution'),
                        onPressed: () => setState(() => _sidebar = 0),
                        child: Text(
                          'Solution',
                          style: TextStyle(
                            color: color(_sidebar == 0 ? 'accent' : 'muted'),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      TextButton(
                        key: const ValueKey('sidebar-git'),
                        onPressed: () => setState(() => _sidebar = 1),
                        child: Text(
                          'Git',
                          style: TextStyle(
                            color: color(_sidebar == 1 ? 'accent' : 'muted'),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      TextButton(
                        key: const ValueKey('sidebar-agent'),
                        onPressed: () => setState(() => _sidebar = 2),
                        child: Text(
                          'Agent',
                          style: TextStyle(
                            color: color(_sidebar == 2 ? 'accent' : 'muted'),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      TextButton(
                        key: const ValueKey('sidebar-requests'),
                        onPressed: () => setState(() => _sidebar = 3),
                        child: Text(
                          'Requests',
                          style: TextStyle(
                            color: color(_sidebar == 3 ? 'accent' : 'muted'),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_sidebar == 0)
                action(
                  Icons.refresh,
                  'Refresh project tree and Git status',
                  'workspace.refresh',
                ),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _sidebar,
            children: [
              _solutionTree(),
              if (session.workspaceRoot != null && session.workspaceHasGit)
                GitChangesDialog(
                  key: ValueKey('git-panel-${session.workspaceRoot}'),
                  session: session,
                  embedded: true,
                  visible: _sidebar == 1,
                )
              else
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Open a Git project to review changes and create commits.',
                    ),
                  ),
                ),
              AgentPanel(
                key: ValueKey('agent-panel-${session.workspaceRoot}'),
                session: session,
              ),
              RequestsPanel(
                key: ValueKey('requests-panel-${session.workspaceRoot}'),
                session: session,
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _solutionTree() => ColoredBox(
    color: color('panel'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Tooltip(
                message: _workspaceDescription,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Icon(
                      Icons.folder_outlined,
                      size: 16,
                      color: color('muted'),
                    ),
                  ),
                ),
              ),
              if (session.workspaceRoot == null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    session.git.available
                        ? 'No folder open.\n\nFile → Clone repository… or File → Open project…'
                        : 'No folder open.\n\nUse File → Open file… to edit a document.',
                    style: TextStyle(
                      color: color('muted'),
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                ),
              if (session.workspaceRoot != null) ...[
                if (session.gitStatusNote != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Text(
                      session.gitStatusNote!,
                      style: TextStyle(fontSize: 10, color: color('muted')),
                    ),
                  ),
                if (session.explorer.loading.contains(session.workspaceRoot))
                  const LinearProgressIndicator(),
                if (session.explorer.errors[session.workspaceRoot] != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      session.explorer.errors[session.workspaceRoot]!,
                      style: TextStyle(color: color('error')),
                    ),
                  ),
                for (final row in session.explorer.rows) ...[
                  _entry(
                    row.entry.name,
                    row.entry.directory
                        ? (session.explorer.expanded.contains(row.entry.uri)
                              ? Icons.folder_open_outlined
                              : Icons.folder_outlined)
                        : Icons.description_outlined,
                    () => session.run(
                      row.entry.directory
                          ? 'workspace.toggleFolder'
                          : 'file.openEntry',
                      row.entry.directory ? row.entry.uri : row.entry,
                    ),
                    entryKey: ValueKey('explorer-${row.entry.uri}'),
                    fileUri: row.entry.directory ? null : row.entry.uri,
                    depth: row.depth,
                    directory: row.entry.directory,
                    expanded: session.explorer.expanded.contains(row.entry.uri),
                    loading: session.explorer.loading.contains(row.entry.uri),
                    selected:
                        !row.entry.directory &&
                        session.documents.active?.uri == row.entry.uri,
                    indicators: session.indicators(
                      row.entry.uri,
                      directory: row.entry.directory,
                    ),
                  ),
                  if (session.explorer.errors[row.entry.uri] != null)
                    Padding(
                      padding: EdgeInsets.only(
                        left: 28 + row.depth * 14.0,
                        right: 8,
                      ),
                      child: Text(
                        session.explorer.errors[row.entry.uri]!,
                        style: TextStyle(fontSize: 11, color: color('error')),
                      ),
                    ),
                ],
              ],
            ],
          ),
        ),
      ],
    ),
  );

  String get _workspaceDescription {
    final root = session.workspaceRoot;
    if (root == null) return 'No workspace open';
    String? name;
    final remote = session.projectMeta?.remoteUrl;
    if (remote != null) {
      final uri = Uri.tryParse(remote);
      name = uri?.pathSegments.where((part) => part.isNotEmpty).lastOrNull;
    }
    name ??= root.pathSegments.where((part) => part.isNotEmpty).lastOrNull;
    name = (name ?? root.toString()).replaceFirst(RegExp(r'\.git$'), '');
    final branch = session.projectMeta?.branch;
    return 'Repository: $name${branch == null ? '' : '\nBranch: $branch'}\n$root';
  }

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  Widget _entry(
    String name,
    IconData icon,
    VoidCallback onTap, {
    bool selected = false,
    Key? entryKey,
    Uri? fileUri,
    int depth = 0,
    bool directory = false,
    bool expanded = false,
    bool loading = false,
    FileIndicators indicators = const FileIndicators(),
  }) => GestureDetector(
    onSecondaryTapDown: fileUri == null
        ? null
        : (event) =>
              showFileGitMenu(context, session, fileUri, event.globalPosition),
    onLongPressStart: fileUri == null
        ? null
        : (event) =>
              showFileGitMenu(context, session, fileUri, event.globalPosition),
    child: Tooltip(
      message: indicators.any ? '$name · ${indicators.description}' : name,
      child: Semantics(
        expanded: directory ? expanded : null,
        child: Material(
          key: entryKey,
          color: selected ? color('selection') : Colors.transparent,
          child: InkWell(
            onTap: () {
              _dismissKeyboard();
              onTap();
            },
            child: Padding(
              padding: EdgeInsets.fromLTRB(8 + depth * 14.0, 9, 8, 9),
              child: Row(
                children: [
                  if (directory)
                    Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                      size: 14,
                      color: color('muted'),
                    )
                  else
                    const SizedBox(width: 14),
                  Icon(
                    icon,
                    size: 16,
                    color: color(
                      indicators.any ? indicators.colorToken : 'muted',
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: indicators.any
                            ? color(indicators.colorToken)
                            : null,
                      ),
                    ),
                  ),
                  if (loading)
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1),
                    ),
                  if (indicators.any)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        indicators.badge,
                        style: TextStyle(
                          fontSize: 10,
                          color: color(indicators.colorToken),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
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
