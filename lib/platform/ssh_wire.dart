import '../core/ssh/transport/ssh_transport.dart';
import '../core/ssh/transport/ssh_wire.dart';
import 'ssh_wire_stub.dart' if (dart.library.io) 'ssh_wire_io.dart' as native;

Future<SshWire> openSshWire(
  String host,
  int port,
  SshCancellation cancellation,
) => native.openSshWire(host, port, cancellation);
