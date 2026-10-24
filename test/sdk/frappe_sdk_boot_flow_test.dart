// FrappeSDK.initialize() — the real boot path a host app runs before its first
// frame (not FrappeSDK.forTesting). A file database under sqflite_ffi, mocked
// secure storage, and a loopback server for the mobile_auth endpoints.
//
// Contracts (frappe_sdk.dart):
//   * initialize() is idempotent and concurrent calls share ONE init
//     (_initInFlight, :384-409);
//   * after init every service getter is wired and the client carries the
//     `*` expander (:531-538);
//   * login through `sdk.auth` makes `sdk.isAuthenticated` true, and the token
//     survives into a second SDK instance's restoreSession (an app restart);
//   * logout(clearDatabase: false) ends the session but keeps local data.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The widget-test binding answers every HttpClient request with 400; this
/// restores real sockets (to the loopback server only) for the test body.
class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  final hits = <String>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    FlutterSecureStorage.setMockInitialValues({});
    // connectivity_plus: report wifi so boot probes see "online".
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (call) async => ['wifi'],
        );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      hits.add(req.uri.path);
      await utf8.decoder.bind(req).join();
      final path = req.uri.path;
      Object body = {'message': null};
      if (path.endsWith('mobile_auth.login')) {
        body = {
          'access_token': 'access-1',
          'refresh_token': 'refresh-1',
          'user': 'tester@test.invalid',
          'full_name': 'Test User',
          'roles': ['Tester'],
        };
      }
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await req.response.close();
    });
  });

  tearDownAll(() => server.close(force: true));

  final appName = 'boot_flow_${DateTime.now().microsecondsSinceEpoch}';
  String base() => 'http://127.0.0.1:${server.port}';

  test('boot, login, "restart", restore, logout', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final sdk = FrappeSDK(baseUrl: base(), databaseAppName: appName);

      // Concurrent callers share one initialisation.
      await Future.wait([sdk.initialize(), sdk.initialize()]);
      await sdk.initialize(); // idempotent

      expect(sdk.isAuthenticated, isFalse);
      expect(sdk.auth, isNotNull);
      expect(sdk.meta, isNotNull);
      expect(sdk.repository, isNotNull);
      expect(sdk.sync, isNotNull);
      expect(sdk.linkOptions, isNotNull);
      expect(sdk.permissions, isNotNull);
      expect(sdk.security, isNotNull);
      expect(sdk.auth.client!.doctype.starFieldsResolver, isNotNull);

      await sdk.auth.login('tester@test.invalid', 'pw');
      expect(sdk.isAuthenticated, isTrue);
      expect(sdk.roles, ['Tester']);
      expect(sdk.currentUser?.email, 'tester@test.invalid');

      // A second SDK over the same database = the next cold start.
      final restarted = FrappeSDK(baseUrl: base(), databaseAppName: appName);
      await restarted.initialize();
      expect(await restarted.auth.restoreSession(), isTrue);
      expect(restarted.isAuthenticated, isTrue);
      expect(
        restarted.auth.client!.requestHeaders['Authorization'],
        'Bearer access-1',
      );

      await restarted.logout(clearDatabase: false);
      expect(restarted.isAuthenticated, isFalse);
      expect(await restarted.auth.restoreSession(), isFalse);

      await restarted.dispose();
      await sdk.dispose();
    }, _RealHttp());
  });
}
