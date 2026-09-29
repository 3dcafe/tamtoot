import 'dart:convert';

const httpMethods = {'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'};
const requestBodyTypes = {'none', 'json', 'text', 'form'};
const requestAuthModes = {'inherit', 'none', 'bearer'};

class RequestKeyValue {
  const RequestKeyValue({required this.key, required this.value, this.enabled = true});
  final String key, value;
  final bool enabled;

  Map<String, dynamic> toJson() => {'key': key, 'value': value, 'enabled': enabled};

  factory RequestKeyValue.parse(dynamic value) {
    if (value is! Map || value['key'] is! String || value['value'] is! String) {
      throw const FormatException('Request key/value item is invalid.');
    }
    return RequestKeyValue(
      key: value['key'] as String,
      value: value['value'] as String,
      enabled: value['enabled'] != false,
    );
  }
}

class RequestAttachment {
  const RequestAttachment({required this.type, required this.path});
  final String type, path;
  Map<String, dynamic> toJson() => {'type': type, 'path': path};

  factory RequestAttachment.parse(dynamic value) {
    if (value is! Map || value['type'] != 'markdown' || value['path'] is! String) {
      throw const FormatException('Only Markdown request attachments are supported.');
    }
    final path = value['path'] as String;
    if (!path.toLowerCase().endsWith('.md')) {
      throw const FormatException('Markdown attachment must use .md.');
    }
    return RequestAttachment(type: 'markdown', path: path);
  }
}

class RequestBody {
  const RequestBody({this.type = 'none', this.value});
  final String type;
  final dynamic value;
  Map<String, dynamic> toJson() => {'type': type, if (type != 'none') 'value': value};

  factory RequestBody.parse(dynamic value) {
    if (value == null) return const RequestBody();
    if (value is! Map || value['type'] is! String || !requestBodyTypes.contains(value['type'])) {
      throw const FormatException('Request body is invalid.');
    }
    return RequestBody(type: value['type'] as String, value: value['value']);
  }
}

class RequestAuth {
  const RequestAuth({this.mode = 'inherit', this.token = ''});
  final String mode, token;
  Map<String, dynamic> toJson() => {'mode': mode, if (mode == 'bearer') 'token': token};

  factory RequestAuth.parse(dynamic value) {
    if (value == null) return const RequestAuth();
    if (value is! Map || value['mode'] is! String || !requestAuthModes.contains(value['mode'])) {
      throw const FormatException('Request authorization is invalid.');
    }
    return RequestAuth(
      mode: value['mode'] as String,
      token: value['token'] is String ? value['token'] as String : '',
    );
  }
}

class HttpRequestFile {
  const HttpRequestFile({
    required this.name,
    this.method = 'GET',
    this.url = '',
    this.headers = const [],
    this.query = const [],
    this.body = const RequestBody(),
    this.auth = const RequestAuth(),
    this.attachments = const [],
  });
  final String name, method, url;
  final List<RequestKeyValue> headers, query;
  final RequestBody body;
  final RequestAuth auth;
  final List<RequestAttachment> attachments;

  void validate() {
    if (name.trim().isEmpty || !httpMethods.contains(method)) {
      throw const FormatException('Request name and supported HTTP method are required.');
    }
    if (!requestBodyTypes.contains(body.type) || !requestAuthModes.contains(auth.mode)) {
      throw const FormatException('Unsupported request body or authorization mode.');
    }
    for (final item in [...headers, ...query]) {
      if (item.key.contains('\n') || item.key.contains('\r')) {
        throw const FormatException('Header and query keys cannot contain new lines.');
      }
    }
  }

  Map<String, dynamic> toJson() {
    validate();
    return {
      'version': 1,
      'name': name,
      'method': method,
      'url': url,
      'headers': headers.map((item) => item.toJson()).toList(),
      'query': query.map((item) => item.toJson()).toList(),
      'body': body.toJson(),
      'auth': auth.toJson(),
      if (attachments.isNotEmpty)
        'attachments': attachments.map((item) => item.toJson()).toList(),
    };
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory HttpRequestFile.parse(String source) {
    final data = jsonDecode(source);
    if (data is! Map || data['version'] != 1 || data['name'] is! String || data['method'] is! String || data['url'] is! String) {
      throw const FormatException('Unsupported or invalid HTTP request file.');
    }
    List<T> list<T>(String key, T Function(dynamic) parse) {
      final raw = data[key] ?? const [];
      if (raw is! List) throw FormatException('$key must be an array.');
      return raw.map(parse).toList();
    }
    final request = HttpRequestFile(
      name: data['name'] as String,
      method: data['method'] as String,
      url: data['url'] as String,
      headers: list('headers', RequestKeyValue.parse),
      query: list('query', RequestKeyValue.parse),
      body: RequestBody.parse(data['body']),
      auth: RequestAuth.parse(data['auth']),
      attachments: list('attachments', RequestAttachment.parse),
    );
    request.validate();
    return request;
  }
}

class RequestEnvironment {
  const RequestEnvironment({this.variables = const {}, this.authType = 'none', this.authToken = ''});
  final Map<String, String> variables;
  final String authType, authToken;

  String encode({bool includeAuth = true}) => const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'variables': variables,
    if (includeAuth) 'auth': {'type': authType, if (authType == 'bearer') 'token': authToken},
  });

  factory RequestEnvironment.parse(String? source) {
    if (source == null || source.trim().isEmpty) return const RequestEnvironment();
    final data = jsonDecode(source);
    if (data is! Map || data['version'] != 1 || data['variables'] is! Map) {
      throw const FormatException('Invalid request environment.');
    }
    final variables = <String, String>{};
    for (final entry in (data['variables'] as Map).entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('Environment variables must be strings.');
      }
      variables[entry.key as String] = entry.value as String;
    }
    final auth = data['auth'];
    final type = auth is Map && auth['type'] is String ? auth['type'] as String : 'none';
    if (type != 'none' && type != 'bearer') throw const FormatException('Invalid project authorization.');
    return RequestEnvironment(
      variables: variables,
      authType: type,
      authToken: auth is Map && auth['token'] is String ? auth['token'] as String : '',
    );
  }
}
