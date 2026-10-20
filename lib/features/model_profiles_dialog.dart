import 'package:flutter/material.dart';

import '../app/ide_session.dart';
import '../core/opencode/config.dart';
import '../core/opencode/engine.dart';
import '../core/opencode/llm.dart';

/// Model settings for the built-in agent engine: pick the Ollama server,
/// the model discovered on it, and whether reasoning (`think`) is enabled.
/// Saved to `.tamtoot/opencode.json` in the project; applies immediately.
class ModelProfilesSettings extends StatefulWidget {
  const ModelProfilesSettings({super.key, required this.session});

  final IdeSession session;

  @override
  State<ModelProfilesSettings> createState() => _ModelProfilesSettingsState();
}

class _ModelProfilesSettingsState extends State<ModelProfilesSettings> {
  final _url = TextEditingController();
  List<String> _models = const [];
  String? _selectedModel;
  var _think = false;
  String? _error;
  String? _notice;
  var _loading = true;
  var _refreshing = false;

  OpencodeEngine? get _engine {
    final root = widget.session.workspaceRoot;
    if (root == null) return null;
    try {
      return OpencodeEngine.forProject(root.toFilePath());
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final engine = _engine;
      if (engine == null) {
        throw const OpencodeException('Open a project folder first.');
      }
      final config = await engine.readConfig();
      final ollama = config.providers['ollama'];
      _url.text = ollama?.baseURL ?? 'http://127.0.0.1:11434';
      _think = ollama?.think ?? false;
      final selected = config.selectedModel;
      if (selected != null && selected.startsWith('ollama/')) {
        _selectedModel = selected.substring('ollama/'.length);
      }
      await _refreshModels(silent: true);
    } on OpencodeException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Fetch the model list from the URL currently in the field, so the user
  /// can type a server address and pick from its models before saving.
  Future<void> _refreshModels({bool silent = false}) async {
    if (!silent) setState(() => _refreshing = true);
    final discovered = await OpencodeConfig.discoverOllamaModels(
      ProviderConfig(
        id: 'ollama',
        type: 'ollama',
        baseURL: _url.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _models = discovered;
      if (_selectedModel == null && discovered.isNotEmpty) {
        _selectedModel = discovered.first;
      }
      _notice = discovered.isEmpty && !silent
          ? 'No models found at ${_url.text.trim()}. Is Ollama running there?'
          : null;
    });
  }

  Future<void> _save() async {
    final engine = _engine;
    if (engine == null) return;
    final config = await engine.readConfig();
    config.providers['ollama'] = ProviderConfig(
      id: 'ollama',
      type: 'ollama',
      baseURL: _url.text.trim(),
      think: _think,
    );
    final model = _selectedModel;
    config.selectedModel = model == null ? null : 'ollama/$model';
    await engine.saveConfig(config, global: true);
    if (!mounted) return;
    setState(
      () => _notice = model == null
          ? 'Saved globally. No model selected — pick one above.'
          : 'Saved globally. The agent now uses ollama/$model in every project.',
    );
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
      padding: const EdgeInsets.all(12),
      children: [
        TextField(
          controller: _url,
          decoration: InputDecoration(
            labelText: 'Ollama server URL',
            hintText: 'http://192.168.0.84:11434',
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: 'Fetch models from this server',
              onPressed: _refreshing ? null : _refreshModels,
              icon: _refreshing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
            ),
          ),
          onSubmitted: (_) => _refreshModels(),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _models.contains(_selectedModel) ? _selectedModel : null,
          decoration: const InputDecoration(
            labelText: 'Model',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: [
            for (final model in _models)
              DropdownMenuItem(value: model, child: Text(model)),
          ],
          onChanged: (value) => setState(() => _selectedModel = value),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Reasoning (think)'),
          subtitle: const Text(
            'Off is the validated default for Qwen3 coding sessions.',
          ),
          value: _think,
          onChanged: (value) => setState(() => _think = value),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('Save'),
            ),
            const SizedBox(width: 12),
            if (_notice != null)
              Expanded(
                child: Text(_notice!, style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
        const Divider(height: 32),
        Text(
          'Saved to your global settings (~/.tamtoot/opencode.json) and '
          'applies to every project. A .tamtoot/opencode.json inside a '
          'project overrides it; OpenAI-compatible providers with API keys '
          'are edited there too.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
