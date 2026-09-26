import 'dart:convert';

class SchemaException implements Exception {
  const SchemaException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// All external contracts enter here. v1 is the first supported schema;
/// missing versions and future versions are rejected, never guessed.
Map<String, dynamic> decodeVersioned(String source, String contract) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (e) {
    throw SchemaException('$contract: invalid JSON (${e.message})');
  }
  if (decoded is! Map<String, dynamic>) {
    throw SchemaException('$contract: expected an object');
  }
  if (decoded['schemaVersion'] != 1) {
    throw SchemaException(
      '$contract: unsupported schemaVersion ${decoded['schemaVersion']}; supported: 1',
    );
  }
  return decoded;
}

String requiredString(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is! String || value.isEmpty) {
    throw SchemaException('Missing or invalid $key');
  }
  return value;
}

List<String> stringList(Object? value, String field) {
  if (value is! List || value.any((e) => e is! String)) {
    throw SchemaException('Invalid $field');
  }
  return value.cast<String>();
}
