import 'package:flutter/material.dart';

import '../app/ide_session.dart';
import '../core/opencode/engine.dart';

/// Project "task board": in the opencode world a task is an agent session.
/// Lists the project's agent sessions and lets the user prune them.
class KanbanDialog extends StatefulWidget {
  const KanbanDialog({super.key, required this.session});

  final IdeSession session;

  @override
  State<KanbanDialog> createState() => _KanbanDialogState();
}

class _KanbanDialogState extends State<KanbanDialog> {
  OpencodeEngine? _api;
  List<Map<String, dynamic>> _sessions = const [];
  String? _error;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final root = widget.session.workspaceRoot;
      if (root == null) {
        throw const OpencodeException('Open a project folder first.');
      }
      _api = OpencodeEngine.forProject(root.toFilePath());
      final sessions = await _api!.sessions();
      if (mounted) setState(() => _sessions = sessions);
    } on OpencodeException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _delete(String id) async {
    await _api?.deleteSession(id);
    await _load();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Agent sessions'),
    content: SizedBox(
      width: 520,
      height: 420,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: SelectableText(_error!))
          : _sessions.isEmpty
          ? const Center(
              child: Text(
                'No agent sessions yet. Start one from the Agent sidebar.',
              ),
            )
          : ListView(
              children: [
                for (final s in _sessions)
                  ListTile(
                    leading: const Icon(Icons.forum_outlined),
                    title: Text('${s['title'] ?? s['id']}'),
                    subtitle: Text('${s['id']}'),
                    trailing: IconButton(
                      tooltip: 'Delete session',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _delete(s['id'] as String),
                    ),
                  ),
              ],
            ),
    ),
    actions: [
      TextButton(
        onPressed: _loading ? null : _load,
        child: const Text('Refresh'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
