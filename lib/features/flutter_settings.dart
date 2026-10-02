import 'package:flutter/material.dart';
import '../app/ide_session.dart';
import '../core/flutter/flutter_runner.dart';

class FlutterSettings extends StatefulWidget {
  const FlutterSettings({super.key, required this.session});
  final IdeSession session;
  @override
  State<FlutterSettings> createState() => _FlutterSettingsState();
}

class _FlutterSettingsState extends State<FlutterSettings> {
  late final _sdk = TextEditingController(
    text: widget.session.settings.get('flutterSdkPath') as String,
  );
  late final _device = TextEditingController(
    text: widget.session.settings.get('flutterDeviceId') as String,
  );
  late final _entry = TextEditingController(
    text: widget.session.settings.get('flutterEntryPoint') as String,
  );
  void _save(String key, String value) {
    widget.session.settings.set(key, value);
    widget.session.changed();
  }

  Future<void> _browse() async {
    try {
      final root = await widget.session.documents.dialogs.openWorkspace();
      if (root == null || !mounted) return;
      _sdk.text = root.toFilePath();
      _save('flutterSdkPath', _sdk.text.trim());
    } catch (e) {
      widget.session.log('Flutter SDK: $e', error: true);
    }
  }

  @override
  void dispose() {
    _sdk.dispose();
    _device.dispose();
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<int>(
    stream: widget.session.changes,
    builder: (context, _) {
      final runner = widget.session.flutter;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(),
          const Text(
            'Flutter SDK',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('flutter-sdk-path'),
            controller: _sdk,
            enabled: !runner.active && !runner.checking,
            decoration: const InputDecoration(
              labelText: 'Flutter SDK folder',
              hintText: '/path/to/flutter or C:\\src\\flutter',
            ),
            onChanged: (text) => _save('flutterSdkPath', text.trim()),
          ),
          Wrap(
            spacing: 8,
            children: [
              if (widget.session.documents.dialogs.supportsDirectories)
                TextButton(
                  onPressed: runner.active || runner.checking ? null : _browse,
                  child: const Text('Browse SDK'),
                ),
              TextButton.icon(
                key: const ValueKey('flutter-sdk-test'),
                icon: const Icon(Icons.check_circle_outline),
                label: Text(runner.checking ? 'Testing…' : 'Test Flutter'),
                onPressed: runner.active || runner.checking
                    ? null
                    : () async {
                        _save('flutterSdkPath', _sdk.text.trim());
                        await widget.session.persistNow();
                        await runner.testSdk(_sdk.text.trim());
                      },
              ),
            ],
          ),
          if (runner.sdkResult != null)
            SelectableText(
              runner.sdkResult!,
              key: const ValueKey('flutter-sdk-result'),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _device,
            enabled: !runner.active,
            decoration: InputDecoration(
              labelText: 'Device ID',
              hintText: defaultFlutterDevice,
              helperText:
                  'Empty selects this desktop. Test Flutter lists available devices.',
            ),
            onChanged: (text) => _save('flutterDeviceId', text.trim()),
          ),
          if (runner.devices.isNotEmpty)
            Wrap(
              spacing: 6,
              children: [
                for (final device in runner.devices)
                  ActionChip(
                    label: Text('${device['name']} (${device['id']})'),
                    onPressed: runner.active
                        ? null
                        : () {
                            _device.text = device['id'] as String;
                            _save('flutterDeviceId', _device.text);
                          },
                  ),
              ],
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _entry,
            enabled: !runner.active,
            decoration: const InputDecoration(
              labelText: 'Entry point',
              hintText: 'lib/main.dart',
            ),
            onChanged: (text) {
              if (text.trim().isNotEmpty) {
                _save('flutterEntryPoint', text.trim());
              }
            },
          ),
          const SizedBox(height: 8),
          const Text(
            'Uses the debugger included in your SDK. The SDK and platform build tools must already be installed.',
          ),
          const Divider(),
        ],
      );
    },
  );
}
