/// Independent flags: a file may be modified and also have unpublished commits.
class FileIndicators {
  const FileIndicators({
    this.unsaved = false,
    this.modified = false,
    this.untracked = false,
    this.unpublished = false,
  });
  final bool unsaved, modified, untracked, unpublished;
  bool get any => unsaved || modified || untracked || unpublished;
  String get badge => [
    if (unsaved) '●',
    if (modified) 'M',
    if (untracked) '?',
    if (unpublished) '↑',
  ].join(' ');
  String get description => [
    if (unsaved) 'Unsaved changes',
    if (modified) 'Modified in Git',
    if (untracked) 'Untracked file',
    if (unpublished) 'Unpublished commits (locally known upstream)',
  ].join(' · ');
  String get colorToken => unsaved || modified
      ? 'scm.modified'
      : untracked
      ? 'scm.untracked'
      : 'scm.unpublished';
}
