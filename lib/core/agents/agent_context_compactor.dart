/// Result of one deterministic agent-context compaction pass.
final class AgentContextCompaction {
  const AgentContextCompaction({
    required this.beforeCharacters,
    required this.afterCharacters,
    required this.transcriptItems,
    required this.observations,
    required this.fileExcerpts,
  });

  final int beforeCharacters;
  final int afterCharacters;
  final int transcriptItems;
  final int observations;
  final int fileExcerpts;

  bool get changed => transcriptItems + observations + fileExcerpts > 0;
}

/// Shrinks old run context without spending another model request.
///
/// Recent source excerpts remain exact so the agent can edit safely. Older
/// excerpts, searches and tool messages become short navigation notes instead
/// of disappearing or being sent in full on every iteration.
final class AgentContextCompactor {
  const AgentContextCompactor();

  static const triggerCharacters = 48000;
  static const targetCharacters = 34000;
  static const maxSummaryCharacters = 4200;
  static const maxSummaryItems = 24;

  AgentContextCompaction compact({
    required List<String> transcript,
    required Map<String, String> observations,
    required Map<String, String> activeFiles,
    required List<String> summary,
    int pinnedCharacters = 0,
  }) {
    int size() =>
        pinnedCharacters +
        transcript.fold<int>(0, (total, item) => total + item.length) +
        observations.entries.fold<int>(
          0,
          (total, item) => total + item.key.length + item.value.length,
        ) +
        activeFiles.entries.fold<int>(
          0,
          (total, item) => total + item.key.length + item.value.length,
        ) +
        summary.fold<int>(0, (total, item) => total + item.length);

    final before = size();
    if (before <= triggerCharacters) {
      return AgentContextCompaction(
        beforeCharacters: before,
        afterCharacters: before,
        transcriptItems: 0,
        observations: 0,
        fileExcerpts: 0,
      );
    }

    var compactedTranscript = 0;
    var compactedObservations = 0;
    var compactedFiles = 0;

    // Keep the newest three exact excerpts first. If the remaining context is
    // still too large, two and finally one exact excerpt remain available.
    for (final minimum in const [3, 2, 1]) {
      while (size() > targetCharacters && activeFiles.length > minimum) {
        final key = activeFiles.keys.first;
        activeFiles.remove(key);
        _remember(summary, 'Previously inspected: $key (exact text evicted).');
        compactedFiles++;
      }
    }

    while (size() > targetCharacters && observations.length > 2) {
      final key = observations.keys.first;
      final value = observations.remove(key)!;
      _remember(summary, _observationSummary(key, value));
      compactedObservations++;
    }

    while (size() > targetCharacters && transcript.length > 3) {
      final index = transcript.indexWhere((item) => !_pinned(item));
      if (index < 0) break;
      final removed = transcript.removeAt(index);
      final note = _transcriptSummary(removed);
      if (note != null) _remember(summary, note);
      compactedTranscript++;
    }

    _trimSummary(summary);
    return AgentContextCompaction(
      beforeCharacters: before,
      afterCharacters: size(),
      transcriptItems: compactedTranscript,
      observations: compactedObservations,
      fileExcerpts: compactedFiles,
    );
  }

  bool _pinned(String item) =>
      item.startsWith('Task:') ||
      item.startsWith('Phase:') ||
      item.startsWith('Memory note:') ||
      item.startsWith('Host note:');

  String _observationSummary(String key, String value) {
    final useful = value
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .skip(1)
        .take(3)
        .join(' | ');
    return useful.isEmpty
        ? 'Earlier observation: $key.'
        : 'Earlier observation: $key → ${_oneLine(useful, 280)}';
  }

  String? _transcriptSummary(String value) {
    const durablePrefixes = [
      'Tool replace_in_file result:',
      'Tool write_file result:',
      'Tool/action error:',
      'Tool blocked by hook:',
      'Assistant update:',
      'Normalized action:',
      'Context eviction:',
    ];
    if (!durablePrefixes.any(value.startsWith)) return null;
    return 'Earlier run state: ${_oneLine(value, 320)}';
  }

  void _remember(List<String> summary, String value) {
    final note = _oneLine(value, 360);
    summary.remove(note);
    summary.add(note);
    _trimSummary(summary);
  }

  void _trimSummary(List<String> summary) {
    int characters() => summary.fold(0, (total, item) => total + item.length);
    while (summary.length > maxSummaryItems ||
        characters() > maxSummaryCharacters) {
      summary.removeAt(0);
    }
  }

  String _oneLine(String value, int limit) {
    final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return compact.length <= limit
        ? compact
        : '${compact.substring(0, limit)}…';
  }
}
