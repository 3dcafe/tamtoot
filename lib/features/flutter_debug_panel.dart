import 'package:flutter/material.dart';
import '../app/ide_session.dart';
import '../core/filesystem/filesystem.dart';
import '../editor/buffer/text_buffer.dart';

class FlutterDebugPanel extends StatelessWidget {
  const FlutterDebugPanel({super.key, required this.session});
  final IdeSession session;
  Widget _button(String title, String command) => TextButton(
    onPressed: session.commands.isEnabled(command)
        ? () => session.run(command)
        : null,
    child: Text(title),
  );
  Future<void> _openFrame(Map<String, dynamic> frame) async {
    try {
      final path = (frame['source'] as Map?)?['path'] as String?;
      if (path == null) return;
      final uri = Uri.file(path);
      final doc = await session.documents.open(
        FileEntry(uri, uri.pathSegments.last),
      );
      session.observe(doc);
      final offset = doc.editor.buffer.offsetAt(
        TextPoint(
          (frame['line'] as int? ?? 1) - 1,
          (frame['column'] as int? ?? 1) - 1,
        ),
      );
      doc.editor.select(offset, offset);
      session.changed();
      await session.flutter.selectFrame(frame['id'] as int);
    } catch (e) {
      session.log('Debug frame: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final runner = session.flutter;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(
          'Flutter · ${runner.state.name}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Wrap(
          children: [
            _button('Run', 'flutter.run'),
            _button('Debug', 'flutter.debug'),
            _button('Stop', 'flutter.stop'),
            _button('Hot reload', 'flutter.hotReload'),
            _button('Hot restart', 'flutter.hotRestart'),
            _button('Pause', 'flutter.pause'),
            _button('Continue', 'flutter.continue'),
            _button('Step over', 'flutter.next'),
            _button('Step into', 'flutter.stepIn'),
            _button('Step out', 'flutter.stepOut'),
            _button('Toggle breakpoint at cursor', 'flutter.breakpoint'),
          ],
        ),
        if (!runner.active)
          const Text(
            'Set the Flutter SDK in Tools → Settings, open a Flutter project, then press Run or Debug. Logs appear in Output.',
          ),
        const Divider(),
        const Text('Breakpoints'),
        for (final entry in runner.breakpoints.entries)
          for (final line in entry.value.toList()..sort())
            ListTile(
              dense: true,
              title: Text('${entry.key}:$line'),
              trailing: IconButton(
                tooltip: 'Remove breakpoint',
                icon: const Icon(Icons.close, size: 16),
                onPressed: () async {
                  try {
                    await runner.toggleBreakpoint(entry.key, line);
                  } catch (e) {
                    session.log('Breakpoint: $e', error: true);
                  }
                },
              ),
            ),
        if (runner.paused) ...[
          const Divider(),
          const Text('Call stack'),
          for (final frame in runner.frames)
            ListTile(
              dense: true,
              selected: frame['id'] == runner.selectedFrame,
              title: Text('${frame['name']} · ${frame['line']}'),
              subtitle: Text('${(frame['source'] as Map?)?['path'] ?? ''}'),
              onTap: () => _openFrame(frame),
            ),
          const Divider(),
          const Text('Variables'),
          for (final variable in runner.variables)
            _VariableValue(
              key: ValueKey(
                '${runner.selectedFrame}:${variable['name']}:${variable['variablesReference']}',
              ),
              session: session,
              variable: variable,
            ),
        ],
      ],
    );
  }
}

class _VariableValue extends StatefulWidget {
  const _VariableValue({
    super.key,
    required this.session,
    required this.variable,
  });
  final IdeSession session;
  final Map<String, dynamic> variable;
  @override
  State<_VariableValue> createState() => _VariableValueState();
}

class _VariableValueState extends State<_VariableValue> {
  Future<List<Map<String, dynamic>>>? _children;
  @override
  Widget build(BuildContext context) {
    final value = widget.variable;
    final reference = value['variablesReference'] as int? ?? 0;
    final title = '${value['name']}: ${value['value']}';
    if (reference == 0) return SelectableText(title);
    return ExpansionTile(
      title: Text(title, style: const TextStyle(fontSize: 12)),
      onExpansionChanged: (expanded) {
        if (expanded && _children == null && widget.session.flutter.paused) {
          setState(
            () => _children = widget.session.flutter.children(reference),
          );
        }
      },
      children: [
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _children,
          builder: (context, snapshot) => snapshot.hasError
              ? Text('${snapshot.error}')
              : Column(
                  children: [
                    for (final child in snapshot.data ?? [])
                      _VariableValue(session: widget.session, variable: child),
                  ],
                ),
        ),
      ],
    );
  }
}
