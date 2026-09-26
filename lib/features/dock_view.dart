import 'package:flutter/material.dart';
import '../app/ide_session.dart';
import '../workspace/layout/dock_layout.dart';

class DockView extends StatelessWidget {
  const DockView({
    super.key,
    required this.session,
    required this.node,
    required this.documents,
    required this.panel,
  });
  final IdeSession session;
  final DockNode node;
  final Widget Function(String) panel;
  final Widget Function(String) documents;
  @override
  Widget build(BuildContext context) {
    final n = node;
    Widget child(DockNode node) => DockView(
      session: session,
      node: node,
      documents: documents,
      panel: panel,
    );
    if (!session.layout.isVisible(n)) return const SizedBox.shrink();
    if (n is DocumentNode) return documents(n.id);
    if (n is PanelNode) return panel(n.panel);
    if (n is TabNode) {
      final panels = n.panels
          .where((p) => !session.layout.hidden.contains(p))
          .toList();
      final active = panels.contains(n.active) ? n.active : panels.first;
      return ColoredBox(
        color: Color(session.theme.color('panel')),
        child: Column(
          children: [
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final id in panels)
                    InkWell(
                      onTap: () =>
                          session.run('layout.activate', MapEntry(n.id, id)),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              width: 2,
                              color: active == id
                                  ? Color(session.theme.color('accent'))
                                  : Colors.transparent,
                            ),
                          ),
                        ),
                        child: Text(
                          '${id[0].toUpperCase()}${id.substring(1)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(
                              session.theme.color(
                                active == id ? 'foreground' : 'muted',
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(child: panel(active)),
          ],
        ),
      );
    }
    final split = n as SplitNode;
    if (!session.layout.isVisible(split.first)) return child(split.second);
    if (!session.layout.isVisible(split.second)) return child(split.first);
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = split.axis == 'horizontal';
        final available =
            (horizontal ? constraints.maxWidth : constraints.maxHeight) - 10;
        if (available <= 0) return const SizedBox.shrink();
        final first = available * split.ratio;
        final divider = Semantics(
          key: ValueKey('resize-${split.id}'),
          label: 'Resize ${split.id}',
          child: MouseRegion(
            cursor: horizontal
                ? SystemMouseCursors.resizeLeftRight
                : SystemMouseCursors.resizeUpDown,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: horizontal
                  ? (e) => session.run(
                      'layout.resize',
                      MapEntry(split.id, split.ratio + e.delta.dx / available),
                    )
                  : null,
              onVerticalDragUpdate: !horizontal
                  ? (e) => session.run(
                      'layout.resize',
                      MapEntry(split.id, split.ratio + e.delta.dy / available),
                    )
                  : null,
              onDoubleTap: () => session.run('layout.reset'),
              child: SizedBox(
                width: horizontal ? 10 : null,
                height: horizontal ? null : 10,
                child: Center(
                  child: Container(
                    width: horizontal ? 1 : null,
                    height: horizontal ? null : 1,
                    color: Color(session.theme.color('border')),
                  ),
                ),
              ),
            ),
          ),
        );
        return Flex(
          direction: horizontal ? Axis.horizontal : Axis.vertical,
          children: [
            SizedBox(
              width: horizontal ? first : null,
              height: horizontal ? null : first,
              child: child(split.first),
            ),
            divider,
            Expanded(child: child(split.second)),
          ],
        );
      },
    );
  }
}
