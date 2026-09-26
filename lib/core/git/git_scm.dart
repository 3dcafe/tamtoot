import '../extensions/plugin_api.dart';
import 'git_service.dart';

/// Adapts [GitService] to the extension [ScmService] surface.
class GitScmService implements ScmService {
  GitScmService(this.git);
  final GitService git;

  @override
  Future<List<Uri>> changedFiles(Uri workspace) async {
    if (!git.available || !await git.isRepository(workspace)) {
      return const [];
    }
    final entries = await git.statusEntries(workspace);
    return [
      for (final entry in entries.where((e) => e.isChanged))
        workspace.resolve(entry.path),
    ];
  }
}
