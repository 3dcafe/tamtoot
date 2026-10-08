import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/sftp/sftp_client.dart';
import '../core/ssh/ssh_client.dart';
import '../core/ssh/ssh_error.dart';
import '../core/ssh/transport/ssh_transport.dart';
import '../platform/sftp_files.dart';

class SftpBrowserView extends StatefulWidget {
  const SftpBrowserView({
    super.key,
    required this.client,
    required this.title,
    this.pickFile,
    this.saveFile,
  });
  final SshClient client;
  final String title;
  final Future<SftpLocalFile?> Function()? pickFile;
  final Future<bool> Function(String, Uint8List)? saveFile;
  @override
  State<SftpBrowserView> createState() => _SftpBrowserViewState();
}

class _SftpBrowserViewState extends State<SftpBrowserView>
    with WidgetsBindingObserver {
  SftpClient? _sftp;
  StreamSubscription<String>? _errors;
  String _path = '.', _message = 'Opening SFTP…';
  List<SftpEntry> _entries = [];
  bool _busy = true, _picking = false, _prompting = false;
  int _done = 0;
  int? _total;
  SshCancellation? _transfer;
  final _pathInput = TextEditingController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connect();
  }

  Future<void> _connect() async {
    await _errors?.cancel();
    await _sftp?.close();
    if (!mounted) return;
    setState(() {
      _busy = true;
      _message = 'Opening SFTP…';
    });
    try {
      final sftp = await SftpClient.connect(widget.client);
      if (!mounted) {
        await sftp.close();
        return;
      }
      _sftp = sftp;
      _errors = sftp.errors.listen((message) {
        if (mounted) setState(() => _message = message);
      });
      _path = await sftp.realpath('.');
      await _load(_path);
    } catch (e) {
      if (mounted) setState(() => _message = _error(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _error(Object e) => e is SftpConflict && e.recoveryPath != null
      ? '${e.message}\nRecovery copy: ${e.recoveryPath}'
      : e is SshException
      ? e.message
      : e is FormatException
      ? e.message
      : 'File operation failed.';
  Future<void> _load(String path) async {
    final sftp = _sftp!;
    final canonical = await sftp.realpath(path),
        entries = await sftp.list(canonical);
    entries.sort((a, b) {
      final directory =
          (b.attributes.directory ? 1 : 0) - (a.attributes.directory ? 1 : 0);
      return directory != 0 ? directory : a.name.compareTo(b.name);
    });
    if (mounted) {
      setState(() {
        _path = canonical;
        _pathInput.text = canonical;
        _entries = entries;
      });
    }
  }

  Future<void> _operation(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = 'Working…';
      _done = 0;
      _total = null;
    });
    try {
      final message = await action();
      if (mounted) setState(() => _message = message ?? 'Ready');
    } catch (e) {
      if (mounted) setState(() => _message = _error(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _transfer = null;
        });
      }
    }
  }

  void _progress(int done, int? total) {
    if (mounted) {
      setState(() {
        _done = done;
        _total = total;
      });
    }
  }

  Future<String?> _name(String title, {String initial = ''}) async {
    setState(() => _prompting = true);
    final controller = TextEditingController(text: initial);
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Remote name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
      if (mounted) setState(() => _prompting = false);
    }
  }

  Future<bool> _confirm(String title, String body) async {
    setState(() => _prompting = true);
    try {
      return await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(title),
              content: Text(body),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Confirm'),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      if (mounted) setState(() => _prompting = false);
    }
  }

  Future<void> _upload() => _operation(() async {
    _picking = true;
    SftpLocalFile? local;
    try {
      local = await (widget.pickFile ?? pickSftpFile)();
    } finally {
      _picking = false;
    }
    if (local == null || !mounted) return 'Upload cancelled';
    final name = await _name('Upload to remote directory', initial: local.name);
    if (name == null || !mounted) return 'Upload cancelled';
    final path = SftpClient.join(_path, name), sftp = _sftp!;
    SftpSnapshot? expected;
    final existing = await sftp.tryStat(path);
    if (existing != null) {
      if (!existing.regular) {
        throw const SftpException(
          'A directory or symbolic link cannot be replaced.',
        );
      }
      if (!mounted ||
          !await _confirm(
            'Replace remote file?',
            '$path\nThe previous version will remain as a recovery copy.',
          )) {
        return 'Upload cancelled';
      }
      expected = await sftp.snapshot(path, maxBytes: SftpClient.maxFileBytes);
    }
    _transfer = SshCancellation();
    final commit = await sftp.writeFile(
      path,
      local.bytes,
      expected: expected,
      cancellation: _transfer,
      progress: _progress,
    );
    await _load(_path);
    return commit.backupPath == null
        ? 'Upload complete'
        : 'Upload complete. Recovery copy: ${commit.backupPath}';
  });
  Future<void> _download(SftpEntry entry) => _operation(() async {
    final path = SftpClient.join(_path, entry.name);
    _transfer = SshCancellation();
    final bytes = await _sftp!.readFile(
      path,
      cancellation: _transfer,
      progress: _progress,
    );
    if (!mounted) return null;
    _picking = true;
    try {
      final saved = await (widget.saveFile ?? saveSftpFile)(entry.name, bytes);
      return saved
          ? 'Download saved'
          : 'Save cancelled; downloaded data was not exported';
    } finally {
      _picking = false;
    }
  });
  Future<void> _edit(SftpEntry entry) => _operation(() async {
    final path = SftpClient.join(_path, entry.name),
        snapshot = await _sftp!.snapshot(path);
    final text = utf8.decode(snapshot.bytes);
    if (text.contains('\x00')) {
      throw const SftpException('Binary files cannot be edited as text.');
    }
    if (!mounted) return null;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            _SftpEditor(sftp: _sftp!, snapshot: snapshot, initial: text),
      ),
    );
    if (mounted) await _load(_path);
    return 'Ready';
  });
  Future<void> _entry(SftpEntry entry) async {
    if (entry.attributes.directory) {
      await _operation(() async {
        await _load(SftpClient.join(_path, entry.name));
        return null;
      });
      return;
    }
    if (entry.attributes.symlink) {
      await _operation(() async {
        final path = SftpClient.join(_path, entry.name),
            target = await _sftp!.readlink(path);
        if (!mounted) return null;
        if (!await _confirm('Open symbolic link?', '$path → $target')) {
          return 'Link left unchanged';
        }
        final attrs = await _sftp!.stat(path, followLinks: true);
        if (attrs.directory) {
          await _load(path);
          return null;
        }
        return 'Link target: $target. Use Download to read it. Editing links is disabled.';
      });
      return;
    }
    await _edit(entry);
  }

  Future<void> _rename(SftpEntry entry) => _operation(() async {
    final name = await _name('Rename remote entry', initial: entry.name);
    if (name == null || !mounted) return 'Rename cancelled';
    final from = SftpClient.join(_path, entry.name),
        to = SftpClient.join(_path, name);
    if (from == to) return 'Name unchanged';
    if (!await _confirm('Rename remote entry?', '$from\n→ $to')) {
      return 'Rename cancelled';
    }
    if (await _sftp!.tryStat(to) != null) {
      throw const SftpConflict(
        'Destination exists; rename will not overwrite it.',
      );
    }
    await _sftp!.rename(from, to);
    await _load(_path);
    return 'Renamed';
  });
  Future<void> _delete(SftpEntry entry) => _operation(() async {
    final path = SftpClient.join(_path, entry.name);
    if (!await _confirm(
      'Delete remote entry?',
      entry.attributes.symlink
          ? 'Delete symbolic link $path? Its target is kept.'
          : 'Delete $path? Directories must be empty.',
    )) {
      return 'Deletion cancelled';
    }
    await _sftp!.remove(
      path,
      directory: entry.attributes.directory && !entry.attributes.symlink,
    );
    await _load(_path);
    return 'Deleted';
  });
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_picking &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS) &&
        state == AppLifecycleState.paused) {
      _transfer?.cancel();
      unawaited(widget.client.close());
      if (mounted) {
        setState(
          () => _message =
              'SSH disconnected in background. Reconnect explicitly.',
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _transfer?.cancel();
    unawaited(_errors?.cancel());
    unawaited(_sftp?.close());
    _pathInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${widget.title} · SFTP'),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: _busy
              ? null
              : () => _sftp?.closed == false
                    ? _operation(() async {
                        await _load(_path);
                        return null;
                      })
                    : _connect(),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            controller: _pathInput,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Remote path'),
            onSubmitted: (path) => _operation(() async {
              await _load(path);
              return null;
            }),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => _operation(() async {
                      await _load(SftpClient.parent(_path));
                      return null;
                    }),
              icon: const Icon(Icons.arrow_upward),
              label: const Text('Parent'),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _upload,
              icon: const Icon(Icons.upload),
              label: const Text('Upload'),
            ),
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => _operation(() async {
                      final name = await _name('Create remote directory');
                      if (name == null) return 'Creation cancelled';
                      await _sftp!.mkdir(SftpClient.join(_path, name));
                      await _load(_path);
                      return 'Directory created';
                    }),
              icon: const Icon(Icons.create_new_folder),
              label: const Text('New folder'),
            ),
          ],
        ),
        if (_busy && !_prompting)
          LinearProgressIndicator(
            value: _total == null || _total == 0
                ? null
                : (_done / _total!).clamp(0, 1),
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: SelectableText(_message, key: const Key('sftp-status')),
        ),
        if (_transfer != null && _busy)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('$_done / ${_total ?? '?'} bytes'),
              TextButton(
                onPressed: () => _transfer?.cancel(),
                child: const Text('Cancel transfer'),
              ),
            ],
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _entries.length,
            itemBuilder: (context, index) {
              final entry = _entries[index];
              return ListTile(
                leading: Icon(
                  entry.attributes.symlink
                      ? Icons.link
                      : entry.attributes.directory
                      ? Icons.folder
                      : Icons.insert_drive_file,
                ),
                title: Text(entry.name),
                subtitle: Text(
                  '${entry.attributes.symlink
                      ? 'Symbolic link'
                      : entry.attributes.directory
                      ? 'Directory'
                      : 'File'} · ${entry.attributes.size ?? '?'} bytes · mode ${entry.attributes.permissions == null ? '?' : (entry.attributes.permissions! & 0xfff).toRadixString(8)}',
                ),
                onTap: _busy ? null : () => _entry(entry),
                trailing: PopupMenuButton<String>(
                  enabled: !_busy,
                  onSelected: (action) {
                    switch (action) {
                      case 'download':
                        _download(entry);
                      case 'edit':
                        _edit(entry);
                      case 'rename':
                        _rename(entry);
                      case 'delete':
                        _delete(entry);
                    }
                  },
                  itemBuilder: (_) => [
                    if (!entry.attributes.directory)
                      const PopupMenuItem(
                        value: 'download',
                        child: Text('Download'),
                      ),
                    if (entry.attributes.regular)
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Edit text'),
                      ),
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}

class _SftpEditor extends StatefulWidget {
  const _SftpEditor({
    required this.sftp,
    required this.snapshot,
    required this.initial,
  });
  final SftpClient sftp;
  final SftpSnapshot snapshot;
  final String initial;
  @override
  State<_SftpEditor> createState() => _SftpEditorState();
}

class _SftpEditorState extends State<_SftpEditor> {
  late final TextEditingController _text;
  late SftpSnapshot _snapshot;
  late String _baseline;
  String _status =
      'Changes are checked against the remote version before saving.';
  bool _saving = false, _dirty = false;
  @override
  void initState() {
    super.initState();
    _snapshot = widget.snapshot;
    _baseline = widget.initial;
    _text = TextEditingController(text: widget.initial)
      ..addListener(() => setState(() => _dirty = _text.text != _baseline));
  }

  Future<void> _save() async {
    final bytes = utf8.encode(_text.text);
    if (bytes.length > 2 * 1024 * 1024) {
      setState(() => _status = 'Text exceeds 2 MiB.');
      return;
    }
    setState(() => _saving = true);
    try {
      final commit = await widget.sftp.writeFile(
        _snapshot.path,
        bytes,
        expected: _snapshot,
      );
      _snapshot = await widget.sftp.snapshot(_snapshot.path);
      if (mounted) {
        setState(() {
          _baseline = _text.text;
          _dirty = false;
          _status = 'Saved. Recovery copy: ${commit.backupPath}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _status = e is SshException ? e.message : 'Save failed.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reload() async {
    if (_dirty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reload and discard local edits?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reload'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _saving = true);
    try {
      final snapshot = await widget.sftp.snapshot(_snapshot.path);
      final text = utf8.decode(snapshot.bytes);
      if (text.contains('\x00')) {
        throw const SftpException('Remote file is binary.');
      }
      if (mounted) {
        setState(() {
          _snapshot = snapshot;
          _baseline = text;
          _text.text = text;
          _dirty = false;
          _status = 'Remote version reloaded.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _status = e is SshException ? e.message : 'Reload failed.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _discard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => _dirty = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_dirty && !_saving,
    onPopInvokedWithResult: (popped, _) {
      if (!popped && !_saving) _discard();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(SftpClient.basename(_snapshot.path)),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save remote'),
          ),
          IconButton(
            tooltip: 'Reload remote file',
            onPressed: _saving ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_saving) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(8),
            child: SelectableText(_status),
          ),
          Expanded(
            child: TextField(
              controller: _text,
              enabled: !_saving,
              expands: true,
              maxLines: null,
              minLines: null,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ),
        ],
      ),
    ),
  );
}
