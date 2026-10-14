import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/requests/curl_import.dart';
import 'package:tamtoot/core/requests/http_request.dart';

void main() {
  test('imports browser cURL with quoted JSON and line continuations', () {
    final request = importCurl(r'''curl 'https://example.com/api?q=one&q=two' \
      -X POST \
      -H 'Content-Type: application/json' \
      -H 'Authorization: Bearer secret' \
      --data-raw '{"text":"hello world","path":"C:\\files"}' --compressed''');
    expect(request.method, 'POST');
    expect(request.url, 'https://example.com/api?q=one&q=two');
    expect(request.headers.length, 2);
    expect(request.body.type, 'text');
    expect(request.body.value, r'{"text":"hello world","path":"C:\\files"}');
    expect(request.auth.mode, 'none');
    expect(
      HttpRequestFile.parse(request.encode()).body.value,
      request.body.value,
    );
  });

  test('imports Windows command and escaped double quotes', () {
    final request = importCurl(r'''curl.exe "https://example.com/api" ^
      --json "{\"name\":\"hello\"}"''');
    expect(request.method, 'POST');
    expect(request.body.value, '{"name":"hello"}');
    expect(request.headers.map((h) => h.value), [
      'application/json',
      'application/json',
    ]);
  });

  test('supports attached options, basic authorization and cookies', () {
    final request = importCurl(
      "curl https://example.com -XPATCH -H'X-Test: value' -u user:pass -b 'session=123' -d'a=1' --data='b=2'",
    );
    expect(request.method, 'PATCH');
    expect(request.body.value, 'a=1&b=2');
    expect(
      request.headers.any(
        (h) => h.key == 'Authorization' && h.value == 'Basic dXNlcjpwYXNz',
      ),
      true,
    );
    expect(
      request.headers.any((h) => h.key == 'Cookie' && h.value == 'session=123'),
      true,
    );
  });

  test(
    'GET data becomes query before fragment and keeps existing parameters',
    () {
      final request = importCurl(
        "curl 'https://example.com/?a=1#anchor' -G --data-urlencode 'q=hello world' -d'a=2'",
      );
      expect(request.method, 'GET');
      expect(request.url, 'https://example.com/?a=1&q=hello+world&a=2#anchor');
      expect(request.body.type, 'none');
    },
  );

  test('rejects invalid commands and options that cannot be represented', () {
    for (final source in [
      'echo hello',
      'curl',
      "curl 'https://example.com",
      'curl https://example.com -H',
      'curl https://example.com --data @secret.txt',
      'curl https://example.com -F file=@secret.txt',
      'curl https://example.com --location',
      'curl https://example.com https://other.com',
      'curl file:///secret.txt',
      'curl https://example.com -X TRACE',
      'curl https://example.com ; echo hello',
    ]) {
      expect(() => importCurl(source), throwsFormatException, reason: source);
    }
  });
}
