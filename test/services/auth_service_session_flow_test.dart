// AuthService end to end: login -> persisted token -> restoreSession ->
// reactive 401 refresh -> logout, against a loopback HTTP server and an
// in-memory database. No production code is stubbed: AuthService builds its
// own FrappeClient/RestHelper exactly as it does in an app.
//
// Contracts exercised (auth_service.dart):
//   * login stores access + refresh token in `auth_tokens` and sets the Bearer;
//     a response without a refresh token is refused (login():281-284);
//   * restoreSession installs a FRESH stored token without any network call,
//     and proactively refreshes an AGED one (TTL 24h minus 5 min skew,
//     :166-170, :602-641);
//   * a Bearer 401 triggers ONE refresh (single-flight, :967-979) and the
//     request is retried with the new token;
//   * only a DEFINITIVE refresh rejection deletes the token (:1026-1042); a
//     transport failure keeps it so an offline user stays signed in;
//   * logout clears the token row and the Bearer.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/database/entities/auth_token_entity.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Server {
  _Server._(this._s);
  final HttpServer _s;
  final hits = <String>[];
  final authHeaders = <String?>[];

  /// Access token the protected endpoint currently accepts.
  String validAccess = 'access-2';

  /// What the refresh endpoint answers: 200 (new token), 401, or null to
  /// drop the connection (transport failure).
  int? refreshStatus = 200;
  Duration refreshDelay = Duration.zero;

  static Future<_Server> start() async {
    final s = _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    s._s.listen(s._handle);
    return s;
  }

  String get base => 'http://127.0.0.1:${_s.port}';

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    hits.add(path);
    authHeaders.add(req.headers.value('authorization'));
    final body = await utf8.decoder.bind(req).join();
    void reply(int status, Object json) {
      req.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(json));
    }

    if (path.endsWith('/mobile_auth.login')) {
      final args = body.isEmpty ? {} : jsonDecode(body) as Map;
      if (args['password'] != 'correct-horse') {
        reply(417, {
          'exc_type': 'ValidationError',
          'message': 'Unable to login',
        });
      } else if (args['username'] == 'no-refresh@test.invalid') {
        reply(200, {'access_token': 'access-1', 'user': 'u'});
      } else {
        reply(200, {
          'access_token': 'access-1',
          'refresh_token': 'refresh-1',
          'user': 'tester@test.invalid',
          'full_name': 'Test User',
          'roles': ['Tester'],
        });
      }
    } else if (path.endsWith('/mobile_auth.refresh_token')) {
      await Future<void>.delayed(refreshDelay);
      if (refreshStatus == null) {
        await req.response.detachSocket().then((s) => s.destroy());
        return;
      }
      if (refreshStatus == 200) {
        reply(200, {'access_token': validAccess, 'refresh_token': 'refresh-2'});
      } else {
        reply(refreshStatus!, {'exc_type': 'AuthenticationError'});
      }
    } else if (path.endsWith('/api/method/app.ping')) {
      final auth = req.headers.value('authorization');
      if (auth == 'Bearer $validAccess') {
        reply(200, {'message': 'pong'});
      } else {
        reply(401, {'exc_type': 'AuthenticationError'});
      }
    } else if (path.endsWith('/mobile_auth.logout')) {
      reply(200, {'message': 'ok'});
    } else {
      reply(404, {'exc_type': 'DoesNotExistError'});
    }
    await req.response.close();
  }

  int count(String suffix) => hits.where((h) => h.endsWith(suffix)).length;

  Future<void> close() => _s.close(force: true);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late _Server server;
  late AppDatabase db;
  late AuthService auth;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = await _Server.start();
    db = await AppDatabase.inMemoryDatabase();
    auth = AuthService()..initialize(server.base, database: db);
    // initialize() writes the base URL fire-and-forget; let it land.
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() => server.close());

  Future<void> seedToken({required Duration age, String access = 'access-1'}) =>
      db.authTokenDao.insertToken(
        AuthTokenEntity(
          accessToken: access,
          refreshToken: 'refresh-1',
          user: 'tester@test.invalid',
          fullName: 'Test User',
          createdAt: DateTime.now().subtract(age).millisecondsSinceEpoch,
        ),
      );

  group('login', () {
    test('persists both tokens, sets the Bearer and the roles', () async {
      await auth.login('tester@test.invalid', 'correct-horse');

      expect(auth.isAuthenticated, isTrue);
      expect(auth.roles, ['Tester']);
      final t = await db.authTokenDao.getCurrentToken();
      expect(t?.accessToken, 'access-1');
      expect(t?.refreshToken, 'refresh-1');
      expect(auth.client!.requestHeaders['Authorization'], 'Bearer access-1');
      expect(auth.currentUserInfo?.fullName, 'Test User');
    });

    test('a wrong password is a ValidationException, not a session', () async {
      await expectLater(
        auth.login('tester@test.invalid', 'wrong'),
        throwsA(isA<ValidationException>()),
      );
      expect(auth.isAuthenticated, isFalse);
      expect(await db.authTokenDao.getCurrentToken(), isNull);
    });

    test('a response without a refresh token is refused', () async {
      await expectLater(
        auth.login('no-refresh@test.invalid', 'correct-horse'),
        throwsA(
          predicate((e) => e.toString().contains('missing refresh_token')),
        ),
      );
      expect(auth.isAuthenticated, isFalse);
    });
  });

  group('restoreSession', () {
    test(
      'a fresh stored token is installed without any network call',
      () async {
        await seedToken(age: const Duration(hours: 1));

        expect(await auth.restoreSession(), isTrue);

        expect(auth.isAuthenticated, isTrue);
        expect(server.hits, isEmpty);
        expect(auth.client!.requestHeaders['Authorization'], 'Bearer access-1');
      },
    );

    test('an aged token is refreshed proactively before first use', () async {
      await seedToken(age: const Duration(hours: 23, minutes: 58));

      expect(await auth.restoreSession(), isTrue);

      expect(server.count('mobile_auth.refresh_token'), 1);
      final t = await db.authTokenDao.getCurrentToken();
      expect(t?.accessToken, 'access-2');
      expect(t?.refreshToken, 'refresh-2');
      expect(auth.client!.requestHeaders['Authorization'], 'Bearer access-2');
    });

    test('an aged token restored OFFLINE is kept, not wiped', () async {
      await seedToken(age: const Duration(hours: 30));

      expect(await auth.restoreSession(isOnline: false), isTrue);

      expect(server.hits, isEmpty);
      expect(
        (await db.authTokenDao.getCurrentToken())?.accessToken,
        'access-1',
      );
    });

    test('a definitively rejected refresh deletes the token', () async {
      await seedToken(age: const Duration(hours: 30));
      server.refreshStatus = 401;

      expect(await auth.restoreSession(), isFalse);

      expect(await db.authTokenDao.getCurrentToken(), isNull);
      expect(auth.sessionHealth.value, SessionHealth.expired);
      expect(auth.expiredSessionEmail, 'tester@test.invalid');
    });

    test('a transport failure during refresh keeps the token', () async {
      await seedToken(age: const Duration(hours: 30));
      server.refreshStatus = null; // connection dropped

      expect(await auth.restoreSession(), isTrue);

      expect(
        (await db.authTokenDao.getCurrentToken())?.accessToken,
        'access-1',
        reason: 'an offline blip must not strand the user behind login',
      );
      expect(auth.sessionHealth.value, isNot(SessionHealth.expired));
    });

    test('no stored base URL means nothing to restore', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final fresh = AuthService();
      expect(await fresh.restoreSession(), isFalse);
    });
  });

  group('reactive refresh', () {
    test('a Bearer 401 refreshes once and the request is retried', () async {
      await seedToken(age: const Duration(hours: 1));
      await auth.restoreSession();

      final res = await auth.client!.call('app.ping');

      expect(res, {'message': 'pong'});
      expect(server.count('mobile_auth.refresh_token'), 1);
      expect(server.authHeaders.last, 'Bearer access-2');
    });

    test('concurrent 401s share ONE refresh (single-flight)', () async {
      await seedToken(age: const Duration(hours: 1));
      await auth.restoreSession();
      server.refreshDelay = const Duration(milliseconds: 100);

      final results = await Future.wait([
        auth.client!.call('app.ping'),
        auth.client!.call('app.ping'),
        auth.client!.call('app.ping'),
      ]);

      expect(results, everyElement({'message': 'pong'}));
      expect(server.count('mobile_auth.refresh_token'), 1);
    });
  });

  test('logout clears the token row, the Bearer and the session', () async {
    await auth.login('tester@test.invalid', 'correct-horse');

    await auth.logout(clearDatabase: false);

    expect(auth.isAuthenticated, isFalse);
    expect(await db.authTokenDao.getCurrentToken(), isNull);
    expect(auth.client!.requestHeaders.containsKey('Authorization'), isFalse);
    expect(auth.roles, isEmpty);
  });
}
