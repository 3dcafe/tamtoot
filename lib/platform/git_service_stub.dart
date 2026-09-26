import '../core/git/git_service.dart';
import '../core/git/http_git_service.dart';
import 'git_shared.dart';
import 'web_directory_web.dart';
import 'workspace_roots.dart';

/// Browser git client: Smart HTTP + real local folder (File System Access API).
class PlatformGitService extends HttpGitService {
  PlatformGitService()
    : super(
        transport: PackageHttpTransport(),
        openStore: (uri) {
          final existing = WorkspaceRoots.storeFor(uri);
          if (existing != null) return existing;
          throw StateError(
            'Choose a local folder first (browser File System Access).',
          );
        },
        inflateAt: sharedInflateAt,
        deflate: sharedDeflate,
      );

  @override
  bool get available => webDirectoryPickerSupported;

  @override
  Future<GitResult> version() async => const GitResult(
    exitCode: 0,
    stdout:
        'tamtoot-http-git 0.1 (web · local folder via File System Access API)',
    stderr: '',
    arguments: ['version'],
  );

  @override
  Future<GitResult> clone(
    Uri remote,
    Uri directory, {
    GitCredentials? credentials,
    String? branch,
    bool shallow = false,
  }) async {
    if (WorkspaceRoots.storeFor(directory) == null) {
      return const GitResult(
        exitCode: 1,
        stdout: '',
        stderr:
            'No local folder selected. Use Browse to choose where to save the clone.',
        arguments: ['clone'],
      );
    }
    return super.clone(
      remote,
      directory,
      credentials: credentials,
      branch: branch,
      shallow: shallow,
    );
  }
}

GitService createGitService({String? gitExecutable}) => PlatformGitService();
