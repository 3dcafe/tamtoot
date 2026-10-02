import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tamtoot/core/agents/model_attachment.dart';
import 'package:tamtoot/core/agents/model_client.dart';
import 'package:tamtoot/core/agents/model_profile.dart';
import 'package:tamtoot/core/agents/ollama_client.dart';
import 'package:tamtoot/features/model_request_dialog.dart';

ModelProfile profile([
  String format = 'chat-completions',
  String endpoint = 'https://api.example.test/v1/chat/completions',
]) => ModelProfile(
  id: 'code',
  name: 'Code',
  provider: 'test',
  model: 'test-model',
  apiFormat: format,
  endpoint: endpoint,
  parameters: {'temperature': 0.2},
);
const prompt = {
  'systemPrompt': 'Follow instructions.',
  'userPrompt': 'Explain this code.',
};

void main() {
  test('chat-completions embeds image and file parts like STAR/OpenAI', () {
    final png = ModelAttachment(
      name: 'shot.png',
      mimeType: 'image/png',
      bytes: Uint8List.fromList([137, 80, 78, 71]),
    );
    final note = ModelAttachment(
      name: 'note.txt',
      mimeType: 'text/plain',
      bytes: Uint8List.fromList(utf8.encode('hello')),
    );
    final body = ModelClient.requestBody(
      profile(),
      prompt,
      attachments: [png, note],
    );
    final user = (body['messages'] as List).last as Map;
    final content = user['content'] as List;
    expect(content.first, {'type': 'text', 'text': 'Explain this code.'});
    expect(content[1]['type'], 'image_url');
    expect(
      (content[1]['image_url'] as Map)['url'],
      startsWith('data:image/png;base64,'),
    );
    expect(content[2]['type'], 'text');
    expect(content[2]['text'], contains('note.txt'));
    expect(content[2]['text'], contains('hello'));
  });

  test('legacy profiles load without endpoint and new profiles round-trip', () {
    final old = jsonDecode(profile().encode()) as Map<String, dynamic>;
    old.remove('endpoint');
    old.remove('apiFormat');
    expect(ModelProfile.parse(jsonEncode(old)).endpoint, '');
    expect(
      ModelProfile.parse(profile('responses').encode()).apiFormat,
      'responses',
    );
  });
  test('validates endpoint and prevents request-body overrides', () {
    for (final endpoint in [
      'http://example.com/api',
      'https://u:p@example.com/api',
      'https://example.com/api?key=secret',
      'file:///tmp/a',
      'https://example.com/api#secret',
    ]) {
      expect(
        () => profile('responses', endpoint).requestUri(),
        throwsFormatException,
      );
    }
    expect(
      profile(
        'chat-completions',
        'http://localhost:11434/v1/chat/completions',
      ).requestUri().host,
      'localhost',
    );
    expect(
      profile(
        'chat-completions',
        'https://ai.qird.ru/v1/models',
      ).requestUri().toString(),
      'https://ai.qird.ru/v1/chat/completions',
    );
    expect(
      profile('chat-completions', 'https://ai.qird.ru').requestUri().path,
      '/v1/chat/completions',
    );
    expect(
      () => ModelProfile(
        id: 'a',
        name: 'a',
        provider: 'p',
        model: 'm',
        parameters: {'stream': true},
      ).validate(),
      throwsFormatException,
    );
  });
  test('models URL completes the full compatible request cycle', () async {
    final client = ModelClient(
      client: MockClient((request) async {
        expect(
          request.url.toString(),
          'https://ai.qird.ru/v1/chat/completions',
        );
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], 'test-model');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'Ready'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );
    final reply = await client.send(
      profile('chat-completions', 'https://ai.qird.ru/v1/models'),
      prompt,
    );
    expect(reply.text, 'Ready');
  });
  test(
    'chat completion sends selected model, auth and parameters; parses UTF8 and usage',
    () async {
      final client = ModelClient(
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.headers['authorization'], 'Bearer test-key');
          expect(request.followRedirects, isFalse);
          final body = jsonDecode(request.body);
          expect(body['model'], 'test-model');
          expect(body['temperature'], 0.2);
          expect(body['stream'], false);
          expect(body['messages'][0]['content'], 'Follow instructions.');
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Ответ'},
                  'finish_reason': 'length',
                },
              ],
              'usage': {'total_tokens': 7},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final reply = await client.send(profile(), prompt, apiKey: 'test-key');
      expect(reply.text, 'Ответ');
      expect(reply.note, contains('limit'));
      expect(reply.usage['total_tokens'], 7);
    },
  );
  test(
    'Responses adapter uses instructions/input and joins only output text',
    () async {
      final client = ModelClient(
        client: MockClient((request) async {
          final body = jsonDecode(request.body);
          expect(body['instructions'], prompt['systemPrompt']);
          expect(body['input'], prompt['userPrompt']);
          expect(body['store'], false);
          return http.Response(
            jsonEncode({
              'status': 'completed',
              'output': [
                {'type': 'reasoning', 'summary': []},
                {
                  'type': 'message',
                  'content': [
                    {'type': 'output_text', 'text': 'One'},
                    {'type': 'output_text', 'text': 'Two'},
                  ],
                },
              ],
            }),
            200,
          );
        }),
      );
      expect(
        (await client.send(profile('responses'), prompt)).text,
        'One\nTwo',
      );
    },
  );
  test(
    'Anthropic adapter uses key/version/max_tokens and parses text blocks',
    () async {
      final client = ModelClient(
        client: MockClient((request) async {
          expect(request.headers['x-api-key'], 'test-key');
          expect(request.headers['anthropic-version'], '2023-06-01');
          expect(request.headers.containsKey('authorization'), false);
          expect(jsonDecode(request.body)['max_tokens'], 2048);
          return http.Response(
            jsonEncode({
              'content': [
                {'type': 'thinking', 'thinking': 'internal'},
                {'type': 'text', 'text': 'Done'},
              ],
              'stop_reason': 'end_turn',
            }),
            200,
          );
        }),
      );
      expect(
        (await client.send(
          profile('anthropic'),
          prompt,
          apiKey: 'test-key',
        )).text,
        'Done',
      );
    },
  );
  test('Ollama discovers models, context and streams chat deltas', () async {
    final requests = <String>[];
    final transport = MockClient((request) async {
      requests.add(request.url.path);
      if (request.url.path == '/api/tags') {
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'qwen3:8b'},
              {'name': 'rnj:latest'},
            ],
          }),
          200,
        );
      }
      if (request.url.path == '/api/show') {
        return http.Response(
          jsonEncode({
            'model_info': {'qwen3.context_length': 32768},
          }),
          200,
        );
      }
      return http.Response('', 404);
    });
    final ollama = OllamaClient(client: transport);
    expect((await ollama.models('http://localhost:11434')).map((m) => m.name), [
      'qwen3:8b',
      'rnj:latest',
    ]);
    expect(
      await ollama.contextWindow('http://localhost:11434', 'qwen3:8b'),
      32768,
    );
    expect(requests, ['/api/tags', '/api/show']);

    final deltas = <String>[];
    final client = ModelClient(
      client: MockClient((request) async {
        final body = jsonDecode(request.body);
        expect(body['options'], {'temperature': 0.2});
        expect(body['stream'], isTrue);
        return http.Response(
          '${jsonEncode({
            'message': {'content': 'Hel'},
            'done': false,
          })}\n'
          '${jsonEncode({
            'message': {'content': 'lo'},
            'done': true,
            'prompt_eval_count': 4,
            'eval_count': 2,
          })}\n',
          200,
        );
      }),
    );
    final answer = await client.send(
      profile('ollama', 'http://localhost:11434/api/chat'),
      prompt,
      onDelta: deltas.add,
    );
    expect(answer.text, 'Hello');
    expect(deltas, ['Hel', 'lo']);
    expect(answer.usage['output_tokens'], 2);
  });

  test('HTTP failures redact credentials and do not retry', () async {
    var calls = 0;
    final client = ModelClient(
      client: MockClient((_) async {
        calls++;
        return http.Response('{"error":{"message":"Bad test-key"}}', 401);
      }),
    );
    await expectLater(
      client.send(profile(), prompt, apiKey: 'test-key'),
      throwsA(
        isA<ModelApiException>().having(
          (e) => e.message,
          'message',
          allOf(contains('401'), isNot(contains('test-key'))),
        ),
      ),
    );
    expect(calls, 1);
  });
  test('malformed and empty answers are explicit failures', () async {
    for (final body in ['not json', '{}', '{"choices":[]}']) {
      final client = ModelClient(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        client.send(profile(), prompt),
        throwsA(isA<ModelApiException>()),
      );
    }
  });
  test(
    'cancel and timeout release the caller even if transport hangs',
    () async {
      final pending = Completer<http.Response>();
      final client = ModelClient(client: MockClient((_) => pending.future));
      final result = client.send(profile(), prompt);
      client.cancel();
      await expectLater(
        result,
        throwsA(
          isA<ModelApiException>().having(
            (e) => e.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
      final timed = ModelClient(
        client: MockClient((_) => pending.future),
        timeout: const Duration(milliseconds: 5),
      );
      await expectLater(
        timed.send(profile(), prompt),
        throwsA(
          isA<ModelApiException>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
      pending.complete(http.Response('{}', 200));
    },
  );

  testWidgets('request dialog sends and displays a model response', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(700, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final p = profile();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ModelRequestDialog(
                  profile: p,
                  prompt: prompt,
                  clientFactory: () => ModelClient(
                    client: MockClient(
                      (_) async => http.Response(
                        jsonEncode({
                          'choices': [
                            {
                              'message': {'content': 'Ready'},
                              'finish_reason': 'stop',
                            },
                          ],
                        }),
                        200,
                      ),
                    ),
                  ),
                ),
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
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'API key',
      ),
      'secret',
    );
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Copy response'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('chat-completions / responses / anthropic disable native tools', () {
    final chat = ModelClient.requestBody(profile(), prompt);
    expect(chat['tool_choice'], 'none');
    final responses = ModelClient.requestBody(profile('responses'), prompt);
    expect(responses['tool_choice'], 'none');
    final anthropic = ModelClient.requestBody(profile('anthropic'), prompt);
    expect(anthropic['tool_choice'], {'type': 'none'});
  });

  test('parseReply explains empty tool_calls answers', () {
    expect(
      () => ModelClient.parseReply('chat-completions', {
        'model': 'glm-5.3-flash',
        'choices': [
          {
            'finish_reason': 'tool_calls',
            'message': {
              'role': 'assistant',
              'content': null,
              'tool_calls': [
                {
                  'type': 'function',
                  'function': {
                    'name': 'unknown_native_tool',
                    'arguments': '{}',
                  },
                },
              ],
            },
          },
        ],
      }),
      throwsA(
        isA<ModelApiException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('No text answer returned.'),
            contains('finish_reason: tool_calls'),
            contains('content: null'),
            contains('tool_calls:'),
            contains('unknown_native_tool'),
            contains('model: glm-5.3-flash'),
            contains('not native tool calls'),
          ),
        ),
      ),
    );
  });

  test('parseReply explains empty length answers without blaming tools', () {
    expect(
      () => ModelClient.parseReply('chat-completions', {
        'model': 'glm-5.3-flash',
        'choices': [
          {
            'finish_reason': 'length',
            'message': {'role': 'assistant', 'content': ''},
          },
        ],
      }),
      throwsA(
        isA<ModelApiException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('finish_reason: length'),
            contains('output token limit'),
            isNot(contains('not native tool calls')),
          ),
        ),
      ),
    );
  });

  test('parseReply converts known tool_calls into JSON actions', () {
    final reply = ModelClient.parseReply('chat-completions', {
      'choices': [
        {
          'finish_reason': 'tool_calls',
          'message': {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'type': 'function',
                'function': {
                  'name': 'search_files',
                  'arguments': '{"query":"openEntry","path":"lib"}',
                },
              },
            ],
          },
        },
      ],
    });
    expect(jsonDecode(reply.text), {
      'action': 'search_files',
      'query': 'openEntry',
      'path': 'lib',
    });
    expect(reply.note, contains('Converted native tool_calls'));
  });

  test('parseReply converts Anthropic tool_use blocks', () {
    final reply = ModelClient.parseReply('anthropic', {
      'stop_reason': 'tool_use',
      'content': [
        {
          'type': 'tool_use',
          'name': 'read_file',
          'input': {
            'path': 'lib/app/session_commands.dart',
            'startLine': 40,
            'lineCount': 80,
          },
        },
      ],
    });
    expect(jsonDecode(reply.text), {
      'action': 'read_file',
      'path': 'lib/app/session_commands.dart',
      'startLine': 40,
      'lineCount': 80,
    });
  });

  test('parseReply accepts ordinary chat text', () {
    final reply = ModelClient.parseReply('chat-completions', {
      'choices': [
        {
          'finish_reason': 'stop',
          'message': {
            'role': 'assistant',
            'content': '{"action":"say","text":"ok"}',
          },
        },
      ],
    });
    expect(reply.text, '{"action":"say","text":"ok"}');
  });
}
