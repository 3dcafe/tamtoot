import 'ssh_key_file_stub.dart'
    if (dart.library.io) 'ssh_key_file_io.dart'
    as implementation;

Future<String> readSshKeyFile(Uri uri) => implementation.readSshKeyFile(uri);
