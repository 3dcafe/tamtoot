/// Conservative host checks for the reported public Angular Help-page failure.
/// Evidence is actual source read by the host, not assertions from the model.
class AgentCompletion {
  static List<String> requirementsFromTask(String task) => [
    for (final line in task.split('\n'))
      if (RegExp(r'^\s*(?:[-*]|\d+[.)])\s+').hasMatch(line))
        line.replaceFirst(RegExp(r'^\s*(?:[-*]|\d+[.)])\s+'), '').trim(),
  ];

  static String requirementContext(String task) {
    final items = requirementsFromTask(task);
    return items.length < 2
        ? ''
        : 'Host requirement checklist (zero-based IDs): ${items.asMap().entries.map((e) => '[${e.key}] ${e.value}').join('; ')}';
  }

  static bool isHelpPageTask(String task) =>
      RegExp(r'help|помощ|справ', caseSensitive: false).hasMatch(task) &&
      RegExp(
        r'page|component|страниц|компонент',
        caseSensitive: false,
      ).hasMatch(task) &&
      RegExp(r'angular|frontend|фронт', caseSensitive: false).hasMatch(task);

  static Map<String, bool> helpChecks(
    Map<String, String> files,
    Set<String> edited,
  ) {
    final pageFiles = files.entries.where(
      (e) =>
          edited.contains(e.key) &&
          RegExp(r'help|помощ|справ', caseSensitive: false).hasMatch(e.key),
    );
    final page = pageFiles.map((e) => e.value).join('\n');
    final all = files.values.join('\n');
    final routes = files.entries
        .where((e) => e.key.endsWith('.ts') && e.value.contains('path'))
        .map((e) => e.value)
        .join('\n');
    final navigation = files.values.any(
      (s) => RegExp(
        r'''(?:routerLink|href)\s*=\s*["'][^"']*/help|navigate(?:ByUrl)?\s*\([^;]*["']/help|routerLink\s*\]\s*=\s*["'][^\n]*help''',
        caseSensitive: false,
      ).hasMatch(s),
    );
    final docs = files.entries
        .where((e) => e.key.endsWith('.md') || e.key.endsWith('package.json'))
        .map((e) => e.value)
        .join(' ');
    Set<String> words(String text) =>
        RegExp(r'[a-zа-яё]{5,}', caseSensitive: false)
            .allMatches(text.toLowerCase())
            .map((m) => m[0]!)
            .where(
              (w) => !{
                'project',
                'about',
                'class',
                'style',
                'return',
                'import',
                'export',
                'template',
                'standalone',
                'component',
                'angular',
                'package',
                'version',
                'private',
                'public',
                'description',
                'dependencies',
              }.contains(w),
            )
            .toSet();
    final facts = words(docs).intersection(words(page));
    return {
      'actual_help_page':
          page.length > 100 &&
          (page.contains('@Component') || page.contains('<h1')),
      'application_integration': files.entries.any(
        (e) =>
            edited.contains(e.key) &&
            !RegExp(r'help', caseSensitive: false).hasMatch(e.key) &&
            RegExp(
              r'Help\w*|/help|path\s*:\s*["\x27]help',
              caseSensitive: false,
            ).hasMatch(e.value),
      ),
      'help_navigation': navigation,
      'public_help_route': _publicHelp(routes),
      'meaningful_project_content':
          RegExp(r'[a-zа-яё]', caseSensitive: false).allMatches(page).length >=
              100 &&
          facts.length >= 2 &&
          !RegExp(
            r'lorem ipsum|TODO:.*help',
            caseSensitive: false,
          ).hasMatch(page),
      'source_evidence': all.isNotEmpty,
    };
  }

  static bool _publicHelp(String source) {
    // Track object nesting, skipping quoted strings and comments. Inspect the
    // Help route and its ancestor route objects, not unrelated sibling guards.
    final stack = <int>[];
    final ends = <int, int>{};
    final parents = <int, List<int>>{};
    String? quote;
    var lineComment = false, blockComment = false;
    for (var i = 0; i < source.length; i++) {
      final c = source[i];
      final next = i + 1 < source.length ? source[i + 1] : '';
      if (lineComment) {
        if (c == '\n') lineComment = false;
        continue;
      }
      if (blockComment) {
        if (c == '*' && next == '/') {
          blockComment = false;
          i++;
        }
        continue;
      }
      if (quote != null) {
        if (c == '\\') {
          i++;
        } else if (c == quote) {
          quote = null;
        }
        continue;
      }
      if (c == '/' && next == '/') {
        lineComment = true;
        i++;
        continue;
      }
      if (c == '/' && next == '*') {
        blockComment = true;
        i++;
        continue;
      }
      if ({'"', "'", '`'}.contains(c)) {
        quote = c;
        continue;
      }
      if (c == '{') {
        parents[i] = List.of(stack);
        stack.add(i);
      }
      if (c == '}' && stack.isNotEmpty) ends[stack.removeLast()] = i;
    }
    String own(int start) {
      final end = ends[start]!;
      final out = StringBuffer();
      for (var i = start + 1; i < end; i++) {
        if (ends.containsKey(i)) {
          i = ends[i]!;
        } else {
          out.write(source[i]);
        }
      }
      return out.toString();
    }

    for (final start in ends.keys) {
      final object = own(start);
      if (!RegExp(r'''\bpath\s*:\s*['"]help['"]''').hasMatch(object)) continue;
      if ([start, ...parents[start]!].any(
        (p) => RegExp(
          r'\bcan(?:Activate|ActivateChild|Match|Load)\s*:',
        ).hasMatch(own(p)),
      )) {
        continue;
      }
      if (RegExp(r'component\s*:|loadComponent\s*:').hasMatch(object)) {
        return true;
      }
    }
    return false;
  }
}
