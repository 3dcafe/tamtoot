import 'package:flutter/material.dart';
import '../app/ide_session.dart';
import '../core/projects/project_detection.dart';

class ProjectLaunchBar extends StatelessWidget {
  const ProjectLaunchBar({super.key, required this.session});
  final IdeSession session;
  Widget _action(IconData icon, String tooltip, String command) => IconButton(
    visualDensity: VisualDensity.compact,
    icon: Icon(icon, size: 20),
    tooltip: tooltip,
    onPressed: session.commands.isEnabled(command)
        ? () => session.commands.execute(command)
        : null,
  );
  @override
  Widget build(BuildContext context) {
    final target = session.launchTarget;
    final busy = session.flutter.active || session.dotnet.active;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: session.launchTargets.isEmpty
              ? const Text(
                  'Project type not detected',
                  overflow: TextOverflow.ellipsis,
                )
              : DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: session.selectedLaunchTarget,
                    items: [
                      for (final item in session.launchTargets)
                        DropdownMenuItem(
                          value: item.id,
                          child: Text(
                            item.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) {
                            session.selectedLaunchTarget = value;
                            session.changed(persist: false);
                          },
                  ),
                ),
        ),
        _action(Icons.refresh, 'Detect project type again', 'project.detect'),
        _action(Icons.play_arrow, 'Run selected project', 'project.run'),
        if (target?.kind == ProjectKind.flutter) ...[
          _action(Icons.bug_report_outlined, 'Debug Flutter', 'flutter.debug'),
          _action(Icons.bolt, 'Hot reload Flutter', 'flutter.hotReload'),
          _action(
            Icons.restart_alt,
            'Hot restart Flutter',
            'flutter.hotRestart',
          ),
        ],
        if (target?.kind == ProjectKind.dotnet)
          _action(
            Icons.bolt,
            'Watch .NET (hot reload; no breakpoint debugger)',
            'dotnet.watch',
          ),
        if (session.flutter.active || target?.kind == ProjectKind.flutter)
          _action(Icons.stop, 'Stop Flutter', 'flutter.stop'),
        if (session.dotnet.active || target?.kind == ProjectKind.dotnet)
          _action(Icons.stop, 'Stop .NET', 'dotnet.stop'),
      ],
    );
  }
}
