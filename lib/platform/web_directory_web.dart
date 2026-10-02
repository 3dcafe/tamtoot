import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../core/git/git_store.dart';
import 'workspace_roots.dart';

bool get webDirectoryPickerSupported =>
    globalContext.has('showDirectoryPicker');

Future<T> _awaitJs<T extends JSAny>(JSPromise promise) async {
  final value = await promise.toDart;
  return value as T;
}

Future<Uri?> pickWebWorkspaceDirectory({String? createChild}) async {
  if (!webDirectoryPickerSupported) return null;
  try {
    final picker = globalContext['showDirectoryPicker'] as JSFunction;
    final options = JSObject()..['mode'] = 'readwrite'.toJS;
    final root = await _awaitJs<JSObject>(
      picker.callAsFunction(null, options) as JSPromise,
    );
    var target = root;
    var label = (root.getProperty('name'.toJS)! as JSString).toDart;
    if (createChild != null && createChild.isNotEmpty) {
      final childOpts = JSObject()..['create'] = true.toJS;
      final getDir = root.getProperty('getDirectoryHandle'.toJS)! as JSFunction;
      target = await _awaitJs<JSObject>(
        getDir.callAsFunction(root, createChild.toJS, childOpts) as JSPromise,
      );
      label = createChild;
    }
    final uri = Uri(scheme: 'fsa', host: 'local', path: '/$label/');
    WorkspaceRoots.register(uri, WebDirectoryStore(target));
    return uri;
  } catch (_) {
    return null;
  }
}

final class WebDirectoryStore extends GitRepositoryStore {
  WebDirectoryStore(this.root);
  final JSObject root;

  Future<JSObject> _dir(String path, {bool create = false}) async {
    if (path.isEmpty) return root;
    var current = root;
    for (final part in path.split('/').where((p) => p.isNotEmpty)) {
      final getDir =
          current.getProperty('getDirectoryHandle'.toJS)! as JSFunction;
      if (create) {
        final opts = JSObject()..['create'] = true.toJS;
        current = await _awaitJs<JSObject>(
          getDir.callAsFunction(current, part.toJS, opts) as JSPromise,
        );
      } else {
        current = await _awaitJs<JSObject>(
          getDir.callAsFunction(current, part.toJS) as JSPromise,
        );
      }
    }
    return current;
  }

  (String, String) _split(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return ('', '');
    if (parts.length == 1) return ('', parts.single);
    return (parts.sublist(0, parts.length - 1).join('/'), parts.last);
  }

  @override
  Future<bool> exists(String path) async {
    try {
      final (dir, name) = _split(path);
      final parent = await _dir(dir);
      if (name.isEmpty) return true;
      try {
        final getFile = parent.getProperty('getFileHandle'.toJS)! as JSFunction;
        await _awaitJs<JSObject>(
          getFile.callAsFunction(parent, name.toJS) as JSPromise,
        );
        return true;
      } catch (_) {
        final getDir =
            parent.getProperty('getDirectoryHandle'.toJS)! as JSFunction;
        await _awaitJs<JSObject>(
          getDir.callAsFunction(parent, name.toJS) as JSPromise,
        );
        return true;
      }
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final (dir, name) = _split(path);
    final parent = await _dir(dir);
    final getFile = parent.getProperty('getFileHandle'.toJS)! as JSFunction;
    final fileHandle = await _awaitJs<JSObject>(
      getFile.callAsFunction(parent, name.toJS) as JSPromise,
    );
    final getFileFn = fileHandle.getProperty('getFile'.toJS)! as JSFunction;
    final file = await _awaitJs<web.File>(
      getFileFn.callAsFunction(fileHandle) as JSPromise,
    );
    final buffer = await file.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    final (dir, name) = _split(path);
    final parent = await _dir(dir, create: true);
    final opts = JSObject()..['create'] = true.toJS;
    final getFile = parent.getProperty('getFileHandle'.toJS)! as JSFunction;
    final fileHandle = await _awaitJs<JSObject>(
      getFile.callAsFunction(parent, name.toJS, opts) as JSPromise,
    );
    final createWritable =
        fileHandle.getProperty('createWritable'.toJS)! as JSFunction;
    final writable = await _awaitJs<JSObject>(
      createWritable.callAsFunction(fileHandle) as JSPromise,
    );
    final write = writable.getProperty('write'.toJS)! as JSFunction;
    final data = Uint8List.fromList(bytes);
    await _awaitJs<JSAny>(
      write.callAsFunction(writable, data.toJS) as JSPromise,
    );
    final close = writable.getProperty('close'.toJS)! as JSFunction;
    await _awaitJs<JSAny>(close.callAsFunction(writable) as JSPromise);
  }

  @override
  Future<void> delete(String path) async {
    final (dir, name) = _split(path);
    final parent = await _dir(dir);
    final remove = parent.getProperty('removeEntry'.toJS)! as JSFunction;
    await _awaitJs<JSAny>(
      remove.callAsFunction(parent, name.toJS) as JSPromise,
    );
  }

  @override
  Future<void> createDirectory(String path) async {
    await _dir(path, create: true);
  }

  @override
  Future<List<String>> listFiles(String dir) async {
    final handle = await _dir(dir);
    final out = <String>[];
    await _walk(
      handle,
      dir,
      out,
      includeMetadata: dir.startsWith('.tamtoot/') || dir.startsWith('.git/'),
    );
    return out;
  }

  Future<void> _walk(
    JSObject dir,
    String prefix,
    List<String> out, {
    bool includeMetadata = false,
  }) async {
    final valuesFn = dir.getProperty('values'.toJS);
    if (valuesFn == null) return;
    final iterator = (valuesFn as JSFunction).callAsFunction(dir);
    if (iterator == null) return;
    final iter = iterator as JSObject;
    final next = iter.getProperty('next'.toJS)! as JSFunction;
    while (true) {
      final result = await _awaitJs<JSObject>(
        next.callAsFunction(iter) as JSPromise,
      );
      final done = (result.getProperty('done'.toJS)! as JSBoolean).toDart;
      if (done) break;
      final entry = result.getProperty('value'.toJS);
      if (entry == null) continue;
      final entryObj = entry as JSObject;
      final name = (entryObj.getProperty('name'.toJS)! as JSString).toDart;
      final kindProp = entryObj.getProperty('kind'.toJS);
      final kind = kindProp != null
          ? (kindProp as JSString).toDart
          : (entryObj.has('getFile') ? 'file' : 'directory');
      final rel = prefix.isEmpty ? name : '$prefix/$name';
      if (kind == 'file') {
        if (includeMetadata ||
            (!rel.startsWith('.git') && !rel.startsWith('.tamtoot'))) {
          out.add(rel);
        }
      } else if (name != '.git' && name != '.tamtoot') {
        await _walk(entryObj, rel, out, includeMetadata: includeMetadata);
      }
    }
  }
}
