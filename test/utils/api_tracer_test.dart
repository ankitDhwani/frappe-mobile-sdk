import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frappe_mobile_sdk/src/utils/api_tracer.dart';

void main() {
  late List<String> printed;
  late DebugPrintCallback original;

  setUp(() {
    printed = <String>[];
    original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) printed.add(message);
    };
  });
  tearDown(() => debugPrint = original);

  test('a login request trace does not print the password', () {
    ApiTracer.traceRequest(
      method: 'POST',
      url: 'https://example.org/api/method/mobile_auth.login',
      body: {'username': 'field@example.org', 'password': 'hunter2-secret'},
    );

    final out = printed.join('\n');
    expect(out, contains('mobile_auth.login'));
    expect(out, contains('field@example.org'));
    expect(out, isNot(contains('hunter2-secret')));
  });

  test('OTP, refresh token and secrets are redacted at any depth', () {
    ApiTracer.traceRequest(
      method: 'POST',
      url: 'https://example.org/api/method/x',
      body: {
        'tmp_id': 'tmp-1',
        'otp': '493817',
        'nested': {'refresh_token': 'RT-live', 'api_secret': 'S-live'},
        'rows': [
          {'access_token': 'AT-live'},
        ],
      },
    );

    final out = printed.join('\n');
    expect(out, contains('tmp-1'));
    for (final secret in ['493817', 'RT-live', 'S-live', 'AT-live']) {
      expect(out, isNot(contains(secret)));
    }
  });

  test('credential query parameters are redacted in the URL and query', () {
    ApiTracer.traceRequest(
      method: 'GET',
      url: 'https://example.org/api/method/x?token=AT-live&page=2',
      queryParams: {'token': 'AT-live', 'page': 2},
    );
    ApiTracer.traceResponse(
      statusCode: 200,
      url: 'https://example.org/api/method/x?token=AT-live&page=2',
    );

    final out = printed.join('\n');
    expect(out, contains('page'));
    expect(out, isNot(contains('AT-live')));
  });

  test('API keys and OAuth codes are redacted, case-insensitively', () {
    ApiTracer.traceRequest(
      method: 'POST',
      url: 'https://example.org/api/method/x',
      body: {
        'api_key': 'K1-live',
        'API_KEY': 'K2-live',
        'apiKey': 'K3-live',
        'key': 'K4-live',
        'code': 'C1-live',
        'Code': 'C2-live',
        // Short names match only as the whole key.
        'monkey': 'banana',
        'item_code': 'ITEM-001',
        'keyboard': 'qwerty',
      },
    );

    final out = printed.join('\n');
    for (final kept in ['banana', 'ITEM-001', 'qwerty']) {
      expect(out, contains(kept));
    }
    for (final secret in ['K1-live', 'K2-live', 'K3-live', 'K4-live']) {
      expect(out, isNot(contains(secret)));
    }
    expect(out, isNot(contains('C1-live')));
    expect(out, isNot(contains('C2-live')));
  });

  test('an OAuth code in the request URL is redacted', () {
    const url = 'https://example.org/callback?code=C-live&state=S1';
    ApiTracer.traceRequest(method: 'GET', url: url);
    ApiTracer.traceResponse(statusCode: 302, url: url);

    final out = printed.join('\n');
    expect(out, contains('S1'));
    expect(out, isNot(contains('C-live')));
  });

  test('a form-urlencoded String body is redacted', () {
    ApiTracer.traceRequest(
      method: 'POST',
      url: 'https://example.org/api/method/oauth.get_token',
      body:
          'grant_type=authorization_code&code=C-live'
          '&redirect_uri=https%3A%2F%2Fexample.org%2Fcb&client_id=cid-1'
          '&code_verifier=V-live&client_secret=S-live',
    );
    ApiTracer.traceRequest(
      method: 'POST',
      url: 'https://example.org/api/method/login',
      body: 'usr=field%40example.org&pwd=PW-live&api_key=K-live&page=2',
    );

    final out = printed.join('\n');
    for (final kept in [
      'grant_type=authorization_code',
      'client_id=cid-1',
      'usr=field%40example.org',
      'page=2',
    ]) {
      expect(out, contains(kept));
    }
    for (final secret in ['C-live', 'V-live', 'S-live', 'PW-live', 'K-live']) {
      expect(out, isNot(contains(secret)));
    }
  });

  test('a JSON String body is redacted and keeps its other fields', () {
    ApiTracer.traceRequest(
      method: 'POST',
      url: 'https://example.org/api/method/login',
      body:
          '{"usr":"someone","pwd":"PW-live",'
          '"nested":{"api_key":"K-live"},"rows":[{"otp":"123987"}]}',
    );

    final out = printed.join('\n');
    expect(out, contains('someone'));
    for (final secret in ['PW-live', 'K-live', '123987']) {
      expect(out, isNot(contains(secret)));
    }
  });

  test('a JSON String inside a Map value or List stays a redacted String', () {
    final out =
        ApiTracer.redact({
              'cmd': 'x',
              'args': '{"password":"PW-live","name":"n1"}',
            })
            as Map;
    expect(out['cmd'], 'x');
    expect(out['args'], isA<String>());
    final args = jsonDecode(out['args'] as String) as Map;
    expect(args['password'], 'REDACTED');
    expect(args['name'], 'n1');

    final list = ApiTracer.redact(['{"token":"T-live"}', 'plain']) as List;
    expect(list[0], isA<String>());
    expect(list[0], isNot(contains('T-live')));
    expect(list[1], 'plain');
  });

  test('a JSON query parameter is redacted in both the URL and the query', () {
    final query = {'args': '{"password":"PW-live"}', 'page': '2'};
    ApiTracer.traceRequest(
      method: 'GET',
      url: Uri.parse(
        'https://example.org/api/method/x',
      ).replace(queryParameters: query).toString(),
      queryParams: query,
    );

    final out = printed.join('\n');
    expect(out, contains('page'));
    expect(out, isNot(contains('PW-live')));
  });

  test('an error response body string is redacted, nested messages too', () {
    ApiTracer.traceResponse(
      statusCode: 417,
      url: 'https://example.org/api/method/x',
      body: jsonEncode({
        'exc_type': 'ValidationError',
        'exception': 'frappe.exceptions.ValidationError: Bad request',
        '_server_messages': jsonEncode([
          jsonEncode({'message': 'Bad request', 'refresh_token': 'RT-live'}),
        ]),
      }),
    );

    final out = printed.join('\n');
    expect(out, contains('ValidationError'));
    expect(out, contains('Bad request'));
    expect(out, isNot(contains('RT-live')));
  });

  test('strings with nothing to redact are returned unchanged', () {
    const plain = 'Internal Server Error';
    const traceback =
        'Traceback (most recent call last):\n'
        '  File "x.py", line 3, in f\n'
        '    token = get_token(a=1)\n';
    const prettyJson =
        '{\n  "exc_type": "DoesNotExistError",\n'
        '  "filters": "[[\\"name\\", \\"=\\", \\"X-1\\"]]"\n}';
    for (final s in [plain, traceback, prettyJson, 'a=1&b=2']) {
      expect(ApiTracer.redact(s), s);
    }
  });

  test('malformed input never throws and still hides what it can', () {
    expect(() => ApiTracer.redact('{"password": "PW-live"'), returnsNormally);

    final form = ApiTracer.redact('a=%ZZ&b=%E0%A4&pwd=PW-live') as String;
    expect(form, contains('a=%ZZ'));
    expect(form, isNot(contains('PW-live')));

    late String url;
    expect(
      () => url = ApiTracer.redactUrl(
        'https://example.org/x?a=%E0%A4&token=T-live',
      ),
      returnsNormally,
    );
    expect(url, isNot(contains('T-live')));
  });
}
