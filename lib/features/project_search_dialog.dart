import 'dart:async';
import 'package:flutter/material.dart';
import '../app/ide_session.dart';
import '../core/filesystem/filesystem.dart';

class ProjectSearchDialog extends StatefulWidget {
  const ProjectSearchDialog({super.key, required this.session});
  final IdeSession session;
  @override
  State<ProjectSearchDialog> createState() => _ProjectSearchDialogState();
}

class _ProjectSearchDialogState extends State<ProjectSearchDialog> {
  final _query = TextEditingController();
  final _hits = <({FileEntry file, int line, String preview, int offset})>[];
  Timer? _timer;
  int _generation = 0, _skipped = 0;
  bool _busy = false, _caseSensitive = false;

  void _schedule() {
    _timer?.cancel();
    final generation = ++_generation;
    setState(() {
      _hits.clear();
      _busy = _query.text.isNotEmpty;
      _skipped = 0;
    });
    _timer = Timer(
      const Duration(milliseconds: 300),
      () => _search(generation),
    );
  }

  Future<void> _search(int generation) async {
    final root = widget.session.workspaceRoot;
    final query = _query.text;
    if (root == null || query.isEmpty) return;
    final pattern = RegExp(RegExp.escape(query), caseSensitive: _caseSensitive);
    final pending = <Uri>[root], seen = <Uri>{};
    bool active() => mounted && generation == _generation;
    while (pending.isNotEmpty && active() && _hits.length < 500) {
      final directory = pending.removeLast();
      if (!seen.add(directory)) continue;
      List<FileEntry> entries;
      try {
        entries = await widget.session.documents.files.list(directory);
      } catch (_) {
        _skipped++;
        continue;
      }
      for (final entry in entries) {
        if (!active() || _hits.length >= 500) break;
        if (entry.directory) {
          if (!{
            '.git',
            '.tamtoot',
            '.dart_tool',
            'build',
            'node_modules',
            'obj',
          }.contains(entry.name)) {
            pending.add(entry.uri);
          }
          continue;
        }
        if (!seen.add(entry.uri)) continue;
        try {
          final open = widget.session.documents.documents
              .where((d) => d.uri == entry.uri)
              .firstOrNull;
          final text =
              (open?.editor.text ??
                      await widget.session.documents.files.read(entry.uri))
                  .replaceAll('\r\n', '\n');
          if (!active()) return;
          if (text.length > 2000000 || text.contains('\u0000')) {
            _skipped++;
            continue;
          }
          var line = 1, scanned = 0;
          for (final match in pattern.allMatches(text)) {
            while (scanned < match.start) {
              if (text.codeUnitAt(scanned++) == 10) line++;
            }
            final start = match.start == 0
                ? 0
                : text.lastIndexOf('\n', match.start - 1) + 1;
            final end = text.indexOf('\n', match.start);
            final stop = end < 0 ? text.length : end;
            _hits.add((
              file: entry,
              line: line,
              preview: text.substring(
                start,
                stop > start + 180 ? start + 180 : stop,
              ),
              offset: match.start,
            ));
            if (_hits.length >= 500) break;
          }
        } catch (_) {
          _skipped++;
        }
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (active()) setState(() => _busy = false);
  }

  Future<void> _open(int index) async {
    final hit = _hits[index];
    try {
      await widget.session.run('file.openEntry', hit.file);
      final doc = widget.session.documents.active;
      if (doc?.uri != hit.file.uri) return;
      final offset = hit.offset.clamp(0, doc!.editor.text.length);
      await widget.session.run('editor.select', [
        offset,
        (offset + _query.text.length).clamp(0, doc.editor.text.length),
      ]);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open this file.')),
        );
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Find in project'),
    content: SizedBox(
      width: 720,
      height: 460,
      child: Column(
        children: [
          TextField(
            controller: _query,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Search text',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (_) => _schedule(),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Match case'),
            value: _caseSensitive,
            onChanged: (value) {
              _caseSensitive = value!;
              _schedule();
            },
          ),
          if (_busy) const LinearProgressIndicator(),
          Text(
            _busy
                ? 'Searching…'
                : '${_hits.length}${_hits.length == 500 ? "+ (limit reached)" : ""} matches · $_skipped files/folders skipped',
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _hits.length,
              itemBuilder: (_, index) {
                final hit = _hits[index];
                final root = widget.session.workspaceRoot.toString();
                final path = hit.file.uri.toString();
                return ListTile(
                  dense: true,
                  title: Text(
                    '${Uri.decodeFull(path.startsWith(root) ? path.substring(root.length) : path)}:${hit.line}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    hit.preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _open(index),
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
