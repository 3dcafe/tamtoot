import 'package:flutter/material.dart';
import '../app/ide_session.dart';
import '../core/naming/naming_rules.dart';

class NamingSettings extends StatefulWidget {
  const NamingSettings({super.key, required this.session});
  final IdeSession session;
  @override
  State<NamingSettings> createState() => _NamingSettingsState();
}

class _NamingSettingsState extends State<NamingSettings> {
  String language = 'dart';
  static const labels = {
    NameKind.type: 'Types / classes',
    NameKind.function: 'Functions / methods',
    NameKind.variable: 'Variables / fields',
    NameKind.property: 'Properties',
    NameKind.constant: 'Constants',
  };
  void save({
    bool? enabled,
    NameKind? kind,
    NameStyle? style,
    bool reset = false,
  }) {
    final session = widget.session, root = widget.session.workspaceRoot;
    if (root == null) return;
    final projects = Map<String, Object>.from(
      session.settings.get('projectNaming') as Map,
    );
    final current = projects[root.toString()];
    final project = current is Map
        ? Map<String, Object>.from(current)
        : <String, Object>{};
    final rawLanguages = project['languages'];
    final languages = rawLanguages is Map
        ? Map<String, Object>.from(rawLanguages)
        : <String, Object>{};
    if (enabled != null) project['enabled'] = enabled;
    if (reset) {
      languages.remove(language);
    } else if (kind != null && style != null) {
      final rawRules = languages[language];
      final rules = rawRules is Map
          ? Map<String, Object>.from(rawRules)
          : <String, Object>{};
      rules[kind.name] = style.name;
      languages[language] = rules;
    }
    project['languages'] = languages;
    projects[root.toString()] = project;
    session.settings.set('projectNaming', projects);
    session.changed();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    if (session.workspaceRoot == null) {
      return const Text('Open a project to configure its naming conventions.');
    }
    final profile = NamingProfile.forProject(
      session.settings,
      session.workspaceRoot,
      language,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Project: ${session.workspaceRoot!.path}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        SwitchListTile(
          key: const ValueKey('naming-enabled'),
          title: const Text('Check naming conventions'),
          subtitle: const Text(
            'Green underlines are style advice, not compiler errors.',
          ),
          value: profile.enabled,
          onChanged: (v) => save(enabled: v),
        ),
        DropdownButtonFormField<String>(
          key: const ValueKey('naming-language'),
          initialValue: language,
          decoration: const InputDecoration(labelText: 'Language'),
          items: [
            for (final item in NamingProfile.languages.entries)
              DropdownMenuItem(value: item.key, child: Text(item.value)),
          ],
          onChanged: (v) {
            if (v != null) setState(() => language = v);
          },
        ),
        const SizedBox(height: 16),
        for (final kind in NameKind.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DropdownButtonFormField<NameStyle>(
              key: ValueKey(
                'naming-$language-${kind.name}-${profile.rules[kind]!.name}',
              ),
              initialValue: profile.rules[kind],
              isExpanded: true,
              decoration: InputDecoration(labelText: labels[kind]),
              items: [
                for (final style in NameStyle.values)
                  DropdownMenuItem(value: style, child: Text(style.label)),
              ],
              onChanged: (v) => save(kind: kind, style: v),
            ),
          ),
        TextButton(
          onPressed: () => save(reset: true),
          child: const Text('Reset this language to defaults'),
        ),
        const Text(
          'Rules are saved for this project. Checks cover recognized declarations; comments, strings, overrides and Python magic names are excluded. Private prefixes are allowed. No names are changed automatically.',
        ),
      ],
    );
  }
}
