import '../core/git/git_service.dart';

/// Web stub — local clone checkout needs dart:io filesystem.
class PlatformGitService implements GitService {
  @override
  bool get available => false;

  Never _no() => throw UnsupportedError(
    'HTTP git client needs a local filesystem (not available on web).',
  );

  @override
  Future<GitResult> version() async => _no();
  @override
  Future<bool> isRepository(Uri directory) async => false;
  @override
  Future<GitResult> clone(
    Uri remote,
    Uri directory, {
    GitCredentials? credentials,
    String? branch,
    bool shallow = false,
  }) async => _no();
  @override
  Future<GitResult> fetch(
    Uri directory, {
    GitCredentials? credentials,
    String remote = 'origin',
  }) async => _no();
  @override
  Future<GitResult> pull(
    Uri directory, {
    GitCredentials? credentials,
    String remote = 'origin',
    String? branch,
  }) async => _no();
  @override
  Future<GitResult> push(
    Uri directory, {
    GitCredentials? credentials,
    String remote = 'origin',
    String? branch,
    bool setUpstream = false,
  }) async => _no();
  @override
  Future<GitResult> status(Uri directory, {bool porcelain = true}) async =>
      _no();
  @override
  Future<List<GitStatusEntry>> statusEntries(Uri directory) async => _no();
  @override
  Future<GitResult> add(
    Uri directory, {
    List<String> paths = const ['.'],
  }) async => _no();
  @override
  Future<GitResult> commit(
    Uri directory,
    String message, {
    bool allowEmpty = false,
  }) async => _no();
  @override
  Future<GitResult> remoteUrl(Uri directory, {String name = 'origin'}) async =>
      _no();
  @override
  Future<GitResult> setRemoteUrl(
    Uri directory,
    Uri url, {
    String name = 'origin',
    GitCredentials? credentials,
  }) async => _no();
}

GitService createGitService({String? gitExecutable}) => PlatformGitService();
