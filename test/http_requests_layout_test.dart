import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/git/git_http.dart';
import 'package:tamtoot/core/git/http_git_service.dart';
import 'package:tamtoot/core/git/git_store.dart';
import 'package:tamtoot/features/http_requests_dialog.dart';
import 'package:tamtoot/core/requests/http_request.dart';
import 'package:tamtoot/core/requests/request_storage.dart';
import 'package:tamtoot/platform/git_service_io.dart';
import 'package:tamtoot/platform/git_shared.dart';

import 'support.dart';

class _NoHttpTransport implements GitHttpTransport {
  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    throw UnsupportedError('HTTP is not used in this layout test');
  }
}

HttpGitService _fileGit() => HttpGitService(
  transport: _NoHttpTransport(),
  openStore: (uri) {
    if (uri.scheme != 'file') {
      throw ArgumentError('Expected file:// directory, got $uri');
    }
    return FileGitRepositoryStore(Directory.fromUri(uri));
  },
  inflateAt: sharedInflateAt,
  deflate: sharedDeflate,
);

class _RequestStore extends GitRepositoryStore {
  final files = <String, Uint8List>{};
  final directories = <String>{};
  @override
  Future<bool> exists(String path) async =>
      files.containsKey(path) || directories.contains(path);
  @override
  Future<Uint8List> readBytes(String path) async => files[path]!;
  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    files[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String path) async {
    files.remove(path);
  }

  @override
  Future<void> createDirectory(String path) async {
    directories.add(path);
  }

  @override
  Future<List<String>> listFiles(String dir) async => files.keys
      .where((path) => dir.isEmpty || path.startsWith('$dir/'))
      .toList();
}

void main() {
  testWidgets(
    'requests drag into folders and save an edited request in a nested folder',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _RequestStore();
      final git = HttpGitService(
        transport: _NoHttpTransport(),
        openStore: (_) => store,
        inflateAt: sharedInflateAt,
        deflate: sharedDeflate,
      );
      final session = await testSession(git: git);
      session.workspaceRoot = Uri.parse('file:///test-project/');
      final storage = RequestStorage(store);
      await storage.createFolder('users/admin');
      await storage.create(
        '',
        const HttpRequestFile(name: 'Alpha', url: 'https://example.com/alpha'),
      );
      await storage.create(
        '',
        const HttpRequestFile(name: 'Beta', url: 'https://example.com/beta'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HttpRequestsDialog(
              session: session,
              initialPath: 'alpha.json',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final url = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'URL',
      );
      await tester.enterText(url, 'https://example.com/edited');
      final beta = find.byKey(const ValueKey('request-drag-beta.json'));
      final users = find.byKey(const ValueKey('request-folder-drop-users'));
      await tester.dragFrom(
        tester.getCenter(beta),
        tester.getCenter(users) - tester.getCenter(beta),
      );
      await tester.pumpAndSettle();
      expect(find.text('users/beta.json'), findsOneWidget);
      expect(
        (await storage.read('users/beta.json')).url,
        'https://example.com/beta',
      );
      expect(
        tester.widget<TextField>(url).controller!.text,
        'https://example.com/edited',
      );
      expect(find.text('● Unsaved'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('request-folder')),
        'users/admin',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('users/admin/alpha.json'), findsOneWidget);
      expect(
        (await storage.read('users/admin/alpha.json')).url,
        'https://example.com/edited',
      );
      expect(await store.exists('.tamtoot/requests/alpha.json'), false);
      expect(find.text('● Unsaved'), findsNothing);
      final alpha = find.byKey(
        const ValueKey('request-drag-users/admin/alpha.json'),
      );
      final root = find.byKey(const ValueKey('request-folder-drop-'));
      await tester.dragFrom(
        tester.getCenter(alpha),
        tester.getCenter(root) - tester.getCenter(alpha),
      );
      await tester.pumpAndSettle();
      expect(find.text('alpha.json'), findsOneWidget);
      expect(
        (await storage.read('alpha.json')).url,
        'https://example.com/edited',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('request-folder')))
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.dispose);
      debugDefaultTargetPlatformOverride = null;
    },
  );
  for (final width in [1400.0, 430.0]) {
    testWidgets('creating multiple requests updates the list at width $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _RequestStore();
      final git = HttpGitService(
        transport: _NoHttpTransport(),
        openStore: (_) => store,
        inflateAt: sharedInflateAt,
        deflate: sharedDeflate,
      );
      final session = await testSession(git: git);
      session.workspaceRoot = Uri.parse('file:///test-project/');

      Future<void> flush() async {
        await tester.pumpAndSettle();
      }

      Widget manager(String key) => MaterialApp(
        home: Scaffold(
          body: HttpRequestsDialog(key: ValueKey(key), session: session),
        ),
      );
      await tester.pumpWidget(manager('first'));
      await flush();
      var count = 0;
      for (final title in [
        'request',
        'request',
        'Первый запрос',
        'Второй запрос',
      ]) {
        await tester.tap(find.text('New Request'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), title);
        await tester.tap(find.text('OK'));
        await flush();
        count++;
        if (width >= 720) {
          final nameField = tester.widget<TextField>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is TextField && widget.decoration?.labelText == 'Name',
            ),
          );
          expect(nameField.controller!.text, title);
        }
        if (width < 720) {
          await tester.tap(find.text('Requests'));
          await tester.pumpAndSettle();
        }
        if (width >= 720) {
          expect(find.byType(CheckboxListTile), findsNWidgets(count));
        } else {
          final path = count == 1 ? 'request.json' : 'request-$count.json';
          await tester.scrollUntilVisible(find.text(path), 80);
          expect(find.text(path), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      }

      // Reopening must show all saved requests, including colliding names.
      await tester.pumpWidget(manager('reopened'));
      await flush();
      if (width >= 720) {
        expect(find.byType(CheckboxListTile), findsNWidgets(4));
        expect(find.text('request'), findsNWidgets(2));
        expect(find.text('Второй запрос'), findsOneWidget);
      } else {
        await tester.scrollUntilVisible(find.text('request-4.json'), 80);
        expect(find.text('Второй запрос'), findsOneWidget);
      }
      if (width < 720) {
        await tester.scrollUntilVisible(find.text('Первый запрос'), -80);
      }
      expect(find.text('Первый запрос'), findsOneWidget);

      // Cancelling a switch from a dirty request must not create a hidden file.
      await tester.tap(find.text('Первый запрос'));
      await flush();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == 'URL',
        ),
        'https://example.com/unsaved',
      );
      await tester.tap(find.text('New Request'));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved request'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('New Request (folder/name)'), findsNothing);
      final savedEntries = await requestStorageFor(session).list();
      expect(savedEntries.where((entry) => !entry.directory).length, 4);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(session.dispose);
    });
  }

  testWidgets('HTTP requests dialog fits a narrow mobile viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final directory = Directory(
      'build/tamtoot-http-layout-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    addTearDown(() {
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });

    final session = await testSession(git: _fileGit());
    session.workspaceRoot = directory.absolute.uri;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => HttpRequestsDialog(session: session),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('HTTP Requests'), findsOneWidget);
    expect(find.text('Select All'), findsOneWidget);
    expect(find.text('New Request'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
