import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/ide_session.dart';
import '../core/git/http_git_service.dart';
import '../core/requests/http_request.dart';
import '../core/requests/request_executor.dart';
import '../core/requests/request_storage.dart';

RequestStorage requestStorageFor(IdeSession session) {
  final root = session.workspaceRoot;
  final git = session.git;
  if (root == null || git is! HttpGitService) {
    throw StateError('Open a supported project first.');
  }
  return RequestStorage(git.openStore(root));
}

class RequestsPanel extends StatefulWidget {
  const RequestsPanel({super.key, required this.session});
  final IdeSession session;

  @override
  State<RequestsPanel> createState() => _RequestsPanelState();
}

class _RequestsPanelState extends State<RequestsPanel> {
  List<RequestEntry> entries = const [];
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant RequestsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.workspaceRoot != widget.session.workspaceRoot) {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final loaded = await requestStorageFor(widget.session).list();
      if (mounted) {
        setState(() {
          entries = loaded;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          entries = const [];
          error = '$e';
        });
      }
    }
  }

  Future<void> _open([String? path]) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          HttpRequestsDialog(session: widget.session, initialPath: path),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.session.workspaceRoot == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Open a project to use HTTP Requests.'),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _open,
                  icon: const Icon(Icons.http),
                  label: const Text('Open Requests'),
                ),
              ),
              IconButton(
                onPressed: _load,
                tooltip: 'Refresh requests',
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: entries.length,
            itemBuilder: (_, index) {
              final entry = entries[index];
              return ListTile(
                dense: true,
                leading: entry.directory
                    ? const Icon(Icons.folder_outlined, size: 18)
                    : Text(
                        entry.method,
                        style: TextStyle(
                          fontSize: 10,
                          color: entry.valid
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.error,
                        ),
                      ),
                title: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  entry.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: entry.valid
                    ? null
                    : const Icon(Icons.warning_amber, size: 16),
                onTap: entry.valid && !entry.directory
                    ? () => _open(entry.path)
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }
}

class HttpRequestsDialog extends StatefulWidget {
  const HttpRequestsDialog({
    super.key,
    required this.session,
    this.initialPath,
  });
  final IdeSession session;
  final String? initialPath;

  @override
  State<HttpRequestsDialog> createState() => _HttpRequestsDialogState();
}

class _HttpRequestsDialogState extends State<HttpRequestsDialog> {
  late final RequestStorage storage;
  final name = TextEditingController(),
      url = TextEditingController(),
      body = TextEditingController();
  List<RequestEntry> entries = const [];
  final selected = <String>{};
  final headers = <_KvDraft>[], query = <_KvDraft>[];
  String method = 'GET',
      bodyType = 'none',
      authMode = 'inherit',
      authToken = '';
  String? activePath, feedback;
  bool dirty = false, busy = false, parallel = false, stopOnError = false;
  bool compactEditorVisible = false;
  List<RequestExecutionResult> results = const [];
  List<RequestAttachment> attachments = const [];

  @override
  void initState() {
    super.initState();
    storage = requestStorageFor(widget.session);
    _load(widget.initialPath);
  }

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    body.dispose();
    for (final item in [...headers, ...query]) {
      item.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (!dirty) setState(() => dirty = true);
  }

  Future<void> _load([String? openPath]) async {
    try {
      final loaded = await storage.list();
      if (!mounted) return;
      setState(() {
        entries = loaded;
        selected.retainAll(loaded.map((e) => e.path));
        feedback = null;
      });
      final path = openPath ?? activePath;
      if (path != null &&
          loaded.any((entry) => entry.path == path && entry.valid)) {
        await _open(path);
      }
    } catch (e) {
      if (mounted) setState(() => feedback = '$e');
    }
  }

  Future<bool> _confirmLose() async {
    if (!dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Unsaved request'),
            content: const Text('Discard the unsaved request changes?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep editing'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _open(String path) async {
    if (path == activePath || !await _confirmLose()) return;
    try {
      final request = await storage.read(path);
      for (final item in [...headers, ...query]) {
        item.dispose();
      }
      headers
        ..clear()
        ..addAll(request.headers.map(_KvDraft.from));
      query
        ..clear()
        ..addAll(request.query.map(_KvDraft.from));
      name.text = request.name;
      url.text = request.url;
      body.text = request.body.type == 'json'
          ? const JsonEncoder.withIndent('  ').convert(request.body.value)
          : request.body.value?.toString() ?? '';
      setState(() {
        activePath = path;
        compactEditorVisible = true;
        method = request.method;
        bodyType = request.body.type;
        authMode = request.auth.mode;
        authToken = request.auth.token;
        attachments = request.attachments;
        dirty = false;
        feedback = null;
        results = const [];
      });
    } catch (e) {
      setState(() => feedback = '$e');
    }
  }

  HttpRequestFile _draft() {
    dynamic bodyValue;
    if (bodyType == 'json' && body.text.trim().isNotEmpty) {
      bodyValue = jsonDecode(body.text);
    }
    if (bodyType == 'text' || bodyType == 'form') bodyValue = body.text;
    if (bodyType == 'form' && body.text.trim().isNotEmpty) {
      bodyValue = {
        for (final line in const LineSplitter().convert(body.text))
          if (line.contains('='))
            line.substring(0, line.indexOf('=')): line.substring(
              line.indexOf('=') + 1,
            ),
      };
    }
    return HttpRequestFile(
      name: name.text.trim(),
      method: method,
      url: url.text.trim(),
      headers: headers.map((e) => e.value).toList(),
      query: query.map((e) => e.value).toList(),
      body: RequestBody(type: bodyType, value: bodyValue),
      auth: RequestAuth(mode: authMode, token: authToken),
      attachments: attachments,
    );
  }

  Future<void> _save() async {
    if (busy) return;
    if (activePath == null) {
      setState(() => feedback = 'Create or select a request first.');
      return;
    }
    setState(() => busy = true);
    try {
      var request = _draft();
      if (request.auth.mode == 'bearer' &&
          request.auth.token.isNotEmpty &&
          !VariableResolver.isVariableReference(request.auth.token)) {
        final environment = await storage.loadEnvironment();
        final key =
            '${RequestStorage.safeName(request.name).replaceAll('-', '_')}_token';
        await storage.saveLocalEnvironment(
          RequestEnvironment(
            variables: {
              ...environment.local.variables,
              key: request.auth.token,
            },
          ),
        );
        authToken = '{{$key}}';
        request = _draft();
      }
      await storage.save(activePath!, request);
      setState(() {
        dirty = false;
        feedback = 'Saved $activePath';
      });
      await _load();
      await widget.session.refreshGitIndicators();
    } catch (e) {
      setState(() => feedback = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<String?> _ask(String title, {String initial = ''}) async {
    var value = initial;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          onChanged: (updated) => value = updated,
          onFieldSubmitted: (submitted) =>
              Navigator.pop(dialogContext, submitted.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, value.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _newRequest() async {
    final value = await _ask('New Request (folder/name)', initial: 'request');
    if (value == null || value.isEmpty) return;
    final slash = value.lastIndexOf('/');
    final folder = slash < 0 ? '' : value.substring(0, slash);
    final title = slash < 0 ? value : value.substring(slash + 1);
    try {
      final entry = await storage.create(folder, HttpRequestFile(name: title));
      await _load(entry.path);
    } catch (e) {
      setState(() => feedback = '$e');
    }
  }

  Future<void> _newFolder() async {
    final value = await _ask('New Folder');
    if (value == null || value.isEmpty) return;
    try {
      await storage.createFolder(value);
      await _load();
      await widget.session.refreshGitIndicators();
    } catch (e) {
      setState(() => feedback = '$e');
    }
  }

  Future<void> _duplicate(String path) async {
    try {
      final entry = await storage.duplicate(path);
      await _load(entry.path);
      await widget.session.refreshGitIndicators();
      if (mounted) setState(() => feedback = 'Duplicated as ${entry.path}');
    } catch (e) {
      if (mounted) setState(() => feedback = '$e');
    }
  }

  Future<void> _entryMenu(RequestEntry entry, Offset position) async {
    if (entry.directory || !entry.valid) return;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: const [
        PopupMenuItem(
          value: 'duplicate',
          child: ListTile(
            leading: Icon(Icons.copy_outlined),
            title: Text('Duplicate request'),
          ),
        ),
      ],
    );
    if (action == 'duplicate') await _duplicate(entry.path);
  }

  Future<void> _rename() async {
    if (activePath == null) {
      setState(() => feedback = 'Create or select a request first.');
      return;
    }
    final value = await _ask('Rename Request', initial: name.text);
    if (value == null || value.isEmpty) return;
    try {
      final entry = await storage.rename(activePath!, value);
      dirty = false;
      await _load(entry.path);
    } catch (e) {
      setState(() => feedback = '$e');
    }
  }

  Future<void> _move() async {
    if (activePath == null) {
      setState(() => feedback = 'Create or select a request first.');
      return;
    }
    final value = await _ask('Move to folder', initial: '');
    if (value == null) return;
    try {
      final entry = await storage.move(activePath!, value);
      dirty = false;
      await _load(entry.path);
    } catch (e) {
      setState(() => feedback = '$e');
    }
  }

  Future<void> _delete() async {
    if (activePath == null) {
      setState(() => feedback = 'Create or select a request first.');
      return;
    }
    final yes =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text('Delete ${name.text}?'),
            content: const Text('Attached Markdown files will be kept.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!yes) return;
    try {
      await storage.delete(activePath!);
      activePath = null;
      compactEditorVisible = false;
      dirty = false;
      await _load();
    } catch (e) {
      setState(() => feedback = '$e');
    }
  }

  Future<RequestExecutionContext> _context() async {
    final env = await storage.loadEnvironment();
    return RequestExecutionContext(
      projectVariables: env.project.variables,
      secretVariables: env.local.variables,
      projectAuth: RequestEnvironment(
        variables: env.project.variables,
        authType: env.project.authType,
        authToken: env.project.authToken,
      ),
    );
  }

  Future<void> _run(List<String> paths) async {
    if (busy) return;
    if (paths.isEmpty) {
      setState(() => feedback = 'Select at least one request to run.');
      return;
    }
    setState(() {
      busy = true;
      results = const [];
      feedback = 'Running ${paths.length} request(s)…';
    });
    final executor = RequestExecutor();
    try {
      final items = <({String id, HttpRequestFile request})>[];
      for (final path in paths) {
        items.add((
          id: path,
          request: path == activePath && dirty
              ? _draft()
              : await storage.read(path),
        ));
      }
      final batch = await executor.executeMany(
        items,
        await _context(),
        BatchExecutionOptions(parallel: parallel, stopOnError: stopOnError),
      );
      for (final result in batch.results) {
        widget.session.log(
          '[HTTP] ${result.method} ${result.name} → ${result.statusCode ?? 'error'} · ${result.duration.inMilliseconds} ms',
          error: !result.success,
        );
      }
      if (mounted) {
        setState(() {
          results = batch.results;
          feedback =
              'Completed: ${batch.completed} · Failed: ${batch.failed} · Total: ${batch.results.length}';
        });
      }
    } catch (error) {
      if (mounted) setState(() => feedback = '$error');
    } finally {
      executor.close();
      if (mounted) setState(() => busy = false);
    }
  }

  String _responseBody(RequestExecutionResult result) {
    final body = result.responseBody;
    final contentType = result.responseHeaders.entries
        .where((entry) => entry.key.toLowerCase() == 'content-type')
        .map((entry) => entry.value.toLowerCase())
        .firstOrNull;
    if (contentType?.contains('json') == true ||
        body.trimLeft().startsWith('{') ||
        body.trimLeft().startsWith('[')) {
      try {
        return const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
      } catch (_) {}
    }
    return body;
  }

  Future<void> _showResponse(RequestExecutionResult result) async {
    final body = result.error.isNotEmpty ? result.error : _responseBody(result);
    final headers = result.responseHeaders.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n');
    await showDialog<void>(
      context: context,
      builder: (context) => DefaultTabController(
        length: 2,
        child: AlertDialog(
          title: Text(
            '${result.method} ${result.name} · ${result.statusCode ?? 'Error'}',
          ),
          content: SizedBox(
            width: 900,
            height: 620,
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${result.duration.inMilliseconds} ms${result.startedAt == null ? '' : ' · ${result.startedAt!.toLocal()}'}',
                  ),
                ),
                const TabBar(
                  tabs: [
                    Tab(text: 'Body'),
                    Tab(text: 'Headers'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      SingleChildScrollView(
                        padding: const EdgeInsets.only(top: 12),
                        child: SelectableText(
                          body,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                      SingleChildScrollView(
                        padding: const EdgeInsets.only(top: 12),
                        child: SelectableText(
                          headers.isEmpty ? 'No response headers.' : headers,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: body)),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Copy body'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _environment() async {
    final env = await storage.loadEnvironment();
    if (!mounted) return;
    final project = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(env.project.variables),
    );
    final secrets = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(env.local.variables),
    );
    final token = TextEditingController(text: env.project.authToken);
    var auth = env.project.authType;
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Requests Settings'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  TextField(
                    controller: project,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: 'Shared variables (.tamtoot/environment.json)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: secrets,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText:
                          'Local secret variables (environment.local.json)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: auth,
                    items: const [
                      DropdownMenuItem(
                        value: 'none',
                        child: Text('No project authorization'),
                      ),
                      DropdownMenuItem(
                        value: 'bearer',
                        child: Text('Bearer token'),
                      ),
                    ],
                    onChanged: (v) => update(() => auth = v ?? 'none'),
                  ),
                  if (auth == 'bearer')
                    TextField(
                      controller: token,
                      decoration: const InputDecoration(
                        labelText: 'Shared token reference',
                        hintText: '{{token}}',
                        helperText:
                            'A literal token is moved to the local secret variables automatically.',
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (save == true) {
      try {
        Map<String, String> decode(TextEditingController c) =>
            (jsonDecode(c.text) as Map).map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            );
        final localVariables = decode(secrets);
        var sharedToken = token.text.trim();
        if (auth == 'bearer' &&
            sharedToken.isNotEmpty &&
            !VariableResolver.isVariableReference(sharedToken)) {
          localVariables['token'] = sharedToken;
          sharedToken = '{{token}}';
        }
        await storage.saveProjectEnvironment(
          RequestEnvironment(
            variables: decode(project),
            authType: auth,
            authToken: sharedToken,
          ),
        );
        await storage.saveLocalEnvironment(
          RequestEnvironment(variables: localVariables),
        );
        setState(() => feedback = 'Request environments saved.');
        await widget.session.refreshGitIndicators();
      } catch (e) {
        setState(() => feedback = '$e');
      }
    }
    project.dispose();
    secrets.dispose();
    token.dispose();
  }

  Future<void> _newDocumentation() async {
    if (activePath == null) return;
    final filename =
        '${activePath!.split('/').last.replaceAll(RegExp(r'\.json$'), '')}.md';
    try {
      await storage.saveMarkdown(
        activePath!,
        filename,
        '# ${name.text}\n\n## Description\n\n## Request\n\n## Response\n\n## Notes\n',
        overwrite: false,
      );
      attachments = [
        ...attachments,
        RequestAttachment(type: 'markdown', path: filename),
      ];
      dirty = true;
      await _save();
      await _editMarkdown(filename);
    } catch (e) {
      setState(() => feedback = '$e');
    }
  }

  Future<void> _attachDocumentation() async {
    if (activePath == null) return;
    final filename = await _ask(
      'Attach Markdown beside request',
      initial: 'README.md',
    );
    if (filename == null || filename.isEmpty) return;
    try {
      await storage.readMarkdown(activePath!, filename);
      if (attachments.any((item) => item.path == filename)) return;
      setState(() {
        attachments = [
          ...attachments,
          RequestAttachment(type: 'markdown', path: filename),
        ];
        dirty = true;
      });
    } catch (e) {
      setState(() => feedback = '$e');
    }
  }

  Future<void> _editMarkdown(String path) async {
    if (activePath == null) return;
    try {
      final editor = TextEditingController(
        text: await storage.readMarkdown(activePath!, path),
      );
      if (!mounted) {
        editor.dispose();
        return;
      }
      final save = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(path),
          content: SizedBox(
            width: 700,
            height: 500,
            child: TextField(
              controller: editor,
              expands: true,
              maxLines: null,
              minLines: null,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(alignLabelWithHint: true),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save Markdown'),
            ),
          ],
        ),
      );
      if (save == true) {
        await storage.saveMarkdown(activePath!, path, editor.text);
      }
      editor.dispose();
    } catch (e) {
      setState(() => feedback = '$e');
    }
  }

  Widget _kv(String title, List<_KvDraft> items) => ExpansionTile(
    title: Text(title),
    initiallyExpanded: title == 'Headers',
    children: [
      for (final item in items)
        Row(
          children: [
            Checkbox(
              value: item.enabled,
              onChanged: (v) => setState(() {
                item.enabled = v ?? true;
                dirty = true;
              }),
            ),
            Expanded(
              child: TextField(
                controller: item.key,
                onChanged: (_) => _changed(),
                decoration: const InputDecoration(hintText: 'Key'),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: item.valueController,
                onChanged: (_) => _changed(),
                decoration: const InputDecoration(hintText: 'Value'),
              ),
            ),
            IconButton(
              onPressed: () => setState(() {
                items.remove(item);
                item.dispose();
                dirty = true;
              }),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() {
            items.add(_KvDraft());
            dirty = true;
          }),
          icon: const Icon(Icons.add),
          label: Text('Add $title'),
        ),
      ),
    ],
  );

  Widget _editor() {
    if (activePath == null) {
      return const Center(child: Text('Select or create a request.'));
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            SizedBox(
              width: 115,
              child: DropdownButtonFormField<String>(
                key: ValueKey('method-$activePath-$method'),
                initialValue: method,
                items: [
                  for (final value in httpMethods)
                    DropdownMenuItem(value: value, child: Text(value)),
                ],
                onChanged: (v) => setState(() {
                  method = v!;
                  dirty = true;
                }),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: url,
                onChanged: (_) => _changed(),
                decoration: const InputDecoration(labelText: 'URL'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: busy ? null : () => _run([activePath!]),
              icon: const Icon(Icons.send),
              label: const Text('Send'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: name,
          onChanged: (_) => _changed(),
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        _kv('Params', query),
        _kv('Headers', headers),
        ExpansionTile(
          title: const Text('Authorization'),
          children: [
            DropdownButtonFormField<String>(
              key: ValueKey('auth-$activePath-$authMode'),
              initialValue: authMode,
              items: const [
                DropdownMenuItem(
                  value: 'inherit',
                  child: Text('Inherit project authorization'),
                ),
                DropdownMenuItem(
                  value: 'none',
                  child: Text('No authorization'),
                ),
                DropdownMenuItem(
                  value: 'bearer',
                  child: Text('Bearer override'),
                ),
              ],
              onChanged: (v) => setState(() {
                authMode = v!;
                dirty = true;
              }),
            ),
            if (authMode == 'bearer')
              TextFormField(
                key: ValueKey('token-$activePath-$authToken'),
                initialValue: authToken,
                obscureText: true,
                onChanged: (v) {
                  authToken = v;
                  _changed();
                },
                decoration: const InputDecoration(
                  labelText: 'Token or {{variable}}',
                ),
              ),
          ],
        ),
        ExpansionTile(
          title: const Text('Body'),
          children: [
            DropdownButtonFormField<String>(
              key: ValueKey('body-$activePath-$bodyType'),
              initialValue: bodyType,
              items: [
                for (final value in requestBodyTypes)
                  DropdownMenuItem(value: value, child: Text(value)),
              ],
              onChanged: (v) => setState(() {
                bodyType = v!;
                dirty = true;
              }),
            ),
            if (bodyType != 'none')
              TextField(
                controller: body,
                minLines: 5,
                maxLines: 14,
                onChanged: (_) => _changed(),
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: InputDecoration(
                  hintText: bodyType == 'form'
                      ? 'key=value, one per line'
                      : null,
                ),
              ),
          ],
        ),
        ExpansionTile(
          title: const Text('Documentation'),
          children: [
            for (final attachment in attachments)
              ListTile(
                title: Text(attachment.path),
                leading: const Icon(Icons.description_outlined),
                onTap: () => _editMarkdown(attachment.path),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                children: [
                  TextButton.icon(
                    onPressed: _newDocumentation,
                    icon: const Icon(Icons.note_add_outlined),
                    label: const Text('New Documentation'),
                  ),
                  TextButton.icon(
                    onPressed: _attachDocumentation,
                    icon: const Icon(Icons.attach_file),
                    label: const Text('Attach Markdown'),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (results.isNotEmpty) ...[
          const Divider(),
          Text(
            'Run: ${results.length} requests',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final result in results)
            ListTile(
              dense: true,
              leading: Icon(
                result.success ? Icons.check_circle : Icons.cancel,
                color: result.success
                    ? Colors.green
                    : Theme.of(context).colorScheme.error,
              ),
              title: Text('${result.method}  ${result.name}'),
              subtitle: Text(
                result.error.isNotEmpty ? result.error : result.responseBody,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                '${result.statusCode ?? '-'}  ${result.duration.inMilliseconds} ms',
              ),
              onTap: () => _showResponse(result),
            ),
        ],
      ],
    );
  }

  Widget _requestList() => Column(
    children: [
      Row(
        children: [
          TextButton(
            onPressed: () => setState(
              () => selected.addAll(
                entries
                    .where((entry) => entry.valid && !entry.directory)
                    .map((entry) => entry.path),
              ),
            ),
            child: const Text('Select All'),
          ),
          TextButton(
            onPressed: () => setState(selected.clear),
            child: const Text('Clear'),
          ),
        ],
      ),
      Expanded(
        child: ListView.builder(
          itemCount: entries.length,
          itemBuilder: (_, index) {
            final entry = entries[index];
            if (entry.directory) {
              return ListTile(
                dense: true,
                leading: const Icon(Icons.folder_outlined, size: 18),
                title: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  entry.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }
            return GestureDetector(
              onSecondaryTapDown: (event) =>
                  _entryMenu(entry, event.globalPosition),
              onLongPressStart: (event) =>
                  _entryMenu(entry, event.globalPosition),
              child: CheckboxListTile(
                dense: true,
                value: selected.contains(entry.path),
                onChanged: entry.valid
                    ? (value) => setState(() {
                        if (value == true) {
                          selected.add(entry.path);
                        } else {
                          selected.remove(entry.path);
                        }
                      })
                    : null,
                secondary: Text(
                  entry.method,
                  style: TextStyle(
                    fontSize: 9,
                    color: entry.valid
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
                title: InkWell(
                  onTap: entry.valid ? () => _open(entry.path) : null,
                  child: Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                subtitle: Text(
                  entry.error ?? entry.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: activePath == entry.path,
              ),
            );
          },
        ),
      ),
    ],
  );

  Widget _requestsWorkspace(BoxConstraints constraints) {
    if (constraints.maxWidth >= 720) {
      return Row(
        children: [
          SizedBox(width: 290, child: _requestList()),
          const VerticalDivider(width: 1),
          Expanded(child: _editor()),
        ],
      );
    }

    if (!compactEditorVisible || activePath == null) {
      return _requestList();
    }
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => compactEditorVisible = false),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Requests'),
          ),
        ),
        Expanded(child: _editor()),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = (size.width - 24).clamp(280.0, 1050.0);
    final dialogHeight = (size.height - 48).clamp(320.0, 680.0);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
      },
      child: Focus(
        autofocus: true,
        child: AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 24,
          ),
          title: Row(
            children: [
              const Expanded(child: Text('HTTP Requests')),
              if (dirty)
                const Text('● Unsaved', style: TextStyle(fontSize: 12)),
              IconButton(
                onPressed: _environment,
                tooltip: 'Requests settings',
                icon: const Icon(Icons.settings_outlined),
              ),
              IconButton(
                onPressed: () async {
                  if (await _confirmLose() && context.mounted) {
                    Navigator.pop(context);
                  }
                },
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          content: SizedBox(
            width: dialogWidth,
            height: dialogHeight,
            child: Column(
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _newRequest,
                      icon: const Icon(Icons.add),
                      label: const Text('New Request'),
                    ),
                    TextButton.icon(
                      onPressed: _newFolder,
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('New Folder'),
                    ),
                    TextButton(
                      onPressed: busy ? null : _rename,
                      child: const Text('Rename'),
                    ),
                    TextButton(
                      onPressed: busy ? null : _move,
                      child: const Text('Move'),
                    ),
                    TextButton(
                      onPressed: busy ? null : _delete,
                      child: const Text('Delete'),
                    ),
                    FilledButton.icon(
                      onPressed: busy ? null : _save,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: busy
                          ? null
                          : () => _run(
                              entries
                                  .where(
                                    (entry) =>
                                        selected.contains(entry.path) &&
                                        entry.valid &&
                                        !entry.directory,
                                  )
                                  .map((entry) => entry.path)
                                  .toList(),
                            ),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Run Selected'),
                    ),
                    FilterChip(
                      label: const Text('Parallel (5)'),
                      selected: parallel,
                      onSelected: (v) => setState(() => parallel = v),
                    ),
                    FilterChip(
                      label: const Text('Stop on error'),
                      selected: stopOnError,
                      onSelected: (v) => setState(() => stopOnError = v),
                    ),
                  ],
                ),
                if (feedback != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        feedback!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                const Divider(height: 1),
                Expanded(
                  child: LayoutBuilder(
                    builder: (_, constraints) {
                      return _requestsWorkspace(constraints);
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (await _confirmLose() && context.mounted) {
                  Navigator.pop(context);
                }
              },
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}

class _KvDraft {
  _KvDraft({String key = '', String value = '', this.enabled = true})
    : key = TextEditingController(text: key),
      valueController = TextEditingController(text: value);
  factory _KvDraft.from(RequestKeyValue value) =>
      _KvDraft(key: value.key, value: value.value, enabled: value.enabled);
  final TextEditingController key, valueController;
  bool enabled;
  RequestKeyValue get value => RequestKeyValue(
    key: key.text,
    value: valueController.text,
    enabled: enabled,
  );
  void dispose() {
    key.dispose();
    valueController.dispose();
  }
}
