import 'package:flutter/material.dart';

import '../app/ide_session.dart';
import '../core/opencode/engine.dart';

/// MCP server status. MCP is not yet ported to the built-in engine, so the
/// dialog reports an empty status instead of querying an external server.
class McpDialog extends StatefulWidget {
  const McpDialog({super.key, required this.session});

  final IdeSession session;

  @override
  State<McpDialog> createState() => _McpDialogState();
}

class _McpDialogState extends State<McpDialog> {
  Map<String, dynamic> _status = const {};
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
      final status =
          await OpencodeEngine.forProject(root.toFilePath()).mcpStatus();
      if (mounted) setState(() => _status = status);
    } on OpencodeException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: SelectableText(_error!),
      );
    }
    if (_status.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'MCP servers are not yet supported by the built-in agent engine.',
        ),
      );
    }
    return ListView(
      shrinkWrap: true,
      children: [
        for (final entry in _status.entries)
          ListTile(
            dense: true,
            leading: Icon(
              _connected(entry.value)
                  ? Icons.check_circle_outline
                  : Icons.error_outline,
            ),
            title: Text(entry.key),
            subtitle: Text(_describe(entry.value)),
          ),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'MCP servers are managed by the opencode server configuration '
            '(opencode.json).',
          ),
        ),
      ],
    );
  }

  bool _connected(dynamic value) =>
      value is Map && '${value['status']}' == 'connected';

  String _describe(dynamic value) {
    if (value is Map) {
      final status = '${value['status'] ?? 'unknown'}';
      final error = value['error'];
      return error == null ? status : '$status: $error';
    }
    return '$value';
  }
}
