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
      widget.session.flutter.clearDevices();
      _save('flutterSdkPath', _sdk.text.trim());
    } catch (e) {
      widget.session.log('Flutter SDK: $e', error: true);
    }
  }

  @override
  void dispose() {
    _sdk.dispose();
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<int>(
    stream: widget.session.changes,
    builder: (context, _) {
      final runner = widget.session.flutter;
      final selected = widget.session.settings.get('flutterDeviceId') as String;
      final savedName =
          widget.session.settings.get('flutterDeviceName') as String;
      final known = runner.devices.any((device) => device['id'] == selected);
      final computer = switch (defaultFlutterDevice) {
        'windows' => 'Windows',
        'linux' => 'Linux',
        _ => 'macOS',
      };
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
            onChanged: (text) {
              runner.clearDevices();
              _save('flutterSdkPath', text.trim());
            },
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
          Row(
            children: [
              Expanded(
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Device'),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      key: const ValueKey('flutter-device-picker'),
                      isExpanded: true,
                      value: selected,
                      items: [
                        DropdownMenuItem(
                          value: '',
                          child: Text('This computer ($computer)'),
                        ),
                        for (final device in runner.devices)
                          DropdownMenuItem(
                            value: device['id'] as String,
                            child: Text(
                              '${device['name'] ?? 'Unnamed device'}${device['emulator'] == true ? ' (emulator)' : ''}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        if (selected.isNotEmpty && !known)
                          DropdownMenuItem(
                            value: selected,
                            enabled: false,
                            child: Text(
                              '${savedName.isEmpty ? 'Previously selected device' : savedName} (${runner.devicesLoaded ? 'not connected' : 'refresh to check'})',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: runner.active || runner.checking
                          ? null
                          : (value) {
                              if (value == null) return;
                              final name =
                                  runner.devices
                                          .where(
                                            (device) => device['id'] == value,
                                          )
                                          .firstOrNull?['name']
                                      as String? ??
                                  '';
                              _save('flutterDeviceId', value);
                              _save('flutterDeviceName', name);
                            },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                key: const ValueKey('flutter-devices-refresh'),
                icon: const Icon(Icons.refresh),
                label: Text(runner.checking ? 'Loading…' : 'Refresh'),
                onPressed:
                    runner.active || runner.checking || _sdk.text.trim().isEmpty
                    ? null
                    : () => runner.refreshDevices(_sdk.text.trim()),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            runner.deviceError ??
                (runner.devicesLoaded
                    ? runner.devices.isEmpty
                          ? 'No devices found. Connect a device or start an emulator, then refresh.'
                          : 'Select the device where the app should run.'
                    : 'Press Refresh or Test Flutter to find connected devices and running emulators.'),
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
