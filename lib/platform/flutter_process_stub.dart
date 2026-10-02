import 'flutter_process_types.dart';

Future<FlutterToolProcess> startFlutterProcess(
  String sdkPath,
  List<String> arguments,
  String? workingDirectory,
) async =>
    throw UnsupportedError('Flutter tools are available only on desktop');
Future<String> flutterProjectPath(Uri root, String entryPoint) async =>
    throw UnsupportedError('Flutter tools are available only on desktop');
