import 'dart:convert';
import 'package:flutter/material.dart';
import '../app/ide_session.dart';
import '../core/agents/model_profile.dart';
import '../core/agents/model_client.dart';
import '../core/agents/model_api_probe.dart';
import '../core/agents/ollama_client.dart';
import '../core/agents/profile_store.dart';
import '../core/git/http_git_service.dart';
import 'model_request_dialog.dart';

class ModelProfilesDialog extends StatefulWidget {
  const ModelProfilesDialog({super.key, required this.session});
  final IdeSession session;
  @override
  State<ModelProfilesDialog> createState() => _ModelProfilesDialogState();
}

class _ModelProfilesDialogState extends State<ModelProfilesDialog> {
  static const openaiSuggestedModels = [
    'gpt-4o-mini',
    'gpt-4o',
    'gpt-4.1-mini',
    'gpt-4.1',
    'o4-mini',
    'o3-mini',
  ];

  final id = TextEditingController(),
      name = TextEditingController(),
      provider = TextEditingController(text: 'ollama'),
      model = TextEditingController(),
      endpoint = TextEditingController(text: 'http://localhost:11434/api/chat'),
      system = TextEditingController(text: defaultSystemPrompt),
      template = TextEditingController(text: defaultUserTemplate),
      parameters = TextEditingController(text: '{}'),
      instructions = TextEditingController(),
      task = TextEditingController(),
      apiKey = TextEditingController();
  String apiFormat = 'ollama';
  String serverType = 'ollama';
  List<OllamaModel> ollamaModels = const [];
  List<String> detectedModels = const [];
  String? connectionStatus;
  ProfileStore? store;
  List<String> paths = [];
  String? selected, original, originalInstructions, error;
  bool busy = true, dirty = false, instructionsDirty = false;
  late final Uri? root = widget.session.workspaceRoot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      id,
      name,
      provider,
      model,
      endpoint,
      system,
      template,
      parameters,
      instructions,
      task,
      apiKey,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _needsApiKey =>
      serverType == 'openai' ||
      serverType == 'anthropic' ||
      serverType == 'ai-star' ||
      serverType == 'custom';

  List<String> get _modelChoices {
    if (detectedModels.isNotEmpty) return detectedModels;
    if (serverType == 'openai' || serverType == 'ai-star') {
      return openaiSuggestedModels;
    }
    return const [];
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) error = '$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    final git = widget.session.git;
    if (root == null) {
      throw StateError('Open a project to edit its model profiles.');
    }
    if (git is! HttpGitService) {
      throw UnsupportedError(
        'This workspace provider does not support profile files.',
      );
    }
    final loaded = ProfileStore(git.openStore(root!));
    final found = await loaded.list();
    final text = await loaded.read(ProfileStore.instructionsPath);
    if (!mounted) return;
    store = loaded;
    paths = found;
    originalInstructions = text;
    instructions.text = text ?? '';
  });

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ) ??
      false;

  Future<bool> _select(String? path) async {
    if (dirty &&
        !await _confirm(
          'Discard profile edits?',
          'Unsaved edits to this model profile will be lost.',
        )) {
      return false;
    }
    await _run(() async {
      final text = path == null ? null : await store!.read(path);
      if (path != null && text == null) {
        throw StateError('Profile no longer exists. Reopen the dialog.');
      }
      final p = text == null ? null : ModelProfile.parse(text);
      if (p != null && store!.path(p.id) != path) {
        throw const FormatException('Profile ID does not match its filename.');
      }
      if (!mounted) return;
      selected = path;
      original = text;
      id.text = p?.id ?? '';
      name.text = p?.name ?? '';
      provider.text = p?.provider ?? 'ollama';
      model.text = p?.model ?? '';
      endpoint.text = p?.endpoint ?? 'http://localhost:11434/api/chat';
      apiFormat = p?.apiFormat ?? 'ollama';
      serverType = _serverType(p);
      apiKey.text = p == null ? '' : widget.session.modelApiKey(p.id);
      detectedModels = const [];
      connectionStatus = null;
      system.text = p?.systemPrompt ?? defaultSystemPrompt;
      template.text = p?.userTemplate ?? defaultUserTemplate;
      parameters.text = const JsonEncoder.withIndent(
        '  ',
      ).convert(p?.parameters ?? {});
      dirty = false;
    });
    return true;
  }

  ModelProfile _profile() {
    final params = jsonDecode(parameters.text);
    if (params is! Map<String, dynamic>) {
      throw const FormatException('Parameters must be a JSON object.');
    }
    final generatedId = name.text
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return ModelProfile(
      id: id.text.trim().isEmpty ? generatedId : id.text.trim(),
      name: name.text.trim(),
      provider: provider.text.trim(),
      model: model.text.trim(),
      systemPrompt: system.text,
      userTemplate: template.text,
      parameters: params,
      apiFormat: apiFormat,
      endpoint: endpoint.text.trim(),
    )..validate();
  }

  String _serverType(ModelProfile? profile) {
    if (profile == null) return 'ollama';
    final value = profile.endpoint.toLowerCase();
    if (profile.apiFormat == 'ollama') return 'ollama';
    if (value.contains('localhost:1234')) return 'lm-studio';
    if (value.contains('localhost:8080')) return 'localai';
    if (value.contains('api.openai.com')) return 'openai';
    if (value.contains('api.anthropic.com')) return 'anthropic';
    if (value.contains('ai.starimg.ru') || value.contains('ai.starimg.space')) {
      return 'ai-star';
    }
    return 'custom';
  }

  void _chooseServer(String value) {
    const presets = <String, (String, String, String)>{
      'ollama': ('ollama', 'ollama', 'http://localhost:11434/api/chat'),
      'lm-studio': (
        'lm-studio',
        'chat-completions',
        'http://localhost:1234/v1/chat/completions',
      ),
      'localai': (
        'localai',
        'chat-completions',
        'http://localhost:8080/v1/chat/completions',
      ),
      'openai': ('openai', 'responses', 'https://api.openai.com/v1/responses'),
      'ai-star': ('ai-star', 'chat-completions', 'https://ai.starimg.ru/v1'),
      'anthropic': (
        'anthropic',
        'anthropic',
        'https://api.anthropic.com/v1/messages',
      ),
    };
    setState(() {
      serverType = value;
      final preset = presets[value];
      if (preset != null) {
        provider.text = preset.$1;
        apiFormat = preset.$2;
        endpoint.text = preset.$3;
      } else if (value == 'custom') {
        provider.text = 'custom';
        apiFormat = 'chat-completions';
        endpoint.clear();
      }
      if (value == 'openai') {
        if (name.text.trim().isEmpty || name.text.trim() == 'New model') {
          name.text = 'OpenAI GPT';
        }
        if (id.text.trim().isEmpty || id.text.trim() == 'new-model') {
          id.text = 'openai-gpt';
        }
        if (model.text.trim().isEmpty ||
            !openaiSuggestedModels.contains(model.text.trim())) {
          model.text = openaiSuggestedModels.first;
        }
      } else if (value == 'ai-star') {
        if (name.text.trim().isEmpty || name.text.trim() == 'New model') {
          name.text = 'AI STAR coding agent';
        }
        if (id.text.trim().isEmpty || id.text.trim() == 'new-model') {
          id.text = 'ai-star-agent';
        }
        model.text = 'gpt-6.1-sol';
        parameters.text = const JsonEncoder.withIndent(
          '  ',
        ).convert({'temperature': 0.1, 'max_tokens': 2048});
      }
      detectedModels = const [];
      ollamaModels = const [];
      connectionStatus = null;
      dirty = true;
    });
  }

  Future<void> _checkConnection() => _run(() async {
    final profile = ModelProfile(
      id: 'connection-check',
      name: 'Connection check',
      provider: provider.text.trim().isEmpty
          ? serverType
          : provider.text.trim(),
      model: model.text.trim().isEmpty ? '__probe__' : model.text.trim(),
      apiFormat: apiFormat,
      endpoint: endpoint.text.trim(),
    );
    final probe = ModelApiProbe();
    try {
      final result = await probe.check(profile, apiKey: apiKey.text);
      if (!mounted) return;
      final profileId = id.text.trim();
      if (profileId.isNotEmpty) {
        widget.session.rememberModelApiKey(profileId, apiKey.text);
      }
      detectedModels = result.models;
      connectionStatus = '${result.message}\nRequests: ${profile.requestUri()}';
      if (model.text.isEmpty && result.models.isNotEmpty) {
        model.text = result.models.first;
        dirty = true;
      }
    } finally {
      probe.close();
    }
  });

  void _checkProject() {
    if (widget.session.workspaceRoot != root) {
      throw StateError('The active project changed. Reopen model profiles.');
    }
  }

  Future<void> _save() => _run(() async {
    _checkProject();
    final p = _profile();
    final target = store!.path(p.id), text = p.encode();
    await store!.save(target, text, original);
    if (!mounted) return;
    selected = target;
    id.text = p.id;
    original = text;
    dirty = false;
    paths = await store!.list();
    widget.session.rememberModelApiKey(p.id, apiKey.text);
    widget.session.notifyAgentCatalogChanged();
  });

  Future<void> _saveInstructions() => _run(() async {
    _checkProject();
    final text = instructions.text;
    await store!.save(
      ProfileStore.instructionsPath,
      text,
      originalInstructions,
    );
    if (!mounted) return;
    originalInstructions = text;
    instructionsDirty = false;
  });

  Future<void> _delete() async {
    if (!await _confirm(
      'Delete model profile?',
      'Delete ${id.text}? This does not delete the model or its provider account.',
    )) {
      return;
    }
    await _run(() async {
      _checkProject();
      widget.session.rememberModelApiKey(id.text.trim(), '');
      await store!.delete(id.text, original!);
      if (!mounted) return;
      paths = await store!.list();
      selected = null;
      original = null;
      dirty = false;
      id.clear();
      name.clear();
      provider.text = 'ollama';
      model.clear();
      endpoint.text = 'http://localhost:11434/api/chat';
      apiFormat = 'ollama';
      serverType = 'ollama';
      detectedModels = const [];
      connectionStatus = null;
      system.text = defaultSystemPrompt;
      template.text = defaultUserTemplate;
      parameters.text = '{}';
      widget.session.notifyAgentCatalogChanged();
    });
  }

  Map<String, dynamic> _prompt() {
    final doc = widget.session.documents.active;
    final selection = doc?.editor.selection;
    return _profile().preview(
      task: task.text,
      instructions: instructions.text,
      filePath: doc?.uri?.toString() ?? doc?.name ?? '',
      file: doc?.editor.text ?? '',
      selection: doc == null || selection == null
          ? ''
          : doc.editor.text.substring(selection.start, selection.end),
    );
  }

  Future<void> _preview() async {
    try {
      final preview = _prompt();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Prompt preview · not sent'),
          content: SizedBox(
            width: 700,
            child: SingleChildScrollView(
              child: SelectableText(
                const JsonEncoder.withIndent('  ').convert(preview),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _runModel() async {
    try {
      _checkProject();
      final profile = _profile();
      profile.requestUri();
      final prompt = _prompt();
      ModelClient.requestBody(profile, prompt);
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ModelRequestDialog(
          profile: profile,
          prompt: prompt,
          initialApiKey: apiKey.text,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _detectOllama() => _run(() async {
    final source = endpoint.text.trim().isEmpty
        ? 'http://localhost:11434'
        : endpoint.text.trim().replaceFirst(RegExp(r'/api/chat$'), '');
    final client = OllamaClient();
    try {
      final found = await client.models(source);
      if (!mounted) return;
      ollamaModels = found;
      provider.text = 'ollama';
      apiFormat = 'ollama';
      endpoint.text = '$source/api/chat';
      if (model.text.isEmpty && found.isNotEmpty) model.text = found.first.name;
      dirty = true;
    } finally {
      client.close();
    }
  });

  Future<void> _selectOllamaModel(String value) async {
    setState(() {
      model.text = value;
      dirty = true;
    });
    final base = endpoint.text.replaceFirst(RegExp(r'/api/chat$'), '');
    final client = OllamaClient();
    try {
      final contextWindow = await client.contextWindow(base, value);
      if (contextWindow == null || !mounted) return;
      final current = jsonDecode(parameters.text);
      if (current is Map<String, dynamic>) {
        current['num_ctx'] = contextWindow < 32768 ? 32768 : contextWindow;
        parameters.text = const JsonEncoder.withIndent('  ').convert(current);
        setState(() => dirty = true);
      }
    } finally {
      client.close();
    }
  }

  Future<void> _close() async {
    if ((dirty || instructionsDirty) &&
        !await _confirm(
          'Discard unsaved edits?',
          'Profile or project instruction edits have not been saved.',
        )) {
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    int lines = 1,
    bool enabled = true,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      enabled: !busy && enabled,
      minLines: lines,
      maxLines: lines == 1 ? 1 : lines + 8,
      onChanged: (_) => setState(() => dirty = true),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy && !dirty && !instructionsDirty,
    child: AlertDialog(
      title: const Text('Model profiles'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Project profiles and prompt templates. Run uses the current form, including unsaved prompt edits. API keys stay in memory only and are never saved into the profile.',
              ),
              const SizedBox(height: 12),
              if (busy) const LinearProgressIndicator(),
              if (store != null) ...[
                DropdownButton<String>(
                  key: const ValueKey('model-profile-picker'),
                  isExpanded: true,
                  value: selected,
                  hint: const Text('New profile'),
                  items: [
                    for (final path in paths)
                      DropdownMenuItem(
                        value: path,
                        child: Text(
                          path.split('/').last,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: busy ? null : (value) => _select(value),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: busy ? null : () => _select(null),
                      child: const Text('New profile'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              if (!await _select(null)) return;
                              if (!mounted) return;
                              _chooseServer('openai');
                            },
                      child: const Text('Add OpenAI GPT'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              if (!await _select(null)) return;
                              if (!mounted) return;
                              _chooseServer('ai-star');
                            },
                      child: const Text('Add AI STAR agent'),
                    ),
                    TextButton(
                      onPressed: busy || selected == null ? null : _delete,
                      child: const Text('Delete profile'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              if (!await _confirm(
                                'Reset prompts?',
                                'Replace both prompts with the built-in defaults? Save the profile to keep this change.',
                              )) {
                                return;
                              }
                              if (mounted) {
                                setState(() {
                                  system.text = defaultSystemPrompt;
                                  template.text = defaultUserTemplate;
                                  dirty = true;
                                });
                              }
                            },
                      child: const Text('Reset prompts'),
                    ),
                  ],
                ),
                _field('Display name', name),
                DropdownButtonFormField<String>(
                  key: ValueKey('server-$serverType'),
                  isExpanded: true,
                  initialValue: serverType,
                  decoration: const InputDecoration(
                    labelText: 'Model server',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'ollama',
                      child: Text('Ollama · local'),
                    ),
                    DropdownMenuItem(
                      value: 'lm-studio',
                      child: Text('LM Studio · local'),
                    ),
                    DropdownMenuItem(
                      value: 'localai',
                      child: Text('LocalAI · local'),
                    ),
                    DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
                    DropdownMenuItem(
                      value: 'ai-star',
                      child: Text('AI STAR · compatible API'),
                    ),
                    DropdownMenuItem(
                      value: 'anthropic',
                      child: Text('Anthropic'),
                    ),
                    DropdownMenuItem(
                      value: 'custom',
                      child: Text('Custom compatible API'),
                    ),
                  ],
                  onChanged: busy ? null : (value) => _chooseServer(value!),
                ),
                const SizedBox(height: 12),
                if (serverType == 'custom')
                  _field(
                    'Server URL (base, /v1/models, or request endpoint)',
                    endpoint,
                  ),
                if (_needsApiKey) ...[
                  TextField(
                    controller: apiKey,
                    enabled: !busy,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: serverType == 'openai'
                          ? 'OpenAI API key (for check / run, not saved)'
                          : serverType == 'ai-star'
                          ? 'AI STAR token (for check / run, not saved)'
                          : 'API key (for check / run, not saved)',
                      border: const OutlineInputBorder(),
                      helperText:
                          'Paste the key here to check models and Run model. Agent uses its own key field.',
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (ollamaModels.isEmpty && _modelChoices.isEmpty)
                  _field('Model name', model),
                if (_modelChoices.isNotEmpty)
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      'models-$serverType-${_modelChoices.join(',')}-${model.text}',
                    ),
                    isExpanded: true,
                    initialValue: _modelChoices.contains(model.text)
                        ? model.text
                        : null,
                    hint: Text(
                      detectedModels.isNotEmpty
                          ? 'Choose a detected model'
                          : 'Choose an OpenAI model',
                    ),
                    decoration: InputDecoration(
                      labelText: detectedModels.isNotEmpty
                          ? 'Available models'
                          : 'OpenAI model',
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      for (final value in _modelChoices)
                        DropdownMenuItem(value: value, child: Text(value)),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                            model.text = value!;
                            dirty = true;
                          }),
                  ),
                if (serverType == 'openai' && detectedModels.isEmpty) ...[
                  const SizedBox(height: 8),
                  _field('Or type another model id', model),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      key: const ValueKey('check-model-api'),
                      onPressed: busy ? null : _checkConnection,
                      icon: const Icon(Icons.health_and_safety_outlined),
                      label: const Text('Check connection'),
                    ),
                    if (serverType == 'ollama')
                      TextButton(
                        onPressed: busy ? null : _detectOllama,
                        child: const Text('Find Ollama models'),
                      ),
                  ],
                ),
                if (connectionStatus != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      connectionStatus!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                if (ollamaModels.isNotEmpty)
                  DropdownButton<String>(
                    isExpanded: true,
                    value: ollamaModels.any((item) => item.name == model.text)
                        ? model.text
                        : null,
                    hint: const Text('Choose an Ollama model'),
                    items: [
                      for (final item in ollamaModels)
                        DropdownMenuItem(
                          value: item.name,
                          child: Text(item.name),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) {
                            if (value != null) _selectOllamaModel(value);
                          },
                  ),
                ExpansionTile(
                  title: const Text('Advanced connection settings'),
                  subtitle: const Text('Usually no changes are needed'),
                  children: [
                    _field('Profile ID', id, enabled: selected == null),
                    _field('Provider ID', provider),
                    DropdownButtonFormField<String>(
                      key: ValueKey('format-$apiFormat'),
                      isExpanded: true,
                      initialValue: apiFormat,
                      decoration: const InputDecoration(
                        labelText: 'API compatibility format',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final entry in ModelProfile.apiFormats.entries)
                          DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                      ],
                      onChanged: busy
                          ? null
                          : (value) => setState(() {
                              apiFormat = value!;
                              serverType = 'custom';
                              dirty = true;
                            }),
                    ),
                    const SizedBox(height: 12),
                    if (serverType != 'custom')
                      _field('API endpoint', endpoint),
                    _field(
                      'API parameters (JSON object)',
                      parameters,
                      lines: 3,
                    ),
                  ],
                ),
                _field('System prompt', system, lines: 3),
                _field('User prompt template', template, lines: 5),
                const Text(
                  'Variables: {{task}}, {{file_path}}, {{file}}, {{selection}}. Project instructions are appended to the system prompt.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Parameters are sent to the selected API. Ollama uses num_ctx for its context window. Streaming and tool calls are not used in this simple request view.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: task,
                  enabled: !busy,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Task',
                    border: OutlineInputBorder(),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: busy ? null : _preview,
                      child: const Text('Preview prompts'),
                    ),
                    FilledButton(
                      onPressed: busy ? null : _runModel,
                      child: const Text('Run model…'),
                    ),
                    FilledButton(
                      onPressed: busy ? null : _save,
                      child: Text(dirty ? 'Save profile *' : 'Save profile'),
                    ),
                  ],
                ),
                const Divider(height: 28),
                TextField(
                  controller: instructions,
                  enabled: !busy,
                  minLines: 3,
                  maxLines: 12,
                  onChanged: (_) => setState(() => instructionsDirty = true),
                  decoration: const InputDecoration(
                    labelText: 'Shared project instructions',
                    border: OutlineInputBorder(),
                  ),
                ),
                TextButton(
                  onPressed: busy ? null : _saveInstructions,
                  child: Text(
                    instructionsDirty
                        ? 'Save instructions *'
                        : 'Save instructions',
                  ),
                ),
              ],
              if (error != null)
                SelectableText(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: busy ? null : _close, child: const Text('Close')),
      ],
    ),
  );
}
