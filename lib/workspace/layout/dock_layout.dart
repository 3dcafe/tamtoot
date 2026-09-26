import 'dart:convert';
import '../../core/persistence/schema.dart';

sealed class DockNode {
  const DockNode(this.id);
  final String id;
  Map<String, Object?> toJson();
}

class SplitNode extends DockNode {
  const SplitNode(super.id, this.axis, this.ratio, this.first, this.second);
  final String axis;
  final double ratio;
  final DockNode first, second;
  @override
  Map<String, Object?> toJson() => {
    'type': 'split',
    'id': id,
    'axis': axis,
    'ratio': ratio,
    'first': first.toJson(),
    'second': second.toJson(),
  };
}

class TabNode extends DockNode {
  const TabNode(super.id, this.panels, this.active);
  final List<String> panels;
  final String active;
  @override
  Map<String, Object?> toJson() => {
    'type': 'tabs',
    'id': id,
    'panels': panels,
    'active': active,
  };
}

class DocumentNode extends DockNode {
  const DocumentNode(super.id);
  @override
  Map<String, Object?> toJson() => {'type': 'documents', 'id': id};
}

class PanelNode extends DockNode {
  const PanelNode(super.id, this.panel);
  final String panel;
  @override
  Map<String, Object?> toJson() => {'type': 'panel', 'id': id, 'panel': panel};
}

class DockLayout {
  const DockLayout(this.root, {this.hidden = const {}});
  final DockNode root;
  final Set<String> hidden;
  static const panelIds = {
    'explorer',
    'problems',
    'output',
    'terminal',
    'debug',
  };
  static const defaultLayout = DockLayout(
    SplitNode(
      'vertical',
      'vertical',
      .76,
      SplitNode(
        'horizontal',
        'horizontal',
        .22,
        PanelNode('explorerPanel', 'explorer'),
        DocumentNode('primary'),
      ),
      TabNode('tools', ['problems', 'output', 'terminal', 'debug'], 'output'),
    ),
  );
  String encode() => jsonEncode({
    'schemaVersion': 1,
    'layoutId': 'workspace',
    'root': root.toJson(),
    'hidden': hidden.toList(),
  });
  factory DockLayout.parse(
    String source, {
    Set<String> knownPanels = panelIds,
  }) {
    final data = decodeVersioned(source, 'Layout');
    var documents = 0;
    DockNode? parse(Object? raw, int depth) {
      if (depth > 32 || raw is! Map<String, dynamic>) {
        throw const SchemaException('Invalid or deeply nested layout');
      }
      final id = requiredString(raw, 'id');
      switch (raw['type']) {
        case 'documents':
          documents++;
          return DocumentNode(id);
        case 'panel':
          final panel = requiredString(raw, 'panel');
          return knownPanels.contains(panel) ? PanelNode(id, panel) : null;
        case 'tabs':
          final panels = stringList(
            raw['panels'],
            'panels',
          ).where(knownPanels.contains).toSet().toList();
          if (panels.isEmpty) return null;
          final active = raw['active'];
          return TabNode(
            id,
            panels,
            panels.contains(active) ? active as String : panels.first,
          );
        case 'split':
          if (raw['axis'] != 'horizontal' && raw['axis'] != 'vertical') {
            throw const SchemaException('Invalid split axis');
          }
          final ratio = raw['ratio'];
          if (ratio is! num || !ratio.isFinite) {
            throw const SchemaException('Invalid split ratio');
          }
          final a = parse(raw['first'], depth + 1),
              b = parse(raw['second'], depth + 1);
          if (a == null) return b;
          if (b == null) return a;
          return SplitNode(
            id,
            raw['axis'] as String,
            ratio.toDouble().clamp(.1, .9),
            a,
            b,
          );
        default:
          throw SchemaException('Unknown required node type ${raw['type']}');
      }
    }

    final root = parse(data['root'], 0);
    if (root == null || documents == 0) return defaultLayout;
    return DockLayout(
      root,
      hidden: stringList(
        data['hidden'] ?? [],
        'hidden',
      ).where(knownPanels.contains).toSet(),
    );
  }
  DockLayout map(DockNode Function(DockNode) transform) {
    DockNode visit(DockNode n) => transform(
      n is SplitNode
          ? SplitNode(n.id, n.axis, n.ratio, visit(n.first), visit(n.second))
          : n,
    );
    return DockLayout(visit(root), hidden: hidden);
  }

  DockLayout resize(String id, double ratio) => map(
    (n) => n is SplitNode && n.id == id
        ? SplitNode(n.id, n.axis, ratio.clamp(.1, .9), n.first, n.second)
        : n,
  );
  DockLayout activate(String id, String panel) => map(
    (n) => n is TabNode && n.id == id && n.panels.contains(panel)
        ? TabNode(n.id, n.panels, panel)
        : n,
  );
  DockLayout toggle(String panel) {
    final updated = {...hidden};
    if (!updated.remove(panel)) updated.add(panel);
    return DockLayout(root, hidden: updated);
  }

  bool isVisible(DockNode n) => switch (n) {
    PanelNode() => !hidden.contains(n.panel),
    TabNode() => n.panels.any((p) => !hidden.contains(p)),
    DocumentNode() => true,
    SplitNode() => isVisible(n.first) || isVisible(n.second),
  };
}
