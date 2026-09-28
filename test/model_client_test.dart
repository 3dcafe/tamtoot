import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tamtoot/core/agents/model_client.dart';
import 'package:tamtoot/core/agents/model_profile.dart';

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
          expect(jsonDecode(request.body)['max_tokens'], 4096);
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
}
