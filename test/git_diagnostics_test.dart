import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tamtoot/core/git/git_service.dart';
import 'package:tamtoot/core/git/git_http.dart';
import 'package:tamtoot/core/git/http_git_service.dart';
import 'package:tamtoot/core/git/pkt_line.dart';
import 'package:tamtoot/features/dialogs.dart';
import 'package:tamtoot/platform/git_shared.dart';
import 'support.dart';

class ProbeTransport implements GitHttpTransport {
  int status = 200;
  Map<String, String>? sentHeaders;
  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    sentHeaders = headers;
    return GitHttpResponse(
      statusCode: status,
      body: Uint8List.fromList([
        ...PktLine.encodeText('# service=git-upload-pack'),
        ...PktLine.encodeFlush(),
        ...PktLine.encodeText(
          '${'a' * 40} HEAD\x00symref=HEAD:refs/heads/main',
        ),
        ...PktLine.encodeText('${'a' * 40} refs/heads/main'),
        ...PktLine.encodeFlush(),
      ]),
    );
  }
}

class FailingProbe extends Fake implements GitService, GitDiagnosticsProvider {
  @override
  void Function(String)? diagnosticLog;
  @override
  Future<GitResult> checkConnection(
    Uri remote, {
    GitCredentials? credentials,
    String? branch,
  }) async {
    diagnosticLog?.call('HTTP 401');
    throw GitException('Failed: ${credentials!.token}');
  }
}

void main() {
  test(
    'Connection probe verifies refs and branch without local writes; logs exclude credentials',
    () async {
      final transport = ProbeTransport();
      final git = HttpGitService(
        transport: transport,
        openStore: (_) => throw StateError('Probe must not open a local store'),
        inflateAt: sharedInflateAt,
        deflate: sharedDeflate,
      );
      final logs = <String>[];
      git.diagnosticLog = logs.add;
      final credentials = const GitCredentials(
        username: 'git',
        token: 'test-secret',
      );
      final remote = Uri.parse('https://gitlab.com/group/repo.git');
      expect(
        (await git.checkConnection(
          remote,
          credentials: credentials,
          branch: 'main',
        )).ok,
        true,
      );
      expect((await git.checkConnection(remote, branch: 'missing')).ok, false);
      expect(logs.join('\n'), contains('HTTP 200'));
      expect(logs.join('\n'), isNot(contains('test-secret')));
      expect(
        logs.join('\n'),
        isNot(contains(base64Encode(utf8.encode('git:test-secret')))),
      );
      transport.status = 401;
      await expectLater(
        git.checkConnection(remote),
        throwsA(isA<GitException>()),
      );
      expect(logs.join('\n'), contains('HTTP 401'));
    },
  );

  testWidgets('Check connection opens copyable, redacted log at phone width', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final git = FailingProbe();
    final session = (await tester.runAsync(() => testSession(git: git)))!;
    addTearDown(session.dispose);
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => CloneRepositoryDialog(session: session),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Repository URL'),
      'https://gitlab.com/group/repo.git',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Access token'),
      'test-secret',
    );
    await tester.tap(find.text('Check connection'));
    await tester.pumpAndSettle();
    expect(find.text('Repository connection log'), findsOneWidget);
    await tester.tap(find.text('Copy log'));
    await tester.pumpAndSettle();
    expect(copied, contains('HTTP 401'));
    expect(copied, contains('[REDACTED]'));
    expect(copied, isNot(contains('test-secret')));
    expect(git.diagnosticLog, isNull);
    expect(tester.takeException(), isNull);
  });
}
