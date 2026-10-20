// Transport and error-containment tests for the opencode engine port.
// Uses a mock Ollama server; covers the Latin-1/UTF-8 serialization fix and
// the diagnostic error handling that keeps failures out of the transcript.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/opencode/engine.dart';
import 'package:tamtoot/core/opencode/llm.dart';
import 'package:tamtoot/core/opencode/message.dart';

class _MockOllama {
  _MockOllama({required this.responder});

  /// Called per request with the decoded JSON body; returns either an HTTP
  /// status + body for failures or a list of ndjson lines to stream back.
  final FutureOr<Object> Function(Map<String, dynamic> body) responder;
  final capturedBodies = <Map<String, dynamic>>[];
  final capturedRawBodies = <String>[];
  late final HttpServer server;

  Future<int> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      capturedRawBodies.add(raw);
      final body = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      capturedBodies.add(body);
      final result = await responder(body);
      if (result is int) {
        request.response.statusCode = result;
        request.response.write('mock provider failure');
      } else {
        request.response.headers.contentType = ContentType.json;
        for (final line in result as List<String>) {
          request.response.write('$line\n');
          await request.response.flush();
        }
      }
      await request.response.close();
    });
    return server.port;
  }

  Future<void> stop() => server.close(force: true);
}

String _ndjson(Map<String, dynamic> data) => jsonEncode(data);

List<String> _textReply(String text) => [
  _ndjson({
    'message': {'role': 'assistant', 'content': text},
    'done': false,
  }),
  _ndjson({
    'message': {'role': 'assistant', 'content': ''},
    'done': true,
    'done_reason': 'stop',
    'prompt_eval_count': 5,
    'eval_count': 3,
  }),
];

ProviderConfig _provider(int port) => ProviderConfig(
  id: 'ollama',
  type: 'ollama',
  baseURL: 'http://127.0.0.1:$port',
  think: false,
);

void main() {
  group('LlmClient transport', () {
    test('sends Russian Unicode as UTF-8 and completes', () async {
      const message = 'О чем этот проект? Ответь по-русски.';
      final mock = _MockOllama(responder: (_) => _textReply('Проект — IDE.'));
      final port = await mock.start();
      addTearDown(mock.stop);

      final events = <LlmEvent>[];
      await for (final event in LlmClient().stream(
        LlmRequest(
          provider: _provider(port),
          model: 'qwen3:14b',
          messages: [LlmMessage(role: 'user', text: message)],
        ),
      )) {
        events.add(event);
      }

      // The raw body is valid UTF-8 carrying the Cyrillic text verbatim.
      final raw = mock.capturedRawBodies.single;
      expect(raw, contains(message));
      expect(utf8.encode(raw), isNotNull);
      final body = mock.capturedBodies.single;
      expect(body['model'], 'qwen3:14b');
      expect(body['think'], isFalse);
      expect(
        events.whereType<LlmTextDelta>().map((e) => e.text).join(),
        'Проект — IDE.',
      );
      expect(events.whereType<LlmFinish>().single.reason, 'stop');
    });

    test('serializes all six tool definitions natively', () async {
      final mock = _MockOllama(responder: (_) => _textReply('ok'));
      final port = await mock.start();
      addTearDown(mock.stop);

      final tools = [
        for (final name in ['read', 'write', 'edit', 'shell', 'glob', 'grep'])
          LlmToolDef(
            name: name,
            description: '$name tool',
            parameters: {
              'type': 'object',
              'properties': {
                'path': {'type': 'string'},
              },
            },
          ),
      ];
      final request = LlmRequest(
        provider: _provider(port),
        model: 'qwen3:14b',
        messages: [LlmMessage(role: 'user', text: 'hi')],
        tools: tools,
      );
      await for (final _ in LlmClient().stream(request)) {}

      final sent = mock.capturedBodies.single['tools'] as List;
      expect(sent, hasLength(6));
      expect(sent.map((t) => t['function']['name']), [
        'read',
        'write',
        'edit',
        'shell',
        'glob',
        'grep',
      ]);
      expect(sent.first['function']['parameters']['type'], 'object');
    });

    test('returns named tool results using the Ollama wire format', () async {
      final mock = _MockOllama(responder: (_) => _textReply('готово'));
      final port = await mock.start();
      addTearDown(mock.stop);
      await for (final _ in LlmClient().stream(
        LlmRequest(
          provider: _provider(port),
          model: 'qwen3:14b',
          messages: [
            LlmMessage(
              role: 'assistant',
              toolCalls: [
                LlmToolCall(
                  id: 'r1',
                  name: 'read',
                  arguments: {'path': 'README.md'},
                ),
              ],
            ),
            LlmMessage(
              role: 'tool',
              toolCallId: 'r1',
              toolName: 'read',
              text: 'Read file README.md: real content',
            ),
          ],
        ),
      )) {}
      final result =
          (mock.capturedBodies.single['messages'] as List).last as Map;
      expect(result['role'], 'tool');
      expect(result['tool_name'], 'read');
      expect(result.containsKey('name'), isFalse);
      expect(result['content'], contains('real content'));
    });

    test('parses native tool_calls from the stream', () async {
      final mock = _MockOllama(
        responder: (_) => [
          _ndjson({
            'message': {
              'role': 'assistant',
              'tool_calls': [
                {
                  'function': {
                    'name': 'read',
                    'arguments': {'path': 'lib/main.dart'},
                  },
                },
              ],
            },
            'done': false,
          }),
          _ndjson({
            'message': {'role': 'assistant', 'content': ''},
            'done': true,
            'done_reason': 'stop',
          }),
        ],
      );
      final port = await mock.start();
      addTearDown(mock.stop);

      final events = <LlmEvent>[];
      final request = LlmRequest(
        provider: _provider(port),
        model: 'qwen3:14b',
        messages: [LlmMessage(role: 'user', text: 'read main.dart')],
      );
      await for (final event in LlmClient().stream(request)) {
        events.add(event);
      }

      final call = events.whereType<LlmToolCallEvent>().single.call;
      expect(call.name, 'read');
      expect(call.arguments, {'path': 'lib/main.dart'});
      expect(events.whereType<LlmFinish>().single.reason, 'tool-calls');
    });
  });

  group('error containment', () {
    test('ArgumentError brief text is bounded and value-free', () {
      final huge = jsonEncode({'messages': List.filled(50, 'x' * 100)});
      final error = ArgumentError.value(
        huge,
        'string',
        'Contains invalid characters.',
      );
      final brief = briefError(error);
      expect(brief.length, lessThanOrEqualTo(501));
      expect(brief, isNot(contains('xxx')));
      expect(brief, contains('Contains invalid characters'));
    });

    test(
      'transport failure stays out of history and prompts never grow',
      () async {
        var failures = 0;
        late _MockOllama mock;
        mock = _MockOllama(
          responder: (body) {
            final wantsReply = body['messages'].toString().contains('third');
            if (!wantsReply && failures < 2) {
              failures++;
              return 400; // non-retryable provider rejection
            }
            return _textReply('fine');
          },
        );
        final port = await mock.start();
        addTearDown(mock.stop);

        final project = await Directory.systemTemp.createTemp('tamtoot_test');
        addTearDown(() => project.delete(recursive: true));
        await Directory('${project.path}/.tamtoot').create();
        await File('${project.path}/.tamtoot/opencode.json').writeAsString(
          jsonEncode({
            'model': 'ollama/qwen3:14b',
            'providers': {
              'ollama': {
                'type': 'ollama',
                'baseURL': 'http://127.0.0.1:$port',
                'think': false,
              },
            },
          }),
        );

        final engine = OpencodeEngine.forProject(project.path);
        addTearDown(() => OpencodeEngine.restart(project.path));
        final sessionId = await engine.createSession(title: 't');

        Future<void> drain() async {
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (DateTime.now().isBefore(deadline)) {
            final status = await engine.sessionStatus();
            final state = status[sessionId];
            if (state is Map && state['type'] == 'idle') return;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          fail('drain did not settle');
        }

        await engine.promptAsync(sessionId, 'first');
        await drain();
        await engine.promptAsync(sessionId, 'second');
        await drain();
        await engine.promptAsync(sessionId, 'third');
        await drain();

        final messages = [
          for (final raw in await engine.messages(sessionId))
            ChatMessage.fromJson(raw),
        ];
        // Each failure produced exactly one bounded diagnostic message.
        final diagnostics = messages.where((m) => m.diagnostic).toList();
        expect(diagnostics, hasLength(2));
        for (final diagnostic in diagnostics) {
          final text = diagnostic.parts
              .whereType<TextPart>()
              .map((p) => p.text)
              .join();
          expect(text.length, lessThanOrEqualTo(510));
          // A diagnostic may quote the provider's own error body, but it
          // must never echo the serialized request back at the user.
          expect(text, isNot(contains('"role"')));
          expect(text, isNot(contains('first')));
          expect(text, isNot(contains('second')));
        }

        // The successful third request carries only system + three user
        // messages: diagnostics and failed attempts never re-enter the
        // prompt, so repeated failures do not increase its size.
        final thirdRequest = mock.capturedBodies.last;
        final sentMessages = thirdRequest['messages'] as List;
        expect(sentMessages, hasLength(4));
        expect(sentMessages.first['role'], 'system');
        final sentText = jsonEncode(thirdRequest);
        expect(sentText, isNot(contains('⚠')));
        expect(sentText, isNot(contains('Provider rejected')));
      },
    );
  });
}
