import 'dart:convert';

import '../git/git_store.dart';

/// Compact persistent knowledge for one Tamtoot project (not a chat log).
class ProjectMemory {
  ProjectMemory({
    List<ProjectMemoryArea>? areas,
    List<ProjectMemoryEdit>? recentEdits,
  }) : areas = List.of(areas ?? const []),
       recentEdits = List.of(recentEdits ?? const []);

  final List<ProjectMemoryArea> areas;
  final List<ProjectMemoryEdit> recentEdits;

  /// Rough character budget for the on-disk document (~2k tokens).
  static const int maxDocumentCharacters = 8000;

  /// Budget for the slice injected into one model prompt.
  static const int maxPromptCharacters = 1800;

  static const int maxAreas = 12;
  static const int maxRecentEdits = 8;
  static const int maxLearnedPerArea = 6;
  static const int maxFilesPerArea = 6;
  static const int maxChangesPerArea = 4;

  static const storePath = '.tamtoot/agents/project_memory.json';

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'areas': areas.map((area) => area.toJson()).toList(),
    'recentEdits': recentEdits.map((edit) => edit.toJson()).toList(),
  };

  String encode() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

  factory ProjectMemory.parse(String source) {
    final data = jsonDecode(source);
    if (data is! Map<String, dynamic> || data['schemaVersion'] != 1) {
      throw const FormatException('Unsupported project memory schema.');
    }
    final areasRaw = data['areas'];
    final editsRaw = data['recentEdits'];
    return ProjectMemory(
      areas: areasRaw is List
          ? [
              for (final item in areasRaw)
                if (item is Map<String, dynamic>) ProjectMemoryArea.parse(item),
            ]
          : const [],
      recentEdits: editsRaw is List
          ? [
              for (final item in editsRaw)
                if (item is Map<String, dynamic>) ProjectMemoryEdit.parse(item),
            ]
          : const [],
    ).._normalize();
  }

  int get characterCount => encode().length;

  /// Token-ish estimate used only for diagnostics (≈4 chars / token).
  int get estimatedTokens => (characterCount / 4).round();

  void _normalize() {
    for (final area in areas) {
      area.learned = _uniqueBounded(
        area.learned.map(scrubSecrets).where((s) => s.trim().isNotEmpty),
        maxLearnedPerArea,
      );
      area.lastChanges = _uniqueBounded(
        area.lastChanges.map(scrubSecrets).where((s) => s.trim().isNotEmpty),
        maxChangesPerArea,
      );
      area.files = _uniqueBounded(area.files.where(_safePath), maxFilesPerArea);
      area.title = scrubSecrets(area.title).trim();
      if (area.title.length > 80) {
        area.title = area.title.substring(0, 80);
      }
    }
    areas.removeWhere(
      (area) =>
          area.title.isEmpty &&
          area.files.isEmpty &&
          area.learned.isEmpty &&
          area.lastChanges.isEmpty,
    );
    while (areas.length > maxAreas) {
      areas.removeAt(0);
    }
    while (recentEdits.length > maxRecentEdits) {
      recentEdits.removeAt(0);
    }
  }

  /// Merge a task outcome into this memory and compact if needed.
  ProjectMemoryMergeResult mergeTask({
    required String task,
    required String summary,
    required Iterable<String> readPaths,
    required Iterable<String> editedPaths,
    required Map<String, String> fileFingerprints,
    required Iterable<String> learnedFacts,
    List<String> unresolved = const [],
  }) {
    final before = characterCount;
    final areaTitle = _areaTitleFor(task, summary, editedPaths, readPaths);
    ProjectMemoryArea? existing;
    for (final area in areas) {
      if (_similarTitle(area.title, areaTitle)) {
        existing = area;
        break;
      }
    }
    if (existing == null) {
      final touched = {...editedPaths, ...readPaths};
      for (final area in areas) {
        if (area.files.any(touched.contains)) {
          existing = area;
          break;
        }
      }
    }
    final target =
        existing ??
        ProjectMemoryArea(
          title: areaTitle,
          status: editedPaths.isEmpty ? 'investigated' : 'modified',
        );
    if (existing == null) {
      areas.add(target);
    } else if (areaTitle.length < existing.title.length) {
      // Prefer a shorter durable title when merging related work.
      existing.title = areaTitle;
    }

    for (final path in [...readPaths, ...editedPaths]) {
      if (!_safePath(path)) continue;
      if (!target.files.contains(path)) target.files.add(path);
      final fp = fileFingerprints[path];
      if (fp != null) target.fileFingerprints[path] = fp;
    }
    target.files = _uniqueBounded(target.files, maxFilesPerArea);

    final facts = [
      ...learnedFacts.map(scrubSecrets),
      if (summary.trim().isNotEmpty) scrubSecrets(_clip(summary.trim(), 160)),
      ...unresolved.map((item) => 'Unresolved: ${scrubSecrets(item)}'),
    ].where((item) => item.trim().isNotEmpty);
    target.learned = _uniqueBounded([
      ...facts,
      ...target.learned,
    ], maxLearnedPerArea);

    final changeNotes = [
      for (final path in editedPaths)
        if (_safePath(path)) '$path updated',
    ];
    target.lastChanges = _uniqueBounded([
      ...changeNotes,
      ...target.lastChanges,
    ], maxChangesPerArea);
    target.status = editedPaths.isEmpty
        ? (unresolved.isEmpty ? 'investigated' : 'unresolved')
        : (unresolved.isEmpty ? 'modified' : 'unresolved');
    target.updatedAtMs = DateTime.now().millisecondsSinceEpoch;

    for (final path in editedPaths) {
      if (!_safePath(path)) continue;
      recentEdits.removeWhere((edit) => edit.path == path);
      recentEdits.add(
        ProjectMemoryEdit(
          path: path,
          summary: scrubSecrets(
            _clip(
              summary.trim().isEmpty ? 'edited during agent task' : summary.trim(),
              120,
            ),
          ),
          fingerprint: fileFingerprints[path] ?? '',
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    while (recentEdits.length > maxRecentEdits) {
      recentEdits.removeAt(0);
    }

    // Fold oldest recent edits into the matching area, then drop them.
    while (recentEdits.length > 5) {
      final oldest = recentEdits.removeAt(0);
      ProjectMemoryArea foldInto = target;
      for (final area in areas) {
        if (area.files.contains(oldest.path)) {
          foldInto = area;
          break;
        }
      }
      foldInto.lastChanges = _uniqueBounded([
        '${oldest.path}: ${oldest.summary}',
        ...foldInto.lastChanges,
      ], maxChangesPerArea);
    }

    _normalize();
    final compacted = compactIfNeeded();
    return ProjectMemoryMergeResult(
      areaTitle: target.title,
      charactersBefore: before,
      charactersAfter: characterCount,
      compacted: compacted,
    );
  }

  bool compactIfNeeded() {
    if (characterCount <= maxDocumentCharacters) {
      _normalize();
      return false;
    }
    // Drop oldest areas first, then shrink learned lists.
    while (characterCount > maxDocumentCharacters && areas.length > 3) {
      areas.removeAt(0);
    }
    for (final area in areas) {
      if (characterCount <= maxDocumentCharacters) break;
      if (area.learned.length > 3) {
        area.learned = area.learned.take(3).toList();
      }
      if (area.lastChanges.length > 2) {
        area.lastChanges = area.lastChanges.take(2).toList();
      }
    }
    while (characterCount > maxDocumentCharacters && recentEdits.length > 2) {
      recentEdits.removeAt(0);
    }
    _normalize();
    return true;
  }

  /// Pick a compact, task-relevant slice for the next model prompt.
  ProjectMemorySelection selectRelevant(String task) {
    final tokens = _tokens(task);
    if (tokens.isEmpty && areas.isEmpty && recentEdits.isEmpty) {
      return const ProjectMemorySelection.empty();
    }

    final scoredAreas = <({ProjectMemoryArea area, int score})>[];
    for (final area in areas) {
      final score = _scoreText(
        tokens,
        [
          area.title,
          ...area.files,
          ...area.learned,
          ...area.lastChanges,
        ].join(' '),
      );
      if (score > 0) scoredAreas.add((area: area, score: score));
    }
    scoredAreas.sort((a, b) => b.score.compareTo(a.score));

    final scoredEdits = <({ProjectMemoryEdit edit, int score})>[];
    for (final edit in recentEdits) {
      final score = _scoreText(tokens, '${edit.path} ${edit.summary}');
      if (score > 0) scoredEdits.add((edit: edit, score: score));
    }
    scoredEdits.sort((a, b) => b.score.compareTo(a.score));

    final chosenAreas = scoredAreas.take(3).map((item) => item.area).toList();
    final chosenEdits = scoredEdits.take(4).map((item) => item.edit).toList();

    // If nothing scored but we have recent work, surface the newest area lightly.
    if (chosenAreas.isEmpty &&
        chosenEdits.isEmpty &&
        (areas.isNotEmpty || recentEdits.isNotEmpty)) {
      if (areas.isNotEmpty) chosenAreas.add(areas.last);
      if (recentEdits.isNotEmpty) {
        chosenEdits.addAll(recentEdits.reversed.take(2));
      }
    }

    return ProjectMemorySelection(
      areas: chosenAreas,
      recentEdits: chosenEdits,
    );
  }

  /// Build prompt text; [stalePaths] mark known locations that changed on disk.
  String formatForPrompt(
    ProjectMemorySelection selection, {
    Set<String> stalePaths = const {},
  }) {
    if (selection.isEmpty) return '';
    final out = StringBuffer('Relevant retained project knowledge:\n');
    out.writeln(
      'Treat this as a navigation hint, not guaranteed current truth. '
      'Verify the smallest relevant current excerpt before editing.',
    );
    for (final edit in selection.recentEdits) {
      final stale = stalePaths.contains(edit.path) ? ' (possibly stale)' : '';
      out.writeln('- Recent edit$stale: ${edit.path}: ${edit.summary}');
    }
    for (final area in selection.areas) {
      out.writeln('\nArea: ${area.title} [${area.status}]');
      if (area.files.isNotEmpty) {
        out.writeln('Files:');
        for (final path in area.files) {
          final stale = stalePaths.contains(path)
              ? ' (possibly stale — verify before editing)'
              : '';
          out.writeln('- $path$stale');
        }
      }
      if (area.learned.isNotEmpty) {
        out.writeln('Learned:');
        for (final item in area.learned) {
          out.writeln('- $item');
        }
      }
      if (area.lastChanges.isNotEmpty) {
        out.writeln('Last changes:');
        for (final item in area.lastChanges) {
          out.writeln('- $item');
        }
      }
    }
    var text = out.toString().trim();
    if (text.length > maxPromptCharacters) {
      text = '${text.substring(0, maxPromptCharacters)}\n… memory truncated';
    }
    return text;
  }

  /// Paths known from memory that may answer a search without re-scanning.
  List<String> knownPathsForQuery(String query) {
    final tokens = _tokens(query);
    if (tokens.isEmpty) return const [];
    final hits = <String>{};
    for (final area in areas) {
      final blob = [
        area.title,
        ...area.files,
        ...area.learned,
        ...area.lastChanges,
      ].join(' ').toLowerCase();
      if (tokens.every(blob.contains) ||
          tokens.where(blob.contains).length >= 2) {
        hits.addAll(area.files);
      }
    }
    for (final edit in recentEdits) {
      final blob = '${edit.path} ${edit.summary}'.toLowerCase();
      if (tokens.any(blob.contains)) hits.add(edit.path);
    }
    return hits.take(4).toList();
  }

  static String fingerprintBytes(List<int> bytes) {
    var hash = 2166136261;
    for (final b in bytes) {
      hash ^= b & 0xff;
      hash = (hash * 16777619) & 0xffffffff;
    }
    return '${bytes.length}:${hash.toRadixString(16)}';
  }

  static String fingerprintText(String text) =>
      fingerprintBytes(utf8.encode(text));

  static String scrubSecrets(String input) {
    var text = input;
    final patterns = <RegExp>[
      RegExp(
        r'(api[_-]?key|token|secret|password|authorization)\s*[:=]\s*\S+',
        caseSensitive: false,
      ),
      RegExp(r'bearer\s+[a-z0-9\-._~+/]+=*', caseSensitive: false),
      RegExp(r'sk-[a-zA-Z0-9]{10,}'),
      RegExp(r'ghp_[a-zA-Z0-9]{20,}'),
      RegExp(
        r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
      ),
    ];
    for (final pattern in patterns) {
      text = text.replaceAll(pattern, '[redacted]');
    }
    return text;
  }

  static bool _safePath(String path) {
    final value = path.trim();
    if (value.isEmpty || value.contains('..')) return false;
    if (value.startsWith('.git') || value.startsWith('.tamtoot')) return false;
    if (value.endsWith('.env') || value.contains('credentials')) return false;
    return true;
  }

  static List<String> _uniqueBounded(Iterable<String> items, int max) {
    final out = <String>[];
    for (final item in items) {
      final trimmed = item.trim();
      if (trimmed.isEmpty) continue;
      final clipped = _clip(trimmed, 180);
      if (out.any((existing) => existing.toLowerCase() == clipped.toLowerCase())) {
        continue;
      }
      out.add(clipped);
      if (out.length >= max) break;
    }
    return out;
  }

  static String _clip(String value, int max) =>
      value.length <= max ? value : '${value.substring(0, max - 1)}…';

  static Set<String> _tokens(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_./+-]+'), ' ')
        .split(' ')
        .where((token) => token.length >= 3)
        .toSet();
  }

  static int _scoreText(Set<String> tokens, String haystack) {
    if (tokens.isEmpty) return 0;
    final lower = haystack.toLowerCase();
    var score = 0;
    for (final token in tokens) {
      if (lower.contains(token)) score += token.length >= 6 ? 3 : 1;
    }
    return score;
  }

  static bool _similarTitle(String a, String b) {
    final na = a.toLowerCase().trim();
    final nb = b.toLowerCase().trim();
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb) return true;
    if (na.contains(nb) || nb.contains(na)) return true;
    final ta = _tokens(na);
    final tb = _tokens(nb);
    if (ta.isEmpty || tb.isEmpty) return false;
    final overlap = ta.intersection(tb).length;
    final smaller = ta.length < tb.length ? ta.length : tb.length;
    return overlap >= 1 && overlap / smaller >= 0.5;
  }

  static String _areaTitleFor(
    String task,
    String summary,
    Iterable<String> edited,
    Iterable<String> read,
  ) {
    final fromTask = task.trim();
    if (fromTask.isNotEmpty) {
      return _clip(fromTask.replaceAll(RegExp(r'\s+'), ' '), 60);
    }
    final paths = [...edited, ...read];
    if (paths.isNotEmpty) {
      final path = paths.first;
      final parts = path.split('/');
      if (parts.length >= 2) return '${parts[parts.length - 2]}/${parts.last}';
      return path;
    }
    return _clip(summary.trim().isEmpty ? 'general' : summary.trim(), 60);
  }
}

class ProjectMemoryArea {
  ProjectMemoryArea({
    required this.title,
    List<String> files = const [],
    List<String> learned = const [],
    List<String> lastChanges = const [],
    this.status = 'investigated',
    Map<String, String>? fileFingerprints,
    int? updatedAtMs,
  }) : files = List.of(files),
       learned = List.of(learned),
       lastChanges = List.of(lastChanges),
       fileFingerprints = Map.of(fileFingerprints ?? const {}),
       updatedAtMs = updatedAtMs ?? DateTime.now().millisecondsSinceEpoch;

  String title;
  List<String> files;
  List<String> learned;
  List<String> lastChanges;
  String status;
  final Map<String, String> fileFingerprints;
  int updatedAtMs;

  Map<String, dynamic> toJson() => {
    'title': title,
    'files': files,
    'learned': learned,
    'lastChanges': lastChanges,
    'status': status,
    'fileFingerprints': fileFingerprints,
    'updatedAtMs': updatedAtMs,
  };

  factory ProjectMemoryArea.parse(Map<String, dynamic> data) {
    List<String> strings(String key) {
      final raw = data[key];
      if (raw is! List) return [];
      return [
        for (final item in raw)
          if (item is String && item.trim().isNotEmpty) item.trim(),
      ];
    }

    final fingerprints = <String, String>{};
    final rawFp = data['fileFingerprints'];
    if (rawFp is Map) {
      rawFp.forEach((key, value) {
        if (key is String && value is String) fingerprints[key] = value;
      });
    }
    return ProjectMemoryArea(
      title: data['title'] is String ? (data['title'] as String).trim() : '',
      files: strings('files'),
      learned: strings('learned'),
      lastChanges: strings('lastChanges'),
      status: data['status'] is String ? data['status'] as String : 'investigated',
      fileFingerprints: fingerprints,
      updatedAtMs: data['updatedAtMs'] is int
          ? data['updatedAtMs'] as int
          : DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class ProjectMemoryEdit {
  const ProjectMemoryEdit({
    required this.path,
    required this.summary,
    this.fingerprint = '',
    required this.updatedAtMs,
  });

  final String path;
  final String summary;
  final String fingerprint;
  final int updatedAtMs;

  Map<String, dynamic> toJson() => {
    'path': path,
    'summary': summary,
    'fingerprint': fingerprint,
    'updatedAtMs': updatedAtMs,
  };

  factory ProjectMemoryEdit.parse(Map<String, dynamic> data) =>
      ProjectMemoryEdit(
        path: data['path'] is String ? data['path'] as String : '',
        summary: data['summary'] is String ? data['summary'] as String : '',
        fingerprint: data['fingerprint'] is String
            ? data['fingerprint'] as String
            : '',
        updatedAtMs: data['updatedAtMs'] is int
            ? data['updatedAtMs'] as int
            : 0,
      );
}

class ProjectMemorySelection {
  const ProjectMemorySelection({
    this.areas = const [],
    this.recentEdits = const [],
  });

  const ProjectMemorySelection.empty()
    : areas = const [],
      recentEdits = const [];

  final List<ProjectMemoryArea> areas;
  final List<ProjectMemoryEdit> recentEdits;

  bool get isEmpty => areas.isEmpty && recentEdits.isEmpty;
  int get areaCount => areas.length;
}

class ProjectMemoryMergeResult {
  const ProjectMemoryMergeResult({
    required this.areaTitle,
    required this.charactersBefore,
    required this.charactersAfter,
    required this.compacted,
  });

  final String areaTitle;
  final int charactersBefore;
  final int charactersAfter;
  final bool compacted;
}

class ProjectMemoryStore {
  ProjectMemoryStore(this.files);
  final GitRepositoryStore files;

  Future<ProjectMemory> load() async {
    try {
      await files.validateRegularFilePath(ProjectMemory.storePath);
      if (!await files.exists(ProjectMemory.storePath)) {
        return ProjectMemory();
      }
      return ProjectMemory.parse(await files.readText(ProjectMemory.storePath));
    } catch (_) {
      // Corrupt or unreadable memory must not block agent runs.
      return ProjectMemory();
    }
  }

  Future<void> save(ProjectMemory memory) async {
    memory.compactIfNeeded();
    await files.validateRegularFilePath(ProjectMemory.storePath);
    await files.writeText(ProjectMemory.storePath, memory.encode());
  }
}
