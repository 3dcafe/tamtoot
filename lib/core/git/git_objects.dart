import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

enum GitObjectType {
  commit(1, 'commit'),
  tree(2, 'tree'),
  blob(3, 'blob'),
  tag(4, 'tag');

  const GitObjectType(this.code, this.name);
  final int code;
  final String name;

  static GitObjectType fromCode(int code) => switch (code) {
    1 => GitObjectType.commit,
    2 => GitObjectType.tree,
    3 => GitObjectType.blob,
    4 => GitObjectType.tag,
    _ => throw FormatException('Unknown git object type $code'),
  };

  static GitObjectType fromName(String name) => switch (name) {
    'commit' => GitObjectType.commit,
    'tree' => GitObjectType.tree,
    'blob' => GitObjectType.blob,
    'tag' => GitObjectType.tag,
    _ => throw FormatException('Unknown git object name $name'),
  };
}

final class GitObject {
  GitObject(this.type, this.content);
  final GitObjectType type;
  final Uint8List content;

  String get hash => hashObject(type, content);

  List<int> get looseBytes {
    final header = utf8.encode('${type.name} ${content.length}');
    return Uint8List.fromList([...header, 0, ...content]);
  }
}

String hashObject(GitObjectType type, List<int> content) {
  final header = utf8.encode('${type.name} ${content.length}');
  final bytes = <int>[...header, 0, ...content];
  return sha1.convert(bytes).toString();
}

String hashHex(List<int> rawLoose) => sha1.convert(rawLoose).toString();

Uint8List hexToBytes(String hex) {
  if (hex.length != 40) {
    throw FormatException('Expected 40-char hex, got ${hex.length}');
  }
  final out = Uint8List(20);
  for (var i = 0; i < 20; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesToHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final b in bytes) {
    buffer.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

final class TreeEntry {
  TreeEntry(this.mode, this.name, this.hash);
  final String mode;
  final String name;
  final String hash; // 40 hex
  bool get isTree => mode.startsWith('4');
}

List<TreeEntry> parseTree(List<int> content) {
  final entries = <TreeEntry>[];
  var i = 0;
  while (i < content.length) {
    final modeStart = i;
    while (i < content.length && content[i] != 0x20) {
      i++;
    }
    final mode = utf8.decode(content.sublist(modeStart, i));
    i++; // space
    final nameStart = i;
    while (i < content.length && content[i] != 0) {
      i++;
    }
    final name = utf8.decode(content.sublist(nameStart, i));
    i++; // NUL
    final hash = bytesToHex(content.sublist(i, i + 20));
    i += 20;
    entries.add(TreeEntry(mode, name, hash));
  }
  return entries;
}

Uint8List encodeTree(List<TreeEntry> entries) {
  final sorted = [...entries]
    ..sort((a, b) {
      final an = a.isTree ? '${a.name}/' : a.name;
      final bn = b.isTree ? '${b.name}/' : b.name;
      return an.compareTo(bn);
    });
  final out = BytesBuilder(copy: false);
  for (final e in sorted) {
    out.add(utf8.encode('${e.mode} ${e.name}'));
    out.addByte(0);
    out.add(hexToBytes(e.hash));
  }
  return out.toBytes();
}

final class CommitInfo {
  CommitInfo({
    required this.tree,
    required this.parents,
    required this.author,
    required this.committer,
    required this.message,
  });

  final String tree;
  final List<String> parents;
  final String author;
  final String committer;
  final String message;
}

CommitInfo parseCommit(List<int> content) {
  final text = utf8.decode(content);
  final parts = text.split('\n\n');
  final header = parts.first.split('\n');
  final message = parts.length > 1 ? parts.sublist(1).join('\n\n') : '';
  String? tree;
  final parents = <String>[];
  String author = '';
  String committer = '';
  for (final line in header) {
    if (line.startsWith('tree ')) {
      tree = line.substring(5);
    } else if (line.startsWith('parent ')) {
      parents.add(line.substring(7));
    } else if (line.startsWith('author ')) {
      author = line.substring(7);
    } else if (line.startsWith('committer ')) {
      committer = line.substring(10);
    }
  }
  if (tree == null) throw FormatException('Commit missing tree');
  return CommitInfo(
    tree: tree,
    parents: parents,
    author: author,
    committer: committer,
    message: message,
  );
}

Uint8List encodeCommit(CommitInfo info) {
  final buffer = StringBuffer()..writeln('tree ${info.tree}');
  for (final parent in info.parents) {
    buffer.writeln('parent $parent');
  }
  buffer
    ..writeln('author ${info.author}')
    ..writeln('committer ${info.committer}')
    ..writeln()
    ..write(info.message);
  if (!info.message.endsWith('\n')) buffer.writeln();
  return Uint8List.fromList(utf8.encode(buffer.toString()));
}

String formatIdent(String name, String email, DateTime when) {
  final seconds = when.toUtc().millisecondsSinceEpoch ~/ 1000;
  return '$name <$email> $seconds +0000';
}
