// Credentials must never reach a log sink.
//
// A bearer/access token is a live credential for its whole TTL, and a
// password is one forever. `dart:developer` log lines and `debugPrint` output
// both land in the device log on debug/profile builds, where any `adb logcat`
// (or a bug-report zip) can read them.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// `--dart-define=RUN_BUGS=true` runs the BUG-skipped proofs.
const bool _runBugs = bool.fromEnvironment('RUN_BUGS');

void main() {
  test(
    'AuthService never interpolates a raw access token into a log line',
    () {
      final src = File('lib/src/services/auth_service.dart').readAsLinesSync();
      final leaks = <String>[
        for (var i = 0; i < src.length; i++)
          if (RegExp(
            r'(dev\.log|sdkLog|debugPrint|print)\(.*\$\{?(accessToken|refreshToken|password|apiSecret)\b',
          ).hasMatch(src[i]))
            'auth_service.dart:${i + 1}: ${src[i].trim()}',
      ];
      expect(leaks, isEmpty);
    },
    skip: _runBugs
        ? null
        : 'BUG N-10: login() and the OTP-verify path both run '
              "dev.log('access_token: \$accessToken')",
  );

  test(
    'the request tracer does not print a password from a POST body',
    () async {
      final printed = <String>[];
      final saved = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => printed.add(m ?? '');
      addTearDown(() => debugPrint = saved);

      final h = RestHelper(
        'http://x',
        client: MockClient((_) async => http.Response(jsonEncode({}), 200)),
      );
      await h.post(
        '/api/method/login',
        body: {'usr': 'someone', 'pwd': 'pw-SHOULD-NOT-LOG'},
      );

      expect(printed.join('\n'), isNot(contains('pw-SHOULD-NOT-LOG')));
    },
    skip: _runBugs
        ? null
        : 'BUG N-10: ApiTracer.traceRequest prints the raw POST body '
              '(credentials included) on every debug build',
  );

  test('the request tracer still records the call itself', () async {
    final printed = <String>[];
    final saved = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => printed.add(m ?? '');
    addTearDown(() => debugPrint = saved);

    final h = RestHelper(
      'http://x',
      client: MockClient((_) async => http.Response(jsonEncode({}), 200)),
    );
    await h.get('/api/method/ping', queryParams: {'a': 1});

    expect(printed.join('\n'), contains('REQUEST GET'));
    expect(printed.join('\n'), contains('RESPONSE 200'));
  });
}
