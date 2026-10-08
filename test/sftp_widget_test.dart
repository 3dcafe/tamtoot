import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/features/sftp_browser_view.dart';
import 'package:tamtoot/platform/sftp_files.dart';
import 'package:flutter/foundation.dart';
import 'sftp_test_peer.dart';

void main() {
  testWidgets(
    'SFTP at phone width: binary export/upload and confirmed deletion',
    (tester) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final peer = SftpTestPeer();
      await peer.start();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await peer.ssh.close();
      });
      List<int>? exported;
      await tester.pumpWidget(
        MaterialApp(
          home: SftpBrowserView(
            client: peer.ssh,
            title: 'Files',
            pickFile: () async => SftpLocalFile(
              'uploaded.bin',
              Uint8List.fromList([0, 128, 255]),
            ),
            saveFile: (name, bytes) async {
              expect(name, 'binary.bin');
              exported = bytes;
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('text.txt'), findsOneWidget);
      expect(tester.takeException(), null);
      final binary = find.ancestor(
        of: find.text('binary.bin'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: binary,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(exported, [0, 255, 7]);
      expect(find.text('Download saved'), findsOneWidget);
      await tester.tap(find.text('Upload'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Upload to remote directory'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(peer.files['/home/uploaded.bin'], [0, 128, 255]);
      expect(find.text('Upload complete'), findsOneWidget);
      final item = find.ancestor(
        of: find.text('uploaded.bin'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: item,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(peer.files.containsKey('/home/uploaded.bin'), true);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(peer.files.containsKey('/home/uploaded.bin'), true);
      await tester.tap(
        find.descendant(
          of: item,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(peer.files.containsKey('/home/uploaded.bin'), false);
      expect(tester.takeException(), null);
    },
  );
  testWidgets(
    'remote editor rejects conflict, reloads only after confirmation and saves backup',
    (tester) async {
      final peer = SftpTestPeer();
      await peer.start();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await peer.ssh.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SftpBrowserView(client: peer.ssh, title: 'Editor'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('text.txt'));
      await tester.pumpAndSettle();
      final editor = find.byType(TextField).last;
      await tester.enterText(editor, 'local change');
      peer.files['/home/text.txt'] = 'server change'.codeUnits;
      await tester.tap(find.text('Save remote'));
      await tester.pumpAndSettle();
      expect(find.textContaining('changed'), findsOneWidget);
      expect(
        String.fromCharCodes(peer.files['/home/text.txt']!),
        'server change',
      );
      await tester.tap(find.byTooltip('Reload remote file'));
      await tester.pumpAndSettle();
      expect(find.text('Reload and discard local edits?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, 'local change');
      await tester.tap(find.byTooltip('Reload remote file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reload'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(editor).controller!.text,
        'server change',
      );
      await tester.enterText(editor, 'saved change');
      await tester.tap(find.text('Save remote'));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(
        String.fromCharCodes(peer.files['/home/text.txt']!),
        'saved change',
      );
      expect(peer.files.keys.any((p) => p.contains('.tamtoot-backup-')), true);
      expect(find.textContaining('Saved. Recovery copy:'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );
}
