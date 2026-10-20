import 'model_client.dart';
import 'project_memory.dart';

/// Versions observed and produced by this run, independent of model claims.
class AgentEditState {
  final _read = <String, String>{};
  final _versions = <String, Set<String>>{};
  void observedVersion(String path, String version) {
    _read[path] = version;
    _versions.putIfAbsent(path, () => {}).add(version);
  }

  void read(String path, String content) {
    final version = ProjectMemory.fingerprintText(content);
    _read[path] = version;
    _versions.putIfAbsent(path, () => {}).add(version);
  }

  void validateRead(String path, String current) {
    if (_read[path] != ProjectMemory.fingerprintText(current)) {
      throw const ModelApiException(
        'Stale or unread file. Read its current contents before editing; no write was performed.',
      );
    }
  }

  void validate(String path, String current, String updated) {
    final currentVersion = ProjectMemory.fingerprintText(current);
    if (_read[path] != currentVersion) {
      throw const ModelApiException(
        'Stale or unread file. Read its current contents before editing; no write was performed.',
      );
    }
    if (current == updated) {
      throw const ModelApiException(
        'Duplicate edit: file already has this content.',
      );
    }
    if (_versions[path]?.contains(ProjectMemory.fingerprintText(updated)) ??
        false) {
      throw const ModelApiException(
        'Edit reversal detected: this restores an earlier version from the same run. Stop and report the unresolved requirement instead of undoing your changes.',
      );
    }
  }

  void wrote(String path, String content) {
    _versions
        .putIfAbsent(path, () => {})
        .add(ProjectMemory.fingerprintText(content));
  }
}
