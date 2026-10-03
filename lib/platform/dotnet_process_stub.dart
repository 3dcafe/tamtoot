import 'flutter_process_types.dart';

Future<String> resolveDotnet(String configured) async =>
    throw UnsupportedError('.NET tools require desktop');
Future<FlutterToolProcess> startDotnetProcess(
  String executable,
  List<String> args,
  String? directory,
) async => throw UnsupportedError('.NET tools require desktop');
