import '../../core/ssh/crypto/ssh_crypto.dart';
import 'ssh_crypto_stub.dart'
    if (dart.library.io) 'ssh_crypto_io.dart'
    as native;

SshCrypto createSshCrypto() => native.createSshCrypto();
