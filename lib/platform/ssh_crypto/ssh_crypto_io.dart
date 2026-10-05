import 'dart:ffi';
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
    final library = Platform.isAndroid
        ? DynamicLibrary.open('libtamtoot_ssh_crypto.so')
        : Platform.isWindows
        ? DynamicLibrary.open('tamtoot_ssh_crypto.dll')
        : Platform.isLinux
        ? DynamicLibrary.open(
            '${File(Platform.resolvedExecutable).parent.path}/lib/libtamtoot_ssh_crypto.so',
          )
        : DynamicLibrary.process();
    return NativeSshCrypto(library);
  } catch (_) {
    throw const SshException(
      'Native SSH cryptography is unavailable. Rebuild the application.',
    );
  }
}

class NativeSshCrypto implements SshCrypto {
  NativeSshCrypto(this.library);
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
