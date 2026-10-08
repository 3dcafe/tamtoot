import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import '../ssh/ssh_client.dart';
import '../ssh/ssh_error.dart';
import '../ssh/transport/ssh_codec.dart';
import '../ssh/transport/ssh_transport.dart';

class SftpException extends SshException {
  const SftpException(super.message, {this.code});
  final int? code;
}

class SftpConflict extends SftpException {
  const SftpConflict(super.message, {this.recoveryPath});
  final String? recoveryPath;
}

class SftpAttributes {
  const SftpAttributes({
    this.size,
    this.permissions,
    this.modified,
    this.accessed,
    this.uid,
    this.gid,
  });
  final int? size, permissions, modified, accessed, uid, gid;
  bool get directory =>
      permissions != null && (permissions! & 0xf000) == 0x4000;
  bool get symlink => permissions != null && (permissions! & 0xf000) == 0xa000;
  bool get regular => permissions != null && (permissions! & 0xf000) == 0x8000;
}

class SftpEntry {
  const SftpEntry(this.name, this.attributes);
  final String name;
  final SftpAttributes attributes;
}

class SftpSnapshot {
  SftpSnapshot(this.path, List<int> bytes, this.attributes)
    : bytes = Uint8List.fromList(bytes);
  final String path;
  final Uint8List bytes;
  final SftpAttributes attributes;
}

class SftpCommit {
  const SftpCommit({this.backupPath});
  final String? backupPath;
}

class _SftpResponse {
  const _SftpResponse(this.type, this.reader);
  final int type;
  final SshReader reader;
}

/// SFTP v3; no process or filesystem access. A channel failure fails every request.
class SftpClient {
  SftpClient._(this.ssh);
  final SshClient ssh;
  SshExecChannel? _channel;
  final _cancel = SshCancellation();
  final _version = Completer<void>();
  final _pending = <int, Completer<_SftpResponse>>{};
  final extensions = <String, String>{};
  final _errors = StreamController<String>.broadcast();
  Stream<String> get errors => _errors.stream;
  bool _closed = false,
      _negotiated = false,
      _transferring = false,
      _uploading = false;
  int _nextId = 0, _headerBytes = 0, _packetBytes = 0, _length = 0;
  final _header = Uint8List(4);
  Uint8List? _packet;
  static const maxPacket = 256 * 1024,
      chunkSize = 32768,
      maxFileBytes = 32 * 1024 * 1024;
  bool get closed => _closed;
  static Future<SftpClient> connect(SshClient ssh) async {
    final client = SftpClient._(ssh);
    unawaited(
      client._version.future.then((_) {}, onError: (Object _, StackTrace _) {}),
    );
    try {
      client._channel = await ssh.openSubsystem(
        'sftp',
        cancellation: client._cancel,
        onOutput: (o) {
          if (!o.stderr) client._receive(o.data);
        },
      );
      unawaited(
        client._channel!.result.then(
          (_) => client._fail('SFTP channel closed.'),
          onError: (Object _) => client._fail('SFTP connection lost.'),
        ),
      );
      await client._channel!.writeStdin(
        _frame(
          (SshWriter()
                ..byte(1)
                ..uint32(3))
              .take(),
        ),
      );
      await client._version.future.timeout(const Duration(seconds: 30));
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  static Uint8List _frame(List<int> packet) =>
      (SshWriter()
            ..uint32(packet.length)
            ..raw(packet))
          .take();
  void _receive(List<int> bytes) {
    if (_closed) return;
    try {
      var offset = 0;
      while (offset < bytes.length && !_closed) {
        if (_packet == null) {
          while (_headerBytes < 4 && offset < bytes.length) {
            _header[_headerBytes++] = bytes[offset++];
          }
          if (_headerBytes < 4) return;
          _length = ByteData.sublistView(_header).getUint32(0);
          _headerBytes = 0;
          if (_length < 5 || _length > maxPacket) {
            throw const SftpException('Invalid SFTP packet size.');
          }
          _packet = Uint8List(_length);
          _packetBytes = 0;
        }
        final amount = min(_length - _packetBytes, bytes.length - offset);
        _packet!.setRange(_packetBytes, _packetBytes + amount, bytes, offset);
        offset += amount;
        _packetBytes += amount;
        if (_packetBytes == _length) {
          final packet = _packet!;
          _packet = null;
          _dispatch(packet);
        }
      }
    } catch (_) {
      _fail('Malformed SFTP response.');
    }
  }

  void _dispatch(Uint8List packet) {
    final r = SshReader(packet), type = r.byte();
    if (!_negotiated) {
      if (type != 2 || r.uint32() != 3) {
        throw const SftpException('Server must support SFTP version 3.');
      }
      while (r.remaining > 0) {
        if (extensions.length >= 32) {
          throw const SftpException('SFTP extension limit exceeded.');
        }
        final name = r.asciiText(limit: 256),
            value = utf8.decode(r.string(limit: 4096));
        if (extensions.containsKey(name)) {
          throw const SftpException('Duplicate SFTP extension.');
        }
        extensions[name] = value;
      }
      _negotiated = true;
      _version.complete();
      return;
    }
    if (type < 101 || type > 105 && type != 201) {
      throw const SftpException('Unsupported SFTP response.');
    }
    final id = r.uint32(), pending = _pending.remove(id);
    if (pending == null) {
      throw const SftpException('Unknown SFTP request identifier.');
    }
    pending.complete(_SftpResponse(type, r));
  }

  void _fail(String message) {
    if (_closed) return;
    _closed = true;
    _packet = null;
    if (!_version.isCompleted) _version.completeError(SftpException(message));
    for (final p in _pending.values) {
      if (!p.isCompleted) p.completeError(SftpException(message));
    }
    _pending.clear();
    _errors.add(message);
    unawaited(_errors.close());
    _cancel.cancel();
    unawaited(_channel?.cancel());
  }

  Future<void> close() async {
    _fail('SFTP session closed.');
    await _channel?.cancel();
  }

  Future<_SftpResponse> _request(int type, SshWriter fields) async {
    if (_closed || !_negotiated) {
      throw const SftpException('SFTP is disconnected.');
    }
    if (_pending.length >= 8 || _nextId > 0xffffffff) {
      throw const SftpException('SFTP concurrent request limit reached.');
    }
    final id = _nextId++, pending = Completer<_SftpResponse>();
    _pending[id] = pending;
    unawaited(
      pending.future.then((_) {}, onError: (Object _, StackTrace _) {}),
    );
    try {
      final packet =
          (SshWriter()
                ..byte(type)
                ..uint32(id)
                ..raw(fields.take()))
              .take();
      if (packet.length > maxPacket) {
        throw const SftpException('SFTP request exceeds limit.');
      }
      await _channel!.writeStdin(_frame(packet));
      return await pending.future.timeout(const Duration(seconds: 30));
    } catch (e) {
      _pending.remove(id);
      _fail('SFTP request failed or timed out.');
      rethrow;
    }
  }

  T _decode<T>(_SftpResponse response, T Function(int, SshReader) decode) {
    try {
      return decode(response.type, response.reader);
    } on SftpException {
      rethrow;
    } catch (_) {
      _fail('Malformed SFTP response body.');
      throw const SftpException('Malformed SFTP response body.');
    }
  }

  int _status(SshReader r, {bool eof = false}) {
    final code = r.uint32();
    r.string(limit: 8192);
    r.string(limit: 128);
    r.end();
    if (code != 0 && !(eof && code == 1)) {
      throw SftpException(switch (code) {
        2 => 'Remote path does not exist.',
        3 => 'Remote permission denied.',
        4 => 'Remote operation failed.',
        8 => 'Remote operation is unsupported.',
        _ => 'SFTP server rejected the operation.',
      }, code: code);
    }
    return code;
  }

  void _ok(_SftpResponse response) => _decode(response, (type, r) {
    if (type != 101) throw const FormatException('Expected status.');
    _status(r);
  });
  static void validatePath(String path) {
    if (path.isEmpty ||
        path.contains('\x00') ||
        utf8.encode(path).length > 16384) {
      throw const SftpException('Invalid remote path.');
    }
  }

  static String join(String directory, String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\x00')) {
      throw const SftpException('Invalid remote filename.');
    }
    final result = directory == '/'
        ? '/$name'
        : '${directory.replaceFirst(RegExp(r'/+$'), '')}/$name';
    validatePath(result);
    return result;
  }

  static String parent(String path) {
    validatePath(path);
    final absolute = path.startsWith('/');
    path = path.replaceFirst(RegExp(r'/+$'), '');
    if (path.isEmpty && absolute) return '/';
    final slash = path.lastIndexOf('/');
    return slash < 0
        ? '.'
        : slash == 0
        ? '/'
        : path.substring(0, slash);
  }

  static String basename(String path) =>
      path.replaceFirst(RegExp(r'/+$'), '').split('/').last;
  SshWriter _path(String path) {
    validatePath(path);
    return SshWriter()..text(path);
  }

  static int _uint64(SshReader r) {
    final high = r.uint32(), low = r.uint32();
    if (high > 0x1fffff) {
      throw const FormatException('Remote size exceeds exact integer range.');
    }
    return high * 0x100000000 + low;
  }

  static SshWriter _offset(SshWriter w, int value) {
    if (value < 0 || value > 9007199254740991) {
      throw const SftpException('Invalid file offset.');
    }
    return w
      ..uint32(value ~/ 0x100000000)
      ..uint32(value % 0x100000000);
  }

  static SftpAttributes _attributes(SshReader r) {
    final flags = r.uint32();
    if (flags & ~0x8000000f != 0) {
      throw const FormatException('Unknown attributes.');
    }
    int? size, uid, gid, permissions, accessed, modified;
    if (flags & 1 != 0) size = _uint64(r);
    if (flags & 2 != 0) {
      uid = r.uint32();
      gid = r.uint32();
    }
    if (flags & 4 != 0) permissions = r.uint32();
    if (flags & 8 != 0) {
      accessed = r.uint32();
      modified = r.uint32();
    }
    if (flags & 0x80000000 != 0) {
      final count = r.uint32();
      if (count > 32) throw const FormatException('Attribute extension limit.');
      for (var i = 0; i < count; i++) {
        r.string(limit: 256);
        r.string(limit: 4096);
      }
    }
    return SftpAttributes(
      size: size,
      uid: uid,
      gid: gid,
      permissions: permissions,
      accessed: accessed,
      modified: modified,
    );
  }

  Future<SftpAttributes> stat(String path, {bool followLinks = false}) async =>
      _decode(await _request(followLinks ? 17 : 7, _path(path)), (type, r) {
        if (type == 101) _status(r);
        if (type != 105) throw const FormatException('Expected attributes.');
        final value = _attributes(r);
        r.end();
        return value;
      });
  Future<SftpAttributes?> tryStat(String path) async {
    try {
      return await stat(path);
    } on SftpException catch (e) {
      if (e.code == 2) return null;
      rethrow;
    }
  }

  List<SftpEntry> _names(_SftpResponse response) =>
      _decode(response, (type, r) {
        if (type == 101) {
          _status(r, eof: true);
          return <SftpEntry>[];
        }
        if (type != 104) throw const FormatException('Expected names.');
        final count = r.uint32();
        if (count > 4096) throw const FormatException('Directory page limit.');
        final entries = <SftpEntry>[];
        for (var i = 0; i < count; i++) {
          final name = utf8.decode(r.string(limit: 16384));
          r.string(limit: 16384);
          entries.add(SftpEntry(name, _attributes(r)));
        }
        r.end();
        return entries;
      });
  Future<String> realpath(String path) async {
    final names = _names(await _request(16, _path(path)));
    if (names.length != 1) {
      throw const SftpException('Invalid canonical remote path.');
    }
    validatePath(names.single.name);
    return names.single.name;
  }

  Future<String> readlink(String path) async {
    final names = _names(await _request(19, _path(path)));
    if (names.length != 1) throw const SftpException('Invalid link response.');
    return names.single.name;
  }

  Uint8List _handle(_SftpResponse response) => _decode(response, (type, r) {
    if (type == 101) _status(r);
    if (type != 102) throw const FormatException('Expected handle.');
    final handle = Uint8List.fromList(r.string(limit: 256));
    r.end();
    if (handle.isEmpty) throw const FormatException('Empty handle.');
    return handle;
  });
  Future<void> _closeHandle(List<int> handle) async =>
      _ok(await _request(4, SshWriter()..string(handle)));
  Future<List<SftpEntry>> list(String path) async {
    final handle = _handle(await _request(11, _path(path)));
    final entries = <SftpEntry>[];
    try {
      for (var page = 0; page < 1024; page++) {
        final response = await _request(12, SshWriter()..string(handle));
        if (response.type == 101) {
          final code = _decode(response, (_, r) => _status(r, eof: true));
          if (code == 1) return entries;
          throw const SftpException('Directory listing made no progress.');
        }
        final batch = _names(response);
        if (batch.isEmpty) {
          throw const SftpException('Directory listing made no progress.');
        }
        for (final entry in batch) {
          if (entry.name == '.' || entry.name == '..') continue;
          if (entry.name.contains('/') || entry.name.contains('\x00')) {
            throw const SftpException('Invalid directory entry.');
          }
          entries.add(entry);
        }
        if (entries.length > 10000) {
          throw const SftpException('Directory exceeds 10000 entries.');
        }
      }
      throw const SftpException('Directory pagination limit reached.');
    } finally {
      if (!_closed) await _closeHandle(handle);
    }
  }

  Future<void> mkdir(String path) async => _ok(
    await _request(
      14,
      _path(path)
        ..uint32(4)
        ..uint32(0x1c0),
    ),
  );
  Future<void> remove(String path, {bool directory = false}) async =>
      _ok(await _request(directory ? 15 : 13, _path(path)));
  Future<void> rename(String oldPath, String newPath) async {
    validatePath(newPath);
    _ok(await _request(18, _path(oldPath)..text(newPath)));
  }

  Future<Uint8List> _openRead(String path) async => _handle(
    await _request(
      3,
      _path(path)
        ..uint32(1)
        ..uint32(0),
    ),
  );
  Future<int> download(
    String path,
    Future<void> Function(Uint8List) sink, {
    int maxBytes = maxFileBytes,
    SshCancellation? cancellation,
    void Function(int, int?)? progress,
  }) async {
    if (_transferring) {
      throw const SftpException('Another SFTP transfer is running.');
    }
    _transferring = true;
    final finish = _watchCancellation(cancellation);
    Uint8List? handle;
    try {
      _checkCancel(cancellation);
      final attrs = await stat(path, followLinks: true);
      if (attrs.directory || attrs.size != null && attrs.size! > maxBytes) {
        throw const SftpException('File type or transfer size exceeds limit.');
      }
      handle = await _openRead(path);
      var offset = 0;
      while (true) {
        _checkCancel(cancellation);
        final response = await _request(
          5,
          _offset(SshWriter()..string(handle), offset)..uint32(chunkSize),
        );
        if (response.type == 101) {
          final code = _decode(response, (_, r) => _status(r, eof: true));
          if (code != 1) {
            throw const SftpException('File read made no progress.');
          }
          break;
        }
        final data = _decode(response, (type, r) {
          if (type != 103) throw const FormatException('Expected file data.');
          final data = Uint8List.fromList(r.string(limit: chunkSize));
          r.end();
          return data;
        });
        if (data.isEmpty) {
          throw const SftpException('File read made no progress.');
        }
        if (offset + data.length > maxBytes) {
          throw const SftpException('Transfer exceeded size limit.');
        }
        _checkCancel(cancellation);
        await sink(data);
        offset += data.length;
        progress?.call(offset, attrs.size);
      }
      _checkCancel(cancellation);
      await _closeHandle(handle);
      handle = null;
      final after = await stat(path, followLinks: true);
      if (attrs.size != null && offset != attrs.size ||
          attrs.size != after.size ||
          attrs.modified != after.modified) {
        throw const SftpConflict('Remote file changed during download.');
      }
      _checkCancel(cancellation);
      progress?.call(offset, offset);
      return offset;
    } finally {
      if (handle != null && !_closed) {
        try {
          await _closeHandle(handle);
        } catch (_) {}
      }
      _transferring = false;
      finish();
    }
  }

  void _checkCancel(SshCancellation? cancellation) {
    if (cancellation?.cancelled == true) {
      throw const SftpException('SFTP transfer cancelled.');
    }
    if (_closed) throw const SftpException('SFTP is disconnected.');
  }

  Future<Uint8List> readFile(
    String path, {
    int maxBytes = maxFileBytes,
    SshCancellation? cancellation,
    void Function(int, int?)? progress,
  }) async {
    final output = BytesBuilder(copy: false);
    await download(
      path,
      (bytes) async => output.add(bytes),
      maxBytes: maxBytes,
      cancellation: cancellation,
      progress: progress,
    );
    return output.takeBytes();
  }

  Future<SftpSnapshot> snapshot(
    String path, {
    int maxBytes = 2 * 1024 * 1024,
  }) async {
    final attrs = await stat(path);
    if (!attrs.regular) {
      throw const SftpException(
        'Editing requires a regular file, not a symbolic link.',
      );
    }
    final bytes = await readFile(path, maxBytes: maxBytes);
    return SftpSnapshot(path, bytes, attrs);
  }

  bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _validateSnapshot(SftpSnapshot expected, String path) async {
    final attrs = await stat(path);
    if (!attrs.regular ||
        attrs.size != expected.attributes.size ||
        attrs.modified != expected.attributes.modified ||
        attrs.permissions != expected.attributes.permissions) {
      throw const SftpConflict('Remote file changed. Reload before saving.');
    }
    final current = await readFile(path, maxBytes: maxFileBytes);
    if (!_sameBytes(current, expected.bytes)) {
      throw const SftpConflict(
        'Remote contents changed. Reload before saving.',
      );
    }
  }

  String _temporary(String path, String kind) {
    final random = ssh.transport.crypto
        .randomBytes(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return join(parent(path), '.tamtoot-$kind-$random');
  }

  /// Existing files are moved to a recovery backup, checked, then replaced with
  /// a non-overwriting rename. The backup remains; no server-side CAS is claimed.
  Future<SftpCommit> upload(
    String path,
    Stream<List<int>> source, {
    required int length,
    SftpSnapshot? expected,
    SshCancellation? cancellation,
    void Function(int, int?)? progress,
  }) async {
    if (_uploading || _transferring) {
      throw const SftpException('Another SFTP transfer is running.');
    }
    _uploading = true;
    final finish = _watchCancellation(cancellation);
    try {
      return await _upload(
        path,
        source,
        length: length,
        expected: expected,
        cancellation: cancellation,
        progress: progress,
      );
    } finally {
      _uploading = false;
      finish();
    }
  }

  void Function() _watchCancellation(SshCancellation? token) {
    var active = true;
    if (token != null) {
      unawaited(
        token.whenCancelled.then((_) {
          if (active) _fail('SFTP transfer cancelled.');
        }),
      );
    }
    return () => active = false;
  }

  Future<SftpCommit> _upload(
    String path,
    Stream<List<int>> source, {
    required int length,
    SftpSnapshot? expected,
    SshCancellation? cancellation,
    void Function(int, int?)? progress,
  }) async {
    validatePath(path);
    if (length < 0 || length > maxFileBytes) {
      throw const SftpException('Upload exceeds 32 MiB.');
    }
    if (expected != null && expected.path != path) {
      throw const SftpException('Snapshot refers to another remote path.');
    }
    if (expected != null) {
      await _validateSnapshot(expected, path);
    } else if (await tryStat(path) != null) {
      throw const SftpConflict(
        'Remote path exists. Confirm replacement first.',
      );
    }
    final temp = _temporary(path, 'upload');
    Uint8List? handle;
    String? backup;
    var moved = false, committed = false, created = false;
    try {
      _checkCancel(cancellation);
      if (_transferring) {
        throw const SftpException('Another SFTP transfer is running.');
      }
      _transferring = true;
      handle = _handle(
        await _request(
          3,
          _path(temp)
            ..uint32(2 | 8 | 32)
            ..uint32(4)
            ..uint32(
              expected == null
                  ? 0x180
                  : expected.attributes.permissions! & 0x1ff,
            ),
        ),
      );
      created = true;
      if (expected != null) {
        _ok(
          await _request(
            10,
            SshWriter()
              ..string(handle)
              ..uint32(4)
              ..uint32(expected.attributes.permissions! & 0x1ff),
          ),
        );
      }
      var offset = 0;
      final iterator = StreamIterator<List<int>>(source);
      try {
        while (await (cancellation == null
            ? iterator.moveNext().timeout(const Duration(seconds: 30))
            : Future.any<bool>([
                iterator.moveNext().timeout(const Duration(seconds: 30)),
                cancellation.whenCancelled.then(
                  (_) => throw const SftpException('SFTP transfer cancelled.'),
                ),
              ]))) {
          final part = iterator.current;
          for (var index = 0; index < part.length; index += chunkSize) {
            _checkCancel(cancellation);
            final end = min(part.length, index + chunkSize);
            if (offset + end - index > length) {
              throw const SftpException('Upload source size changed.');
            }
            _ok(
              await _request(
                6,
                _offset(SshWriter()..string(handle), offset)
                  ..string(part.sublist(index, end)),
              ),
            );
            offset += end - index;
            progress?.call(offset, length);
          }
        }
      } finally {
        await iterator.cancel();
      }
      if (offset != length) {
        throw const SftpException('Upload source size changed.');
      }
      _checkCancel(cancellation);
      if (extensions['fsync@openssh.com'] == '1') {
        _ok(
          await _request(
            200,
            SshWriter()
              ..text('fsync@openssh.com')
              ..string(handle),
          ),
        );
      }
      await _closeHandle(handle);
      handle = null;
      _transferring = false;
      if (expected != null) {
        await _validateSnapshot(expected, path);
        _checkCancel(cancellation);
        backup = _temporary(path, 'backup');
        await rename(path, backup);
        moved = true;
        try {
          await _validateSnapshot(expected, backup);
        } catch (_) {
          throw SftpConflict(
            'Remote file changed; replacement stopped.',
            recoveryPath: backup,
          );
        }
      }
      _checkCancel(cancellation);
      await rename(temp, path);
      committed = true;
      _checkCancel(cancellation);
      progress?.call(length, length);
      return SftpCommit(backupPath: backup);
    } catch (e) {
      if (moved && !committed && _closed) {
        throw SftpConflict(
          'Connection lost during replacement. Check the destination and recovery copy.',
          recoveryPath: backup,
        );
      }
      if (moved && !committed && !_closed) {
        try {
          await rename(backup!, path);
          moved = false;
        } catch (_) {
          throw SftpConflict(
            'Replacement failed. Original retained at $backup.',
            recoveryPath: backup,
          );
        }
      }
      if (e is SftpConflict && e.recoveryPath != null && !moved) {
        throw const SftpConflict(
          'Conflict detected. Original restored; reload before saving.',
        );
      }
      rethrow;
    } finally {
      _transferring = false;
      if (handle != null && !_closed) {
        try {
          await _closeHandle(handle);
        } catch (_) {}
      }
      if (created && !committed && !_closed) {
        try {
          await remove(temp);
        } catch (_) {}
      }
    }
  }

  Future<SftpCommit> writeFile(
    String path,
    List<int> bytes, {
    SftpSnapshot? expected,
    SshCancellation? cancellation,
    void Function(int, int?)? progress,
  }) => upload(
    path,
    Stream.value(bytes),
    length: bytes.length,
    expected: expected,
    cancellation: cancellation,
    progress: progress,
  );
}
