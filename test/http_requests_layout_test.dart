import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/git/git_http.dart';
import 'package:tamtoot/core/git/http_git_service.dart';
import 'package:tamtoot/features/http_requests_dialog.dart';
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

void main() {
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
