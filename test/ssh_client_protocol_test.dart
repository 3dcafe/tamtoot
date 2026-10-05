import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/ssh/auth/ssh_private_key.dart';
import 'package:tamtoot/core/ssh/ssh_client.dart';
import 'package:tamtoot/core/ssh/ssh_error.dart';
import 'package:tamtoot/core/ssh/transport/ssh_codec.dart';
import 'package:tamtoot/core/ssh/transport/ssh_transport.dart';
import 'ssh_client_support.dart';

void service(ProtocolTransport wire, Uint8List packet) {
  final r = SshReader(packet)..byte();
  expect(r.asciiText(), 'ssh-userauth');
  r.end();
  wire.emit(
    (SshWriter()
          ..byte(6)
          ..text('ssh-userauth'))
        .take(),
  );
}

void reject(
  ProtocolTransport wire,
  List<String> methods, {
  bool partial = false,
}) => wire.emit(
  (SshWriter()
        ..byte(51)
        ..names(methods)
        ..byte(partial ? 1 : 0))
      .take(),
);
void authScript(
  ProtocolTransport wire,
  void Function(String, SshReader) handler,
) {
  wire.onSend = (packet) {
    if (packet[0] == 5) {
      service(wire, packet);
      return;
    }
    final r = SshReader(packet)..byte();
    expect(r.asciiText(), 'alice');
    expect(r.asciiText(), 'ssh-connection');
    handler(r.asciiText(), r);
  };
}

Future<SshClient> ready(ProtocolTransport wire) async {
  final client = SshClient(wire);
  authScript(wire, (method, r) {
    if (method == 'none') {
      r.end();
      reject(wire, ['password']);
    } else {
      expect(method, 'password');
      expect(r.boolean(), isFalse);
      r.string();
      r.end();
      wire.emit([52]);
    }
  });
  await client.login('alice', password: () async => Uint8List.fromList([1]));
  return client;
}

void channels(
  ProtocolTransport wire, {
  int window = 100000,
  int packet = 32768,
  bool confirm = true,
  bool exit = true,
}) {
  wire.onSend = (bytes) {
    final r = SshReader(bytes);
    final type = r.byte();
    if (type == 90) {
      expect(r.asciiText(), 'session');
      final local = r.uint32();
      expect(r.uint32(), 262144);
      expect(r.uint32(), 32768);
      r.end();
      if (confirm) {
        wire.emit(
          (SshWriter()
                ..byte(91)
                ..uint32(local)
                ..uint32(7)
                ..uint32(window)
                ..uint32(packet))
              .take(),
        );
      }
    } else if (type == 98) {
      expect(r.uint32(), 7);
      expect(r.asciiText(), 'exec');
      expect(r.boolean(), isTrue);
      r.string();
      r.end();
      wire.emit(
        (SshWriter()
              ..byte(99)
              ..uint32(0))
            .take(),
      );
    } else if (type == 94) {
      expect(r.uint32(), 7);
      final data = r.string();
      r.end();
      wire.emit(
        (SshWriter()
              ..byte(94)
              ..uint32(0)
              ..string(data))
            .take(),
      );
    } else if (type == 96) {
      expect(r.uint32(), 7);
      r.end();
      if (exit) {
        wire.emit(
          (SshWriter()
                ..byte(98)
                ..uint32(0)
                ..text('exit-status')
                ..byte(0)
                ..uint32(0))
              .take(),
        );
      }
      wire.emit(
        (SshWriter()
              ..byte(96)
              ..uint32(0))
            .take(),
      );
      wire.emit(
        (SshWriter()
              ..byte(97)
              ..uint32(0))
            .take(),
      );
    }
  };
}

void main() {
  test('credentials cannot be requested before host verification', () async {
    final wire = ProtocolTransport(trustRequired: true);
    final client = SshClient(wire);
    var asked = 0;
    try {
      await expectLater(
        client.login(
          'alice',
          password: () async {
            asked++;
            return Uint8List(1);
          },
        ),
        throwsA(isA<SshException>()),
      );
      expect(asked, 0);
      expect(wire.sent, isEmpty);
    } finally {
      await wire.close();
      await client.close();
    }
  });
  test(
    'password auth waits for service, handles banner and wipes the supplied password',
    () async {
      final wire = ProtocolTransport();
      final protocol = SshClient(wire),
          password = Uint8List.fromList(utf8.encode('test-only-password'));
      var banner = '';
      authScript(wire, (method, r) {
        if (method == 'none') {
          r.end();
          wire.emit(
            (SshWriter()
                  ..byte(53)
                  ..text('Test banner')
                  ..text(''))
                .take(),
          );
          reject(wire, ['password']);
        } else {
          expect(method, 'password');
          expect(r.boolean(), isFalse);
          expect(r.string(), orderedEquals(utf8.encode('test-only-password')));
          r.end();
          wire.emit([52]);
        }
      });
      try {
        await protocol.login(
          'alice',
          password: () async => password,
          onBanner: (text) => banner = text,
        );
        expect(protocol.state, SshClientState.ready);
        expect(wire.authenticated, isTrue);
        expect(banner, 'Test banner');
        expect(password, everyElement(0));
      } finally {
        await protocol.close();
      }
    },
  );
  test(
    'partial key authentication requires interactive factor and wipes answers',
    () async {
      final wire = ProtocolTransport();
      final client = SshClient(wire), signer = ProtocolSigner();
      final blob =
          (SshWriter()
                ..text('ssh-ed25519')
                ..string(Uint8List(32)))
              .take();
      final answer = Uint8List.fromList([4, 2]);
      wire.onSend = (packet) {
        if (packet[0] == 5) {
          service(wire, packet);
          return;
        }
        if (packet[0] == 61) {
          final r = SshReader(packet)..byte();
          expect(r.uint32(), 1);
          expect(r.string(), [4, 2]);
          r.end();
          wire.emit([52]);
          return;
        }
        final r = SshReader(packet)..byte();
        r.asciiText();
        r.asciiText();
        final method = r.asciiText();
        if (method == 'none') {
          reject(wire, ['publickey']);
        } else if (method == 'publickey') {
          final signed = r.boolean();
          expect(r.asciiText(), 'ssh-ed25519');
          expect(r.string(), blob);
          if (!signed) {
            wire.emit(
              (SshWriter()
                    ..byte(60)
                    ..text('ssh-ed25519')
                    ..string(blob))
                  .take(),
            );
          } else {
            r.string();
            r.end();
            reject(wire, ['keyboard-interactive'], partial: true);
          }
        } else {
          expect(method, 'keyboard-interactive');
          r.string();
          r.string();
          r.end();
          wire.emit(
            (SshWriter()
                  ..byte(60)
                  ..text('OTP')
                  ..text('Enter one-time code')
                  ..text('')
                  ..uint32(1)
                  ..text('Code')
                  ..byte(0))
                .take(),
          );
        }
      };
      try {
        await client.login(
          'alice',
          preferKey: true,
          identity: () async => SshIdentity('ssh-ed25519', blob, signer),
          keyboard: (challenge) async {
            expect(challenge.prompts.single.echo, isFalse);
            expect(challenge.prompts.single.text, 'Code');
            return [answer];
          },
        );
        expect(client.state, SshClientState.ready);
        expect(answer, everyElement(0));
        expect(signer.disposed, isTrue);
        final signed = SshReader(signer.message!);
        expect(signed.string(), wire.sessionIdentifier);
        expect(signed.byte(), 50);
      } finally {
        await client.close();
      }
    },
  );
  test(
    'RSA probes SHA-2 only; mismatched public-key acceptance never signs',
    () async {
      final wire = ProtocolTransport();
      final protocol = SshClient(wire), signer = ProtocolSigner();
      final blob =
          (SshWriter()
                ..text('ssh-rsa')
                ..mpint([1, 0, 1])
                ..mpint(List.filled(256, 255)))
              .take();
      authScript(wire, (method, r) {
        if (method == 'none') {
          reject(wire, ['publickey']);
          return;
        }
        expect(method, 'publickey');
        expect(r.boolean(), isFalse);
        final algorithm = r.asciiText();
        expect(algorithm, 'rsa-sha2-512');
        r.string();
        r.end();
        wire.emit(
          (SshWriter()
                ..byte(60)
                ..text(algorithm)
                ..string([1, 2, 3]))
              .take(),
        );
      });
      try {
        await expectLater(
          protocol.login(
            'alice',
            preferKey: true,
            identity: () async => SshIdentity('ssh-rsa', blob, signer),
          ),
          throwsA(isA<SshException>()),
        );
        expect(signer.algorithms, isEmpty);
        expect(signer.disposed, isTrue);
        expect(protocol.state, SshClientState.closed);
      } finally {
        await protocol.close();
      }
    },
  );
  for (final limit in [8, 9]) {
    test(
      'interactive challenge limit permits eight complete rounds: $limit',
      () async {
        final wire = ProtocolTransport();
        final client = SshClient(wire);
        var count = 0, asked = 0;
        void challenge() {
          wire.emit(
            (SshWriter()
                  ..byte(60)
                  ..text('OTP')
                  ..text('')
                  ..text('')
                  ..uint32(1)
                  ..text('Code')
                  ..byte(0))
                .take(),
          );
        }

        wire.onSend = (packet) {
          if (packet[0] == 5) {
            service(wire, packet);
            return;
          }
          if (packet[0] == 61) {
            count++;
            if (count < limit) {
              challenge();
            } else {
              wire.emit([52]);
            }
            return;
          }
          final r = SshReader(packet)..byte();
          r.asciiText();
          r.asciiText();
          final method = r.asciiText();
          if (method == 'none') {
            reject(wire, ['keyboard-interactive']);
          } else {
            expect(method, 'keyboard-interactive');
            challenge();
          }
        };
        try {
          final login = client.login(
            'alice',
            keyboard: (_) async {
              asked++;
              return [
                Uint8List.fromList([1]),
              ];
            },
          );
          if (limit == 8) {
            await login;
            expect(client.state, SshClientState.ready);
          } else {
            await expectLater(login, throwsA(isA<SshException>()));
            expect(client.state, SshClientState.closed);
          }
          expect(asked, 8);
        } finally {
          await client.close();
        }
      },
    );
  }
  test(
    'stdin respects peer window and packet limits, EOF follows pending writes',
    () async {
      final wire = ProtocolTransport();
      final protocol = await ready(wire);
      channels(wire, window: 3, packet: 2);
      try {
        final channel = await protocol.openExec('cat');
        var completed = false;
        final writing = channel.writeStdin([1, 2, 3, 4, 5, 6]).then((_) {
          completed = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(completed, isFalse);
        final data = wire.sent
            .where((p) => p[0] == 94)
            .map(
              (p) =>
                  (SshReader(p)
                        ..byte()
                        ..uint32())
                      .string(),
            )
            .expand((b) => b)
            .toList();
        expect(data, [1, 2, 3]);
        wire.emit(
          (SshWriter()
                ..byte(93)
                ..uint32(0)
                ..uint32(3))
              .take(),
        );
        await writing;
        await channel.finishStdin();
        final result = await channel.result;
        expect(result.stdout, [1, 2, 3, 4, 5, 6]);
        expect(result.succeeded, isTrue);
        for (final p in wire.sent.where((p) => p[0] == 94)) {
          final r = SshReader(p)
            ..byte()
            ..uint32();
          expect(r.string().length, lessThanOrEqualTo(2));
        }
      } finally {
        await protocol.close();
      }
    },
  );
  test('close without exit status cannot become command success', () async {
    final wire = ProtocolTransport(), client = await ready(wire);
    channels(wire, exit: false);
    try {
      final channel = await client.openExec('false');
      await channel.finishStdin();
      await expectLater(
        channel.result,
        throwsA(
          isA<SshException>().having(
            (e) => e.message,
            'message',
            contains('exit status'),
          ),
        ),
      );
    } finally {
      await client.close();
    }
  });
  test('data after channel EOF closes the connection', () async {
    final wire = ProtocolTransport(), client = await ready(wire);
    channels(wire);
    try {
      final channel = await client.openExec('cat');
      final rejected = expectLater(
        channel.result,
        throwsA(isA<SshException>()),
      );
      wire.emit(
        (SshWriter()
              ..byte(96)
              ..uint32(0))
            .take(),
      );
      wire.emit(
        (SshWriter()
              ..byte(94)
              ..uint32(0)
              ..string([1]))
            .take(),
      );
      await rejected;
      expect(client.state, SshClientState.closed);
    } finally {
      await client.close();
    }
  });
  test(
    'cancellation during channel open handles a late confirmation',
    () async {
      final wire = ProtocolTransport(), client = await ready(wire);
      channels(wire, confirm: false);
      final cancellation = SshCancellation();
      try {
        final opening = client.openExec('cat', cancellation: cancellation);
        final rejected = expectLater(opening, throwsA(isA<SshException>()));
        await Future<void>.delayed(Duration.zero);
        cancellation.cancel();
        await rejected;
        wire.emit(
          (SshWriter()
                ..byte(91)
                ..uint32(0)
                ..uint32(7)
                ..uint32(100)
                ..uint32(32))
              .take(),
        );
        await Future<void>.delayed(Duration.zero);
        expect(wire.sent.where((p) => p[0] == 97), hasLength(1));
        wire.emit(
          (SshWriter()
                ..byte(97)
                ..uint32(0))
              .take(),
        );
        await Future<void>.delayed(Duration.zero);
        expect(client.state, SshClientState.ready);
      } finally {
        await client.close();
      }
    },
  );
}
