abstract interface class FlutterToolProcess {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;
  void write(List<int> bytes);
  void kill();
}

typedef FlutterProcessStarter =
    Future<FlutterToolProcess> Function(
      String sdkPath,
      List<String> arguments,
      String? workingDirectory,
    );
