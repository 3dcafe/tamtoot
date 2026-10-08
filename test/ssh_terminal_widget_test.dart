import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/ssh/ssh_client.dart';
import 'package:tamtoot/core/ssh/transport/ssh_codec.dart';
import 'package:tamtoot/core/terminal/terminal_screen.dart';
import 'package:tamtoot/features/ssh_terminal_view.dart';
import 'ssh_client_support.dart';
import 'ssh_client_protocol_test.dart' show ready;

class TerminalFixture {
  final wire = ProtocolTransport();
  final inputs = <List<int>>[];
  final dimensions = <List<int>>[];
  int opens = 0;
  late SshClient client;
  Future<void> start() async {
    client = await ready(wire);
    wire.onSend = (bytes) {
      final r = SshReader(bytes), type = r.byte();
      if (type == 90) {
        opens++;
        r.asciiText();
        final id = r.uint32();
        wire.emit(
          (SshWriter()
                ..byte(91)
                ..uint32(id)
                ..uint32(7)
                ..uint32(262144)
                ..uint32(32768))
              .take(),
        );
      } else if (type == 98) {
        r.uint32();
        final name = r.asciiText(), reply = r.boolean();
        if (name == 'pty-req') {
          expect(r.asciiText(), 'vt100');
          dimensions.add([r.uint32(), r.uint32()]);
        }
        if (name == 'window-change') dimensions.add([r.uint32(), r.uint32()]);
        if (reply) {
          wire.emit(
            (SshWriter()
                  ..byte(99)
                  ..uint32(0))
                .take(),
          );
        }
      } else if (type == 94) {
        r.uint32();
        inputs.add(List<int>.from(r.string()));
      } else if (type == 97) {
        wire.emit(
          (SshWriter()
                ..byte(97)
                ..uint32(0))
              .take(),
        );
      }
    };
  }

  void output(String value) => wire.emit(
    (SshWriter()
          ..byte(94)
          ..uint32(0)
          ..string(utf8.encode(value)))
        .take(),
  );
}

TerminalScreen model(WidgetTester tester) =>
    (tester
                    .widget<CustomPaint>(
                      find.byKey(const Key('ssh-terminal-screen')),
                    )
                    .painter
                as dynamic)
            .screen
        as TerminalScreen;
void main() {
  testWidgets(
    'phone terminal: text, special keys, paste, selection, resize and exit',
    (tester) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = TerminalFixture();
      await fixture.start();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await fixture.client.close();
      });
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return {'text': 'pasted\nline\x1b[201~'};
          }
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SshTerminalView(client: fixture.client, title: 'Fixture'),
        ),
      );
      await tester.pumpAndSettle();
      expect(fixture.opens, 1);
      expect(tester.takeException(), null);
      fixture.output('界e\u0301\x1b[?2004h\x1b[?1h');
      await tester.pumpAndSettle();
      expect(model(tester).lines[0][0].text, '界');
      await tester.enterText(
        find.byKey(const Key('ssh-terminal-input')),
        ' hello',
      );
      await tester.pumpAndSettle();
      expect(utf8.decode(fixture.inputs.last), '\x1b[200~hello\x1b[201~');
      await tester.tap(find.text('Esc'));
      await tester.pumpAndSettle();
      expect(fixture.inputs.last, [27]);
      await tester.tap(find.text('Ctrl'));
      await tester.enterText(find.byKey(const Key('ssh-terminal-input')), ' c');
      await tester.pumpAndSettle();
      expect(fixture.inputs.last, [3]);
      await tester.tap(find.byTooltip('Paste'));
      await tester.pumpAndSettle();
      expect(
        utf8.decode(fixture.inputs.last),
        '\x1b[200~pasted\nline[201~\x1b[201~',
      );
      final rect = tester.getRect(find.byKey(const Key('ssh-terminal-screen')));
      final gesture = await tester.startGesture(
        rect.topLeft + const Offset(2, 8),
      );
      await gesture.moveTo(rect.topLeft + const Offset(23, 8));
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Copy selection or screen'));
      await tester.pumpAndSettle();
      expect(clipboard, '界e\u0301');
      tester.view.physicalSize = const Size(430, 650);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(fixture.dimensions.last[1], lessThan(fixture.dimensions.first[1]));
      expect(tester.takeException(), null);
      fixture.wire.emit(
        (SshWriter()
              ..byte(98)
              ..uint32(0)
              ..text('exit-status')
              ..byte(0)
              ..uint32(0))
            .take(),
      );
      fixture.wire.emit(
        (SshWriter()
              ..byte(97)
              ..uint32(0))
            .take(),
      );
      await tester.pumpAndSettle();
      expect(find.text('Shell exited: 0'), findsOneWidget);
      expect(fixture.opens, 1);
    },
  );
  testWidgets(
    'desktop keyboard sends cursor/application/control keys and safe native paste',
    (tester) async {
      final fixture = TerminalFixture();
      await fixture.start();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await fixture.client.close();
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': 'a\nb'} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SshTerminalView(client: fixture.client, title: 'Keyboard'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ssh-terminal-screen')));
      await tester.pumpAndSettle();
      fixture.output('\x1b[?1h\x1b[?2004h');
      await tester.pumpAndSettle();
      fixture.output('\x1b=');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.numpad1);
      await tester.pumpAndSettle();
      expect(utf8.decode(fixture.inputs.last), '\x1bOq');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(utf8.decode(fixture.inputs.last), '\x1bOA');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(fixture.inputs.last, [3]);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(utf8.decode(fixture.inputs.last), '\x1b[200~a\nb\x1b[201~');
    },
  );
  testWidgets(
    'mobile background disconnects explicitly and resume never reopens shell',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final fixture = TerminalFixture();
      await fixture.start();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await fixture.client.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SshTerminalView(client: fixture.client, title: 'Lifecycle'),
        ),
      );
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(fixture.wire.closed, true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.opens, 1);
      expect(find.textContaining('background'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
