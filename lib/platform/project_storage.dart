import 'package:flutter/foundation.dart';

/// Storage policy is based on the platform, not picker availability.
bool get usesManagedProjectStorage =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Names must be a single portable directory component.
String? projectNameError(String name) {
  if (name.isEmpty) return 'Enter a project name';
  if (name == '.' ||
      name == '..' ||
      RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(name) ||
      name.endsWith('.') ||
      name.endsWith(' ')) {
    return 'Use a folder name without path separators or special characters';
  }
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    return 'This folder name is reserved on Windows';
  }
  return null;
}
