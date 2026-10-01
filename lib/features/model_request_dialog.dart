import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/agents/model_client.dart';
import '../core/agents/model_profile.dart';

class ModelRequestDialog extends StatefulWidget {
  const ModelRequestDialog({
    super.key,
    required this.profile,
    required this.prompt,
    this.initialApiKey,
    this.clientFactory,
  });

  final ModelProfile profile;
  final Map<String, dynamic> prompt;
  final String? initialApiKey;
  final ModelClient Function()? clientFactory;

  @override
  State<ModelRequestDialog> createState() => _ModelRequestDialogState();
}

class _ModelRequestDialogState extends State<ModelRequestDialog> {
  late final apiKey = TextEditingController(text: widget.initialApiKey ?? '');
  ModelClient? active;
  ModelReply? reply;
  String? error;
  String streamed = '';

  @override
  void dispose() {
    active?.cancel();
    apiKey.clear();
    apiKey.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (active != null) return;
    final client = widget.clientFactory?.call() ?? ModelClient();
    setState(() {
      active = client;
      reply = null;
      error = null;
      streamed = '';
    });
    try {
      final result = await client.send(
        widget.profile,
        widget.prompt,
        apiKey: apiKey.text,
        onDelta: widget.profile.apiFormat == 'ollama'
            ? (delta) {
                if (mounted) setState(() => streamed += delta);
              }
            : null,
      );
      if (mounted) setState(() => reply = result);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => active = null);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: active == null,
    child: AlertDialog(
      title: Text('Run · ${widget.profile.name}'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(
                '${widget.profile.model}\n${widget.profile.endpoint}',
              ),
              const SizedBox(height: 8),
              const Text(
                'Send transmits the resolved prompts and included editor content to this endpoint. Each request is independent.',
              ),
              ExpansionTile(
                title: const Text('Request preview'),
                children: [
                  SelectableText(
                    const JsonEncoder.withIndent(' ').convert(
                      ModelClient.requestBody(widget.profile, widget.prompt),
                    ),
                  ),
                ],
              ),
              TextField(
                controller: apiKey,
                enabled: active == null,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'API key',
                  helperText:
                      'Kept only in this window. Leave empty for local Ollama or another unauthenticated local server.',
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: 16),
              if (active != null) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                const Text('Waiting for the model…'),
                if (streamed.isNotEmpty) SelectableText(streamed),
              ],
              if (error != null)
                SelectableText(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (reply != null) ...[
                const Text(
                  'Response',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                SelectableText(reply!.text),
                if (reply!.note.isNotEmpty) Text(reply!.note),
                if (reply!.usage.isNotEmpty)
                  Text('Tokens: ${jsonEncode(reply!.usage)}'),
                TextButton(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: reply!.text)),
                  child: const Text('Copy response'),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: active == null ? () => Navigator.pop(context) : null,
          child: const Text('Close'),
        ),
        if (active != null)
          TextButton(
            onPressed: () => active?.cancel(),
            child: const Text('Stop'),
          ),
        FilledButton(
          onPressed: active == null ? _send : null,
          child: const Text('Send'),
        ),
      ],
    ),
  );
}
