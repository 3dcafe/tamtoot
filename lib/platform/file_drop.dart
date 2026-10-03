import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef FileDropListener = bool Function(List<String> paths);

/// Routes native file drops to whichever UI currently accepts them.
final class FileDropService {
  FileDropService._();

  static const _channel = MethodChannel('dev.tamtoot/file_drop');
  static final _listeners = <int, FileDropListener>{};
  static var _nextId = 0;
  static var _initialized = false;

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  static VoidCallback listen(FileDropListener listener) {
    if (isSupported && !_initialized) {
      _initialized = true;
      _channel.setMethodCallHandler(_handleCall);
    }
    final id = _nextId++;
    _listeners[id] = listener;
    return () => _listeners.remove(id);
  }

  static Future<void> _handleCall(MethodCall call) async {
    if (call.method != 'filesDropped') return;
    final paths =
        (call.arguments as List?)
            ?.whereType<String>()
            .where((path) => path.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    if (paths.isEmpty) return;
    final listeners = List<FileDropListener>.of(_listeners.values);
    for (final listener in listeners.reversed) {
      if (listener(paths)) break;
    }
  }
}
