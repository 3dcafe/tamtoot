import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/ssh/ssh_client.dart';
import 'package:tamtoot/core/ssh/transport/ssh_codec.dart';
import 'ssh_client_support.dart';
import 'ssh_client_protocol_test.dart' show ready;

class SftpTestPeer {
  final wire = ProtocolTransport();
  late SshClient ssh;
  final files = <String, List<int>>{
    '/home/text.txt': utf8.encode('original'),
    '/home/binary.bin': [0, 255, 7],
  };
  final folders = {'/', '/home'};
  final links = <String, String>{};
  final _handles = <String, String>{}, _listed = <String>{};
  final _buffer = <int>[];
  final requests = <int>[];
  final held = <List<int>>[];
  void Function(String, String)? beforeRename;
  bool holdStats = false,
      malformedVersion = false,
      fragment = false,
      refuse = false;
  int _handleId = 0, subsystems = 0;
  Future<void> start() async {
    ssh = await ready(wire);
    wire.onSend = (bytes) {
      final r = SshReader(bytes), type = r.byte();
      if (type == 90) {
        r.asciiText();
        final local = r.uint32();
        wire.emit(
          (SshWriter()
                ..byte(91)
                ..uint32(local)
                ..uint32(7)
                ..uint32(262144)
                ..uint32(32768))
              .take(),
        );
      } else if (type == 98) {
        r.uint32();
        expect(r.asciiText(), 'subsystem');
        expect(r.boolean(), true);
        expect(r.asciiText(), 'sftp');
        r.end();
        subsystems++;
        wire.emit(
          (SshWriter()
                ..byte(refuse ? 100 : 99)
                ..uint32(0))
              .take(),
        );
      } else if (type == 94) {
        r.uint32();
        _buffer.addAll(r.string());
        _parse();
      } else if (type == 97) {
        wire.emit(
          (SshWriter()
                ..byte(97)
                ..uint32(0))
              .take(),
        );
      }
    };
  }

  String path(String path) {
    final parts = <String>[];
    for (final piece in (path.startsWith('/') ? path : '/home/$path').split(
      '/',
    )) {
      if (piece.isEmpty || piece == '.') continue;
      if (piece == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(piece);
      }
    }
    return '/${parts.join('/')}';
  }

  void _parse() {
    while (_buffer.length >= 4) {
      final length = ByteData.sublistView(
        Uint8List.fromList(_buffer.take(4).toList()),
      ).getUint32(0);
      if (_buffer.length < length + 4) return;
      final bytes = _buffer.sublist(4, length + 4);
      _buffer.removeRange(0, length + 4);
      _request(SshReader(bytes));
    }
  }

  SshWriter attrs(String name, {bool follow = false}) {
    if (follow && links.containsKey(name)) name = links[name]!;
    final size = files[name]?.length ?? 0,
        mode = links.containsKey(name)
            ? 0xa1ff
            : folders.contains(name)
            ? 0x41c0
            : 0x81a4;
    return SshWriter()
      ..uint32(1 | 4 | 8)
      ..uint32(0)
      ..uint32(size)
      ..uint32(mode)
      ..uint32(1)
      ..uint32(1);
  }

  void send(List<int> payload) {
    final frame =
        (SshWriter()
              ..uint32(payload.length)
              ..raw(payload))
            .take();
    if (fragment) {
      for (final byte in frame) {
        wire.emit(
          (SshWriter()
                ..byte(94)
                ..uint32(0)
                ..string([byte]))
              .take(),
        );
      }
    } else {
      wire.emit(
        (SshWriter()
              ..byte(94)
              ..uint32(0)
              ..string(frame))
            .take(),
      );
    }
  }

  void status(int id, int code) => send(
    (SshWriter()
          ..byte(101)
          ..uint32(id)
          ..uint32(code)
          ..text('test status')
          ..text(''))
        .take(),
  );
  void _request(SshReader r) {
    final type = r.byte();
    requests.add(type);
    if (type == 1) {
      expect(r.uint32(), 3);
      r.end();
      send(
        (SshWriter()
              ..byte(2)
              ..uint32(malformedVersion ? 4 : 3)
              ..text('fsync@openssh.com')
              ..text('1'))
            .take(),
      );
      return;
    }
    final id = r.uint32();
    switch (type) {
      case 7:
      case 17:
        final name = path(r.asciiText());
        if (!files.containsKey(name) &&
            !folders.contains(name) &&
            !links.containsKey(name)) {
          status(id, 2);
          return;
        }
        final reply =
            (SshWriter()
                  ..byte(105)
                  ..uint32(id)
                  ..raw(attrs(name, follow: type == 17).take()))
                .take();
        if (holdStats) {
          held.add(reply);
        } else {
          send(reply);
        }
      case 16:
      case 19:
        final name = path(r.asciiText());
        final result = type == 16 ? name : links[name];
        if (result == null) {
          status(id, 2);
          return;
        }
        send(
          (SshWriter()
                ..byte(104)
                ..uint32(id)
                ..uint32(1)
                ..text(result)
                ..text('')
                ..uint32(0))
              .take(),
        );
      case 11:
      case 3:
        final name = path(r.asciiText());
        if (type == 3) {
          final flags = r.uint32();
          r.uint32();
          if (r.remaining > 0) r.uint32();
          if (flags & 32 != 0 && files.containsKey(name)) {
            status(id, 4);
            return;
          }
          if (flags & 8 != 0) files[name] = [];
          if (!files.containsKey(name) && !links.containsKey(name)) {
            status(id, 2);
            return;
          }
        } else if (!folders.contains(name)) {
          status(id, 2);
          return;
        }
        final handle = 'h${_handleId++}';
        _handles[handle] = links[name] ?? name;
        send(
          (SshWriter()
                ..byte(102)
                ..uint32(id)
                ..text(handle))
              .take(),
        );
      case 4:
        final h = r.asciiText();
        _handles.remove(h);
        status(id, 0);
      case 12:
        final h = r.asciiText(), name = _handles[h]!;
        if (!_listed.add(h)) {
          status(id, 1);
          return;
        }
        final names = {...files.keys, ...folders, ...links.keys}
            .where(
              (p) =>
                  p != name &&
                  p.startsWith('$name/') &&
                  !p.substring(name.length + 1).contains('/'),
            )
            .toList();
        final reply = SshWriter()
          ..byte(104)
          ..uint32(id)
          ..uint32(names.length);
        for (final p in names) {
          reply
            ..text(p.split('/').last)
            ..text('')
            ..raw(attrs(p).take());
        }
        send(reply.take());
      case 5:
        final h = r.asciiText();
        r.uint32();
        final offset = r.uint32(),
            size = r.uint32(),
            file = files[_handles[h]]!;
        if (offset >= file.length) {
          status(id, 1);
          return;
        }
        send(
          (SshWriter()
                ..byte(103)
                ..uint32(id)
                ..string(
                  file.sublist(offset, (offset + size).clamp(0, file.length)),
                ))
              .take(),
        );
      case 6:
        final h = r.asciiText();
        r.uint32();
        final offset = r.uint32(),
            data = r.string(),
            file = files[_handles[h]]!;
        while (file.length < offset + data.length) {
          file.add(0);
        }
        file.setRange(offset, offset + data.length, data);
        status(id, 0);
      case 10:
        status(id, 0);
      case 14:
        final name = path(r.asciiText());
        if (folders.contains(name)) {
          status(id, 4);
        } else {
          folders.add(name);
          status(id, 0);
        }
      case 13:
      case 15:
        final name = path(r.asciiText());
        if (type == 15) {
          folders.remove(name);
        } else {
          files.remove(name);
          links.remove(name);
        }
        status(id, 0);
      case 18:
        final from = path(r.asciiText()), to = path(r.asciiText());
        beforeRename?.call(from, to);
        if (files.containsKey(to) ||
            folders.contains(to) ||
            links.containsKey(to)) {
          status(id, 4);
          return;
        }
        if (files.containsKey(from)) {
          files[to] = files.remove(from)!;
          status(id, 0);
        } else {
          status(id, 2);
        }
      case 200:
        expect(r.asciiText(), 'fsync@openssh.com');
        r.string();
        r.end();
        status(id, 0);
      default:
        status(id, 8);
    }
  }
}
