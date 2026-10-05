import 'dart:ffi';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';
import '../../core/ssh/crypto/ssh_crypto.dart';
import '../../core/ssh/ssh_error.dart';

typedef _AllocN = Pointer<Void> Function(UintPtr);
typedef _FreeN = Void Function(Pointer<Void>, UintPtr);
typedef _RandomN = Int32 Function(Pointer<Uint8>, UintPtr);
typedef _HashN = Int32 Function(Int32, Pointer<Uint8>, UintPtr, Pointer<Uint8>);
typedef _ExchangeN = Pointer<Void> Function(Pointer<Uint8>);
typedef _SharedN =
    Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>);
typedef _DisposeN = Void Function(Pointer<Void>);
typedef _CipherN = Pointer<Void> Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _ApplyN =
    Int32 Function(Pointer<Void>, Pointer<Uint8>, UintPtr, Pointer<Uint8>);

SshCrypto createSshCrypto() {
  try {
    final path = Platform.isAndroid
        ? 'libtamtoot_ssh_crypto.so'
        : Platform.isWindows
        ? 'tamtoot_ssh_crypto.dll'
        : Platform.isLinux
        ? '${File(Platform.resolvedExecutable).parent.path}/lib/libtamtoot_ssh_crypto.so'
        : null;
    return NativeSshCrypto(
      path == null ? DynamicLibrary.process() : DynamicLibrary.open(path),
      libraryPath: path,
    );
  } catch (_) {
    throw const SshException(
      'Native SSH cryptography is unavailable. Rebuild the application.',
    );
  }
}

class NativeSshCrypto implements SshSigningCrypto {
  NativeSshCrypto(this.library, {this.libraryPath});
  final String? libraryPath;
  final DynamicLibrary library;
  late final _alloc = library
      .lookupFunction<_AllocN, Pointer<Void> Function(int)>(
        'tamtoot_ssh_alloc',
      );
  late final _free = library
      .lookupFunction<_FreeN, void Function(Pointer<Void>, int)>(
        'tamtoot_ssh_free',
      );
  late final _random = library
      .lookupFunction<_RandomN, int Function(Pointer<Uint8>, int)>(
        'tamtoot_ssh_random',
      );
  late final _hash = library
      .lookupFunction<
        _HashN,
        int Function(int, Pointer<Uint8>, int, Pointer<Uint8>)
      >('tamtoot_ssh_hash');
  late final _exchange = library
      .lookupFunction<_ExchangeN, Pointer<Void> Function(Pointer<Uint8>)>(
        'tamtoot_ssh_exchange_create',
      );
  late final _shared = library
      .lookupFunction<
        _SharedN,
        int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>)
      >('tamtoot_ssh_exchange_shared');
  late final _exchangeFree = library
      .lookupFunction<_DisposeN, void Function(Pointer<Void>)>(
        'tamtoot_ssh_exchange_free',
      );
  late final _cipher = library
      .lookupFunction<
        _CipherN,
        Pointer<Void> Function(Pointer<Uint8>, Pointer<Uint8>)
      >('tamtoot_ssh_cipher_create');
  late final _apply = library
      .lookupFunction<
        _ApplyN,
        int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint8>)
      >('tamtoot_ssh_cipher_apply');
  late final _cipherFree = library
      .lookupFunction<_DisposeN, void Function(Pointer<Void>)>(
        'tamtoot_ssh_cipher_free',
      );
  late final _signerCreate = library
      .lookupFunction<
        Pointer<Void> Function(Int32, Pointer<Uint8>, UintPtr),
        Pointer<Void> Function(int, Pointer<Uint8>, int)
      >('tamtoot_ssh_signer_create');
  late final _signerSize = library
      .lookupFunction<
        UintPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('tamtoot_ssh_signer_size');
  late final _signerSign = library
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Int32,
          Pointer<Uint8>,
          UintPtr,
          Pointer<Uint8>,
          UintPtr,
        ),
        int Function(
          Pointer<Void>,
          int,
          Pointer<Uint8>,
          int,
          Pointer<Uint8>,
          int,
        )
      >('tamtoot_ssh_signer_sign');
  late final _signerFree = library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('tamtoot_ssh_signer_free');
  late final _bcrypt = library
      .lookupFunction<
        Int32 Function(
          Pointer<Uint8>,
          UintPtr,
          Pointer<Uint8>,
          UintPtr,
          Uint32,
          Pointer<Uint8>,
          UintPtr,
        ),
        int Function(
          Pointer<Uint8>,
          int,
          Pointer<Uint8>,
          int,
          int,
          Pointer<Uint8>,
          int,
        )
      >('tamtoot_ssh_bcrypt');
  @override
  SshSigner createSigner(String algorithm, List<int> material) {
    final kind = algorithm == 'ssh-ed25519'
        ? 1
        : algorithm == 'ssh-rsa'
        ? 2
        : 0;
    if (kind == 0) {
      throw const SshException('Unsupported private-key algorithm.');
    }
    final input = _buffer(material.length, material);
    try {
      final handle = _signerCreate(kind, input.pointer, material.length);
      if (handle == nullptr) {
        throw const SshException(
          'Private key does not match its public key or has invalid parameters.',
        );
      }
      return _NativeSigner(this, handle, _signerSize(handle), kind);
    } finally {
      input.dispose();
    }
  }

  @override
  Future<Uint8List> bcryptPbkdf(
    List<int> password,
    List<int> salt,
    int rounds,
    int length,
  ) async {
    if (password.isEmpty ||
        password.length > 65536 ||
        salt.isEmpty ||
        salt.length > 64 ||
        rounds < 1 ||
        rounds > 128 ||
        length < 1 ||
        length > 64) {
      throw const SshException(
        'Unsupported private-key derivation parameters.',
      );
    }
    final request = (
      path: libraryPath,
      password: Uint8List.fromList(password),
      salt: Uint8List.fromList(salt),
      rounds: rounds,
      length: length,
    );
    try {
      return await Isolate.run(() => _deriveInIsolate(request));
    } finally {
      request.password.fillRange(0, request.password.length, 0);
    }
  }

  _Buffer _buffer(int length, [List<int>? bytes]) =>
      _Buffer(this, length, bytes);
  @override
  Uint8List randomBytes(int length) {
    final output = _buffer(length);
    try {
      if (_random(output.pointer, length) != 1) {
        throw const SshException('System random source failed.');
      }
      return output.copy(length);
    } finally {
      output.dispose();
    }
  }

  Uint8List hash(int bits, List<int> bytes) {
    final input = _buffer(bytes.length, bytes), output = _buffer(bits ~/ 8);
    try {
      if (_hash(bits, input.pointer, bytes.length, output.pointer) != 1) {
        throw const SshException('SSH hash operation failed.');
      }
      return output.copy(bits ~/ 8);
    } finally {
      input.dispose();
      output.dispose();
    }
  }

  @override
  Uint8List sha256(List<int> bytes) => hash(256, bytes);
  @override
  Uint8List sha512(List<int> bytes) => hash(512, bytes);
  @override
  SshKeyExchange createExchange() {
    final output = _buffer(32);
    try {
      final handle = _exchange(output.pointer);
      if (handle == nullptr) {
        throw const SshException('SSH key exchange creation failed.');
      }
      return _NativeExchange(this, handle, output.copy(32));
    } finally {
      output.dispose();
    }
  }

  @override
  SshCipher createCipher(List<int> key, List<int> iv) {
    if (key.length != 32 || iv.length != 16) {
      throw const SshException('Invalid SSH cipher parameters.');
    }
    final k = _buffer(32, key), v = _buffer(16, iv);
    try {
      final handle = _cipher(k.pointer, v.pointer);
      if (handle == nullptr) {
        throw const SshException('SSH cipher creation failed.');
      }
      return _NativeCipher(this, handle);
    } finally {
      k.dispose();
      v.dispose();
    }
  }
}

class _Buffer {
  _Buffer(this.crypto, int length, List<int>? bytes)
    : length = length == 0 ? 1 : length {
    if (length < 0 || length > 2 * 1024 * 1024) {
      throw const SshException('SSH native buffer limit exceeded.');
    }
    pointer = crypto._alloc(this.length).cast<Uint8>();
    if (pointer == nullptr) {
      throw const SshException('SSH native allocation failed.');
    }
    if (bytes != null) pointer.asTypedList(bytes.length).setAll(0, bytes);
  }
  final NativeSshCrypto crypto;
  final int length;
  late Pointer<Uint8> pointer;
  Uint8List copy(int count) => Uint8List.fromList(pointer.asTypedList(count));
  void dispose() {
    if (pointer != nullptr) {
      crypto._free(pointer.cast<Void>(), length);
      pointer = nullptr;
    }
  }
}

class _NativeExchange implements SshKeyExchange {
  _NativeExchange(this.crypto, this.handle, this._publicKey);
  final NativeSshCrypto crypto;
  Pointer<Void> handle;
  final Uint8List _publicKey;
  @override
  Uint8List get publicKey => Uint8List.fromList(_publicKey);
  @override
  Uint8List sharedSecret(List<int> peer) {
    if (handle == nullptr || peer.length != 32) {
      throw const SshException('Invalid SSH key exchange peer.');
    }
    final input = crypto._buffer(32, peer), output = crypto._buffer(32);
    try {
      if (crypto._shared(handle, input.pointer, output.pointer) != 1) {
        throw const SshException(
          'SSH server supplied a low-order exchange key.',
        );
      }
      return output.copy(32);
    } finally {
      input.dispose();
      output.dispose();
    }
  }

  @override
  void dispose() {
    if (handle != nullptr) {
      crypto._exchangeFree(handle);
      handle = nullptr;
    }
  }
}

class _NativeCipher implements SshCipher {
  _NativeCipher(this.crypto, this.handle);
  final NativeSshCrypto crypto;
  Pointer<Void> handle;
  @override
  Uint8List apply(List<int> bytes) {
    if (handle == nullptr) throw const SshException('SSH cipher is closed.');
    final input = crypto._buffer(bytes.length, bytes),
        output = crypto._buffer(bytes.length);
    try {
      if (crypto._apply(handle, input.pointer, bytes.length, output.pointer) !=
          1) {
        throw const SshException('SSH cipher operation failed.');
      }
      return output.copy(bytes.length);
    } finally {
      input.dispose();
      output.dispose();
    }
  }

  @override
  void dispose() {
    if (handle != nullptr) {
      crypto._cipherFree(handle);
      handle = nullptr;
    }
  }
}

NativeSshCrypto _workerCrypto(String? path) => NativeSshCrypto(
  path == null ? DynamicLibrary.process() : DynamicLibrary.open(path),
  libraryPath: path,
);
Uint8List _deriveInIsolate(
  ({String? path, Uint8List password, Uint8List salt, int rounds, int length})
  request,
) {
  final crypto = _workerCrypto(request.path);
  final password = crypto._buffer(request.password.length, request.password),
      salt = crypto._buffer(request.salt.length, request.salt),
      output = crypto._buffer(request.length);
  try {
    if (crypto._bcrypt(
          password.pointer,
          request.password.length,
          salt.pointer,
          request.salt.length,
          request.rounds,
          output.pointer,
          request.length,
        ) !=
        1) {
      throw const SshException(
        'Unsupported private-key derivation parameters.',
      );
    }
    return output.copy(request.length);
  } finally {
    password.dispose();
    salt.dispose();
    output.dispose();
    request.password.fillRange(0, request.password.length, 0);
  }
}

Uint8List _signInIsolate(
  ({String? path, int address, int bits, int size, Uint8List message}) request,
) {
  final crypto = _workerCrypto(request.path),
      input = crypto._buffer(request.message.length, request.message);
  final output = crypto._buffer(request.size);
  try {
    if (crypto._signerSign(
          Pointer<Void>.fromAddress(request.address),
          request.bits,
          input.pointer,
          request.message.length,
          output.pointer,
          request.size,
        ) !=
        1) {
      throw const SshException('Native SSH signing failed.');
    }
    return output.copy(request.size);
  } finally {
    input.dispose();
    output.dispose();
    request.message.fillRange(0, request.message.length, 0);
  }
}

class _NativeSigner implements SshSigner {
  _NativeSigner(this.crypto, this.handle, this.size, this.kind);
  final NativeSshCrypto crypto;
  Pointer<Void> handle;
  final int size, kind;
  bool busy = false, closed = false;
  @override
  Future<Uint8List> sign(List<int> message, String algorithm) async {
    final bits = algorithm == 'ssh-ed25519'
        ? 0
        : algorithm == 'rsa-sha2-512'
        ? 512
        : algorithm == 'rsa-sha2-256'
        ? 256
        : -1;
    if (closed ||
        busy ||
        bits < 0 ||
        (kind == 1 && bits != 0) ||
        (kind == 2 && bits == 0)) {
      throw const SshException('Invalid SSH signing state or algorithm.');
    }
    busy = true;
    final request = (
      path: crypto.libraryPath,
      address: handle.address,
      bits: bits,
      size: size,
      message: Uint8List.fromList(message),
    );
    try {
      return await Isolate.run(() => _signInIsolate(request));
    } finally {
      request.message.fillRange(0, request.message.length, 0);
      busy = false;
      if (closed) _free();
    }
  }

  void _free() {
    if (handle != nullptr) {
      crypto._signerFree(handle);
      handle = nullptr;
    }
  }

  @override
  void dispose() {
    closed = true;
    if (!busy) _free();
  }
}
