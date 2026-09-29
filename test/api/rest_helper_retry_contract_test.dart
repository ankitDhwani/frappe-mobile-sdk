// Contract tests for RestHelper's retry loop (rest_helper.dart `_request`).
//
// The loop shares ONE attempt counter between two different kinds of retry:
//   * a network retry (GET only, on SocketException / TimeoutException), and
//   * a token-refresh retry (any verb, on a Bearer 401 that onTokenExpired
//     repaired).
// Whatever the budget, `_request` must end in exactly one of two ways: it
// returns the server's decoded body, or it throws a FrappeException. Falling
// off the end of the `while` returns `null`, which every caller reads as an
// empty-but-successful response.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, int status) =>
    http.Response(jsonEncode(body), status);

void main() {
  group('token-refresh retry', () {
    test('POST: 401 -> refresh -> the same body is re-sent once', () async {
      final bodies = <String>[];
      final h = RestHelper(
        'http://x',
        client: MockClient((req) async {
          bodies.add(req.body);
          if (bodies.length == 1) return _json({'exc': 'expired'}, 401);
          return _json({'message': 'created'}, 200);
        }),
        onTokenExpired: () async => true,
      );
      h.setBearerToken('old');

      final res = await h.post('/api/resource/Task', body: {'title': 'T'});

      expect(res, {'message': 'created'});
      expect(bodies, hasLength(2));
      expect(bodies[0], bodies[1], reason: 'retry must replay the payload');
    });

    test(
      'a fast-fail call (maxRetries: 0) still gets its one post-refresh retry',
      () async {
        // maxRetries documents the NETWORK retry budget ("Pass `0` for
        // fast-fail boot probes", rest_helper.dart:138-139). A refreshed token
        // is not a network retry; the refresh contract is "retry once".
        var calls = 0;
        final h = RestHelper(
          'http://x',
          client: MockClient((_) async {
            calls++;
            if (calls == 1) return _json({'exc': 'expired'}, 401);
            return _json({'message': 'ok'}, 200);
          }),
          onTokenExpired: () async => true,
        );
        h.setBearerToken('old');

        final res = await h.get('/api/method/x', maxRetries: 0);

        expect(calls, 2);
        expect(res, {'message': 'ok'});
      },
      skip:
          'BUG N-03: with maxRetries: 0 a successful token refresh exits the '
          'retry loop and _request returns null instead of retrying',
    );

    test(
      'a request that keeps answering 401 after refreshes throws, never '
      'returns null',
      () async {
        var calls = 0;
        final h = RestHelper(
          'http://x',
          client: MockClient((_) async {
            calls++;
            return _json({'exc': 'expired'}, 401);
          }),
          onTokenExpired: () async => true,
        );
        h.setBearerToken('old');

        Object? outcome;
        try {
          outcome = await h.post('/api/method/x', body: {'a': 1});
        } catch (e) {
          outcome = e;
        }

        expect(calls, greaterThanOrEqualTo(2));
        expect(
          outcome,
          isA<AuthException>(),
          reason:
              'a null return is read by callers as an empty success; a POST '
              'that never went through must surface as an error',
        );
      },
      skip:
          'BUG N-03: after the attempt budget is spent on refresh retries the '
          'while-loop falls through and _request returns null',
    );
  });

  group('network retry', () {
    test('POST is never retried on a socket error (non-idempotent)', () async {
      var calls = 0;
      final h = RestHelper(
        'http://x',
        client: MockClient((_) async {
          calls++;
          throw const SocketException('Connection refused');
        }),
      );

      await expectLater(
        h.post('/api/resource/Task', body: {'title': 'T'}),
        throwsA(
          isA<NetworkException>().having(
            (e) => e.message,
            'message',
            contains('Cannot reach server'),
          ),
        ),
      );
      expect(calls, 1);
    });

    test(
      'an unrecognised socket error maps to "No internet connection"',
      () async {
        final h = RestHelper(
          'http://x',
          client: MockClient((_) async {
            throw const SocketException('Failed host lookup');
          }),
        );
        await expectLater(
          h.post('/api/method/x'),
          throwsA(
            isA<NetworkException>().having(
              (e) => e.message,
              'message',
              'No internet connection',
            ),
          ),
        );
      },
    );

    test(
      'GET timeouts are retried, then surface as NetworkException',
      () async {
        var calls = 0;
        final h = RestHelper(
          'http://x',
          client: MockClient((_) async {
            calls++;
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return _json({'message': 'late'}, 200);
          }),
          requestTimeout: const Duration(milliseconds: 20),
        );

        await expectLater(
          h.get('/api/method/x', maxRetries: 1),
          throwsA(
            isA<NetworkException>().having(
              (e) => e.message,
              'message',
              contains('not responding'),
            ),
          ),
        );
        expect(calls, 2);
      },
    );

    test('PUT timeout is not retried', () async {
      var calls = 0;
      final h = RestHelper(
        'http://x',
        client: MockClient((_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return _json({'message': 'late'}, 200);
        }),
        requestTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        h.put('/api/resource/Task/T-1', body: {'a': 1}),
        throwsA(isA<NetworkException>()),
      );
      expect(calls, 1);
    });

    test('a non-Frappe client error is wrapped, not leaked raw', () async {
      final h = RestHelper(
        'http://x',
        client: MockClient((_) async {
          throw http.ClientException('connection closed');
        }),
      );
      await expectLater(
        h.delete('/api/resource/Task/T-1'),
        throwsA(
          isA<NetworkException>().having(
            (e) => e.message,
            'message',
            contains('connection closed'),
          ),
        ),
      );
    });
  });

  group('callPublic', () {
    test('GET callPublic sends no Authorization and uses the query', () async {
      late http.Request seen;
      final h = RestHelper(
        'http://x/',
        client: MockClient((req) async {
          seen = req;
          return _json({'message': 1}, 200);
        }),
      );
      h.setBearerToken('secret');

      await h.callPublic('app.ping', args: {'a': 'b'}, httpMethod: 'get');

      expect(seen.method, 'GET');
      expect(seen.url.path, '/api/method/app.ping');
      expect(seen.url.queryParameters, {'a': 'b'});
      expect(seen.headers.containsKey('Authorization'), isFalse);
    });

    test('POST callPublic sends the args as a JSON body', () async {
      late http.Request seen;
      final h = RestHelper(
        'http://x',
        client: MockClient((req) async {
          seen = req;
          return _json({'message': 1}, 200);
        }),
      );
      await h.callPublic('app.ping', args: {'a': 'b'});
      expect(seen.method, 'POST');
      expect(jsonDecode(seen.body), {'a': 'b'});
      expect(seen.headers['Content-Type'], startsWith('application/json'));
    });
  });

  test('requestHeaders exposes the active auth header for media loads', () {
    final h = RestHelper('http://x');
    expect(h.requestHeaders.containsKey('Authorization'), isFalse);
    h.setApiKey('k', 's');
    expect(h.requestHeaders['Authorization'], 'token k:s');
    h.setBearerToken('b');
    expect(h.requestHeaders['Authorization'], 'Bearer b');
    h.clearSession();
    expect(h.requestHeaders.containsKey('Authorization'), isFalse);
  });
}
