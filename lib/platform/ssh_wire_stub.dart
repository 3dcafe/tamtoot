import '../core/ssh/transport/ssh_transport.dart';
import '../core/ssh/ssh_error.dart';
import '../core/ssh/transport/ssh_wire.dart';

Future<SshWire> openSshWire(
  String host,
  int port,
  SshCancellation cancellation,
) => throw const SshException('SSH TCP connections require a native platform.');
