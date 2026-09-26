import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/workspace/tamtoot_meta.dart';

void main() {
  test('TamtootProjectMeta round-trips', () {
    final meta = TamtootProjectMeta(
      remoteUrl: 'https://gitverse.ru/latin/tamtoot.git',
      branch: 'master',
      head: '0123456789abcdef0123456789abcdef01234567',
      clonedAt: DateTime.utc(2026, 9, 26, 12),
      lastOpenedAt: DateTime.utc(2026, 9, 26, 18),
    );
    final parsed = TamtootProjectMeta.parse(meta.encode());
    expect(parsed.remoteUrl, meta.remoteUrl);
    expect(parsed.branch, 'master');
    expect(parsed.head, meta.head);
    expect(parsed.clonedAt.toUtc(), meta.clonedAt);
    expect(parsed.lastOpenedAt!.toUtc(), meta.lastOpenedAt);
    expect(parsed.client, TamtootProjectMeta.defaultClient);
  });

  test('rejects unsupported schema', () {
    expect(
      () => TamtootProjectMeta.parse('{"schemaVersion":2,"kind":"repository"}'),
      throwsA(isA<Exception>()),
    );
  });
}
