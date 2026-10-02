import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// macOS App Sandbox: keep access to user-picked folders across relaunches.
class SecurityScopedRoots {
  SecurityScopedRoots._();

  static const _channel = MethodChannel('dev.tamtoot/bookmarks');
  static const _prefPrefix = 'tamtoot.bookmark.';
  static final _active = <String>{};

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static String _keyFor(Uri root) =>
      '$_prefPrefix${Uri.encodeComponent(_normalize(root))}';

  static String _normalize(Uri root) {
    var path = root.toFilePath();
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  /// Call right after the user picks a folder in an open panel.
  static Future<void> rememberPickedFolder(Uri root) async {
    if (!_supported) return;
    final path = _normalize(root);
    try {
      final bookmark = await _channel.invokeMethod<String>('createBookmark', {
        'path': path,
      });
      if (bookmark == null || bookmark.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyFor(root), bookmark);
      _active.add(path);
    } catch (_) {
      // Picker still grants access for this process; bookmark is best-effort.
    }
  }

  /// Restore sandbox access before listing/reading a previously opened project.
  static Future<void> ensureAccess(Uri root) async {
    if (!_supported) return;
    final path = _normalize(root);
    if (_active.contains(path)) return;
    final prefs = await SharedPreferences.getInstance();
    final bookmark = prefs.getString(_keyFor(root));
    if (bookmark == null || bookmark.isEmpty) {
      // Try creating a bookmark if this process already has access (same session).
      await rememberPickedFolder(root);
      return;
    }
    try {
      final resolved = await _channel.invokeMethod<String>('beginAccess', {
        'bookmark': bookmark,
      });
      if (resolved != null && resolved.isNotEmpty) {
        _active.add(path);
        if (resolved != path) {
          await prefs.setString(_keyFor(Uri.directory(resolved)), bookmark);
          _active.add(resolved);
        }
      }
    } catch (_) {
      await prefs.remove(_keyFor(root));
    }
  }

  static Future<void> release(Uri root) async {
    if (!_supported) return;
    final path = _normalize(root);
    if (!_active.remove(path)) return;
    try {
      await _channel.invokeMethod<void>('endAccess', {'path': path});
    } catch (_) {}
  }

  static bool looksLikeSandboxDenial(Object error) {
    final text = '$error';
    return text.contains('PathAccessException') ||
        text.contains('Operation not permitted') ||
        text.contains('errno = 1');
  }

  static String reopenHint(Uri root) =>
      'macOS blocked access to ${root.toFilePath()}. '
      'Use File → Open project… and pick the folder again '
      '(Finder grant is required after each app reinstall or sometimes after restart).';
}
