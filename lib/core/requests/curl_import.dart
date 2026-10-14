import 'dart:convert';

import 'http_request.dart';

/// Parse a pasted command as data; never execute a shell or read local files.
HttpRequestFile importCurl(String source, {String name = 'Imported request'}) {
  final args = _split(source);
  if (args.isEmpty ||
      !{'curl', 'curl.exe'}.contains(args.first.toLowerCase())) {
    throw const FormatException('Paste a command starting with curl.');
  }
  String? url, method;
  final headers = <RequestKeyValue>[];
  final data = <String>[];
  var json = false, get = false, head = false;
  void header(String value) {
    final colon = value.indexOf(':');
    if (colon <= 0) throw const FormatException('Invalid cURL header.');
    headers.add(
      RequestKeyValue(
        key: value.substring(0, colon).trim(),
        value: value.substring(colon + 1).trim(),
      ),
    );
  }

  for (var i = 1; i < args.length; i++) {
    var option = args[i];
    String? inline;
    final equals = option.indexOf('=');
    if (option.startsWith('--') && equals > 0) {
      inline = option.substring(equals + 1);
      option = option.substring(0, equals);
    } else if (option.length > 2 &&
        {'-X', '-H', '-d', '-u', '-b'}.contains(option.substring(0, 2))) {
      inline = option.substring(2);
      option = option.substring(0, 2);
    }
    String value() {
      if (inline != null) return inline;
      if (++i >= args.length) {
        throw FormatException('Missing value for $option.');
      }
      return args[i];
    }

    switch (option) {
      case '-X':
      case '--request':
        method = value().toUpperCase();
      case '-H':
      case '--header':
        header(value());
      case '--url':
        if (url != null) {
          throw const FormatException('Only one URL is supported.');
        }
        url = value();
      case '-d':
      case '--data':
      case '--data-ascii':
      case '--data-binary':
      case '--data-raw':
      case '--data-urlencode':
      case '--json':
        var payload = value();
        if (option != '--data-raw' &&
            (payload.startsWith('@') ||
                (option == '--data-urlencode' &&
                    payload.contains('@') &&
                    !payload.contains('=')))) {
          throw const FormatException(
            'File-based cURL bodies are not supported. Paste the body directly.',
          );
        }
        if (option == '--data-urlencode') {
          final split = payload.indexOf('=');
          payload = split < 0
              ? Uri.encodeQueryComponent(payload)
              : '${payload.substring(0, split)}=${Uri.encodeQueryComponent(payload.substring(split + 1))}';
        }
        json |= option == '--json';
        data.add(payload);
      case '-u':
      case '--user':
        header('Authorization: Basic ${base64Encode(utf8.encode(value()))}');
      case '-b':
      case '--cookie':
        final cookie = value();
        if (!cookie.contains('=')) {
          throw const FormatException('Cookie files are not supported.');
        }
        header('Cookie: $cookie');
      case '-G':
      case '--get':
        get = true;
      case '-I':
      case '--head':
        head = true;
      case '--compressed':
      case '-s':
      case '--silent':
      case '-S':
      case '--show-error':
        break;
      default:
        if (option.startsWith('-')) {
          throw FormatException('Unsupported cURL option: $option');
        }
        if (url != null) {
          throw const FormatException('Only one URL is supported.');
        }
        url = option;
    }
  }
  final uri = url == null ? null : Uri.tryParse(url);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty) {
    throw const FormatException('An HTTP or HTTPS URL is required.');
  }
  final payload = data.join(json ? '' : '&');
  if (get && data.isNotEmpty) {
    final query = [if (uri.hasQuery) uri.query, payload].join('&');
    url = uri.replace(query: query).toString();
  }
  void defaultHeader(String key, String value) {
    if (!headers.any((item) => item.key.toLowerCase() == key.toLowerCase())) {
      headers.add(RequestKeyValue(key: key, value: value));
    }
  }

  if (data.isNotEmpty && !get) {
    defaultHeader(
      'Content-Type',
      json ? 'application/json' : 'application/x-www-form-urlencoded',
    );
    if (json) defaultHeader('Accept', 'application/json');
  }
  final request = HttpRequestFile(
    name: name,
    method:
        method ??
        (head
            ? 'HEAD'
            : get || data.isEmpty
            ? 'GET'
            : 'POST'),
    url: url!,
    headers: headers,
    body: data.isEmpty || get
        ? const RequestBody()
        : RequestBody(type: 'text', value: payload),
    auth: const RequestAuth(mode: 'none'),
  );
  request.validate();
  return request;
}

List<String> _split(String source) {
  source = source.replaceAll(RegExp(r'[\\^`]\r?\n'), '');
  final result = <String>[];
  var token = StringBuffer(), quote = '', started = false;
  for (var i = 0; i < source.length; i++) {
    final char = source[i];
    if (char == '\\' && quote != "'" && i + 1 < source.length) {
      final next = source[i + 1];
      if (quote.isEmpty || {'"', '\\', r'$', '`'}.contains(next)) {
        token.write(next);
        i++;
        started = true;
        continue;
      }
    }
    if (quote.isNotEmpty) {
      if (char == quote) {
        quote = '';
      } else {
        token.write(char);
      }
      started = true;
    } else if (char == "'" || char == '"') {
      quote = char;
      started = true;
    } else if (RegExp(r'\s').hasMatch(char)) {
      if (started) result.add(token.toString());
      token = StringBuffer();
      started = false;
    } else {
      token.write(char);
      started = true;
    }
  }
  if (quote.isNotEmpty) {
    throw const FormatException('Unclosed quote in cURL command.');
  }
  if (started) result.add(token.toString());
  return result;
}
