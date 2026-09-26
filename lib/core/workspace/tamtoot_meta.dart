import 'dart:convert';

import '../persistence/schema.dart';

/// Service metadata for a Tamtoot-managed project folder (`.tamtoot/`).
/// Lives beside `.git` and is safe to commit or keep local.
class TamtootProjectMeta {
  TamtootProjectMeta({
    required this.remoteUrl,
    required this.branch,
    required this.head,
    required this.clonedAt,
    this.lastOpenedAt,
    this.client = defaultClient,
  });

  static const schemaVersion = 1;
  static const defaultClient = 'tamtoot-http-git/0.1';
  static const directoryName = '.tamtoot';
  static const fileName = 'workspace.json';
  static const relativePath = '$directoryName/$fileName';

  final String remoteUrl;
  final String branch;
  final String head;
  final DateTime clonedAt;
  final DateTime? lastOpenedAt;
  final String client;

  TamtootProjectMeta copyWith({
    String? remoteUrl,
    String? branch,
    String? head,
    DateTime? clonedAt,
    DateTime? lastOpenedAt,
    String? client,
  }) => TamtootProjectMeta(
    remoteUrl: remoteUrl ?? this.remoteUrl,
    branch: branch ?? this.branch,
    head: head ?? this.head,
    clonedAt: clonedAt ?? this.clonedAt,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
    client: client ?? this.client,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'kind': 'repository',
    'remoteUrl': remoteUrl,
    'branch': branch,
    'head': head,
    'clonedAt': clonedAt.toUtc().toIso8601String(),
    'lastOpenedAt': lastOpenedAt?.toUtc().toIso8601String(),
    'client': client,
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory TamtootProjectMeta.parse(String source) {
    final data = decodeVersioned(source, 'TamtootWorkspace');
    if (data['kind'] != null && data['kind'] != 'repository') {
      throw const SchemaException('TamtootWorkspace: unexpected kind');
    }
    DateTime? opened;
    final rawOpened = data['lastOpenedAt'];
    if (rawOpened is String && rawOpened.isNotEmpty) {
      opened = DateTime.tryParse(rawOpened);
    }
    return TamtootProjectMeta(
      remoteUrl: requiredString(data, 'remoteUrl'),
      branch: requiredString(data, 'branch'),
      head: requiredString(data, 'head'),
      clonedAt:
          DateTime.tryParse(requiredString(data, 'clonedAt')) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      lastOpenedAt: opened,
      client: data['client'] is String && (data['client'] as String).isNotEmpty
          ? data['client'] as String
          : defaultClient,
    );
  }
}
