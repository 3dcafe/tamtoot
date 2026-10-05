import 'dart:ffi';
import 'dart:io';
import 'package:tamtoot/platform/ssh_crypto/ssh_crypto_io.dart';

Future<({NativeSshCrypto crypto, Directory? directory})>
buildSshTestCrypto() async {
  final supplied = Platform.environment['TAMTOOT_SSH_TEST_LIBRARY'];
  if (supplied != null)
    return (
      crypto: NativeSshCrypto(DynamicLibrary.open(supplied)),
      directory: null,
    );
  final dir = await Directory.systemTemp.createTemp('tamtoot-ssh-native-');
  final source = '${Directory.current.path}/native/ssh/ssh_crypto.cpp';
  final output =
      '${dir.path}/${Platform.isWindows
          ? 'ssh.dll'
          : Platform.isMacOS
          ? 'ssh.dylib'
          : 'ssh.so'}';
  final result = await Process.run(
    Platform.isWindows
        ? 'cl'
        : Platform.isMacOS
        ? '/usr/bin/clang++'
        : 'c++',
    Platform.isWindows
        ? [
            '/LD',
            '/EHsc',
            '/std:c++17',
            source,
            '/Fe:$output',
            '/link',
            'bcrypt.lib',
          ]
        : [
            if (Platform.isMacOS) ...['-arch', 'arm64', '-arch', 'x86_64'],
            '-std=c++17',
            '-O2',
            '-Wall',
            '-Wextra',
            '-shared',
            '-fPIC',
            source,
            '-o',
            output,
          ],
    workingDirectory: dir.path,
  );
  if (result.exitCode != 0) {
    await dir.delete(recursive: true);
    throw StateError('Native SSH test compile failed: ${result.stderr}');
  }
  return (crypto: NativeSshCrypto(DynamicLibrary.open(output)), directory: dir);
}
