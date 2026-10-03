import 'package:flutter/material.dart';
import '../app/ide_session.dart';

class DotnetSettings extends StatefulWidget {
  const DotnetSettings({super.key, required this.session});
  final IdeSession session;
  @override
  State<DotnetSettings> createState() => _DotnetSettingsState();
}

class _DotnetSettingsState extends State<DotnetSettings> {
  late final _path = TextEditingController(
    text: widget.session.settings.get('dotnetPath') as String,
  );
  void _save(String value) {
    widget.session.settings.set('dotnetPath', value.trim());
    widget.session.dotnet.sdkResult = null;
    widget.session.changed();
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<int>(
    stream: widget.session.changes,
    builder: (context, _) {
      final runner = widget.session.dotnet;
      final busy =
          runner.active || runner.checking || widget.session.flutter.active;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('.NET SDK', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('dotnet-path'),
            controller: _path,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'dotnet executable or installation folder',
              hintText: 'Leave empty to detect automatically',
            ),
            onChanged: _save,
          ),
          Wrap(
            spacing: 8,
            children: [
              if (widget.session.documents.dialogs.supportsDirectories)
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          final root = await widget.session.documents.dialogs
                              .openWorkspace();
                          if (root == null || !mounted) return;
                          _path.text = root.toFilePath();
                          _save(_path.text);
                        },
                  child: const Text('Browse SDK'),
                ),
              TextButton.icon(
                key: const ValueKey('dotnet-test'),
                icon: const Icon(Icons.check_circle_outline),
                label: Text(runner.checking ? 'Testing…' : 'Test .NET'),
                onPressed: busy
                    ? null
                    : () async {
                        _save(_path.text);
                        await widget.session.persistNow();
                        await runner.testSdk(_path.text.trim());
                      },
              ),
            ],
          ),
          if (runner.sdkResult != null) SelectableText(runner.sdkResult!),
          const Text(
            'Automatic search: DOTNET_HOST_PATH, DOTNET_ROOT, PATH and standard installation folders. Test lists installed SDKs without building a project.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Run and Watch use the installed SDK. Watch supports hot reload where available. Breakpoint debugging requires a separate .NET debug adapter; it is not included in the SDK.',
          ),
          const Divider(),
        ],
      );
    },
  );
}
