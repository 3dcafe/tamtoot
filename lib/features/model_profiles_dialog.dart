import 'package:flutter/material.dart';

import '../app/ide_session.dart';
import '../core/opencode/engine.dart';

/// Provider/model overview from the built-in engine. Providers are
/// configured in `.tamtoot/opencode.json` in the project; local Ollama
/// models are discovered automatically.
class ModelProfilesSettings extends StatefulWidget {
  const ModelProfilesSettings({super.key, required this.session});

  final IdeSession session;

  @override
  State<ModelProfilesSettings> createState() => _ModelProfilesSettingsState();
}

class _ModelProfilesSettingsState extends State<ModelProfilesSettings> {
  List<Map<String, dynamic>> _providers = const [];
  Map<String, dynamic> _defaults = const {};
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
      final data =
          await OpencodeEngine.forProject(root.toFilePath()).providers();
      if (!mounted) return;
      setState(() {
        final providers = data['providers'];
        _providers = providers is List
            ? providers.whereType<Map<String, dynamic>>().toList()
            : const [];
        final defaults = data['default'];
        _defaults = defaults is Map
            ? Map<String, dynamic>.from(defaults)
            : const {};
      });
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(_error!),
            const SizedBox(height: 12),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    return ListView(
      shrinkWrap: true,
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Model providers are managed by the built-in engine. Edit '
            '.tamtoot/opencode.json in the project to add providers or pick '
            'a model. Local Ollama models are discovered automatically.',
          ),
        ),
        for (final provider in _providers)
          ListTile(
            dense: true,
            leading: const Icon(Icons.cloud_outlined),
            title: Text('${provider['name'] ?? provider['id']}'),
            subtitle: Text(
              'Default model: ${_defaults['${provider['id']}'] ?? '—'}',
            ),
          ),
        if (_providers.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('No providers are configured.'),
          ),
      ],
    );
  }
}
