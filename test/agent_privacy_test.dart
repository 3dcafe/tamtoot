import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/agents/agent_privacy.dart';
import 'package:tamtoot/core/agents/model_attachment.dart';

void main() {
  test('Unicode and punycode domains are masked', () {
    final privacy = AgentPrivacy();
    const source = 'api.example.ru пример.рф xn--e1afmkfd.xn--p1ai';
    final masked = privacy.mask(source);
    expect(masked, isNot(contains('example.ru')));
    expect(masked, isNot(contains('пример.рф')));
    expect(masked, isNot(contains('xn--p1ai')));
    expect(privacy.restore(masked), source);
  });

  test(
    'hosts and URL credentials are masked with reversible run-local aliases',
    () {
      final privacy = AgentPrivacy();
      const source =
          'https://user:password@api.customer.example:8443/path '
          'api.customer.example mail@customer.example 192.168.1.10 '
          'http://[2001:db8::1]:80/ lib/main.dart README.md';
      final masked = privacy.mask(source);
      for (final secret in [
        'customer.example',
        'password',
        '192.168.1.10',
        '2001:db8::1',
      ]) {
        expect(masked, isNot(contains(secret)));
      }
      expect(masked, contains('lib/main.dart README.md'));
      expect(privacy.mask(masked), masked);
      expect(privacy.restore(masked), source);
      expect(
        privacy.mask('api.customer.example'),
        privacy.mask('api.customer.example'),
      );
      expect(AgentPrivacy().restore(masked), masked);
    },
  );

  test(
    'nested actions restore domains without persisting aliases to edits',
    () {
      final privacy = AgentPrivacy();
      final masked = privacy.mask('https://api.example.com/');
      final result = privacy.restoreValue({
        'action': 'replace_in_file',
        'oldText': masked,
        'newText': '$masked/v2',
        'paths': [privacy.mask('api.example.com/config.json')],
      });
      expect(result['oldText'], 'https://api.example.com/');
      expect(result['newText'], 'https://api.example.com//v2');
      expect(result['paths'], ['api.example.com/config.json']);
    },
  );

  test('text attachments are masked and binary attachments are rejected', () {
    final privacy = AgentPrivacy();
    final prepared = privacy.prepareAttachments([
      ModelAttachment(
        name: 'notes.txt',
        mimeType: 'text/plain',
        bytes: Uint8List.fromList(utf8.encode('https://internal.example.com')),
      ),
    ]);
    expect(
      utf8.decode(prepared.single.bytes),
      isNot(contains('internal.example.com')),
    );
    expect(
      () => privacy.prepareAttachments([
        ModelAttachment(
          name: 'image.png',
          mimeType: 'image/png',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      ]),
      throwsFormatException,
    );
  });
}
