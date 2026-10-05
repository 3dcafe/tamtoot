class SshException implements Exception {
  const SshException(this.message);
  final String message;
  @override
  String toString() => message;
}
