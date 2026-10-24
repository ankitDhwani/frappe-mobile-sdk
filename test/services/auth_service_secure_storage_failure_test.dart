// Secure storage can refuse writes: on Android this happens after a backup
// restore or a Keystore reset. Login, refresh and the one-time migration of
// tokens out of the database must keep working when it does, and a token must
// never fall back into the plain SQLite row.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/entities/auth_token_entity.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';

const _accessKey = 'frappe_mobile_access_token';
const _refreshKey = 'frappe_mobile_refresh_token';

int _agedCreatedAt() =>
    DateTime.now().subtract(const Duration(hours: 25)).millisecondsSinceEpoch;

/// Secure storage whose writes throw, the way the Android plugin does after a
/// Keystore reset. Reads and deletes go to the mocked store.
class _RefusingStorage extends FlutterSecureStorage {
  _RefusingStorage({this.failingWrites = -1});

  /// How many writes throw before writes start working; -1 means all of them.
  int failingWrites;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failingWrites != 0) {
      if (failingWrites > 0) failingWrites--;
      throw PlatformException(
        code: 'Exception',
        message: 'BadPaddingException',
      );
    }
    return super.write(key: key, value: value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late Map<String, String> secure;
  late List<String?> authHeaders;

  setUp(() async {
    db = await AppDatabase.inMemoryDatabase();
    secure = <String, String>{'frappe_base_url': 'http://x'};
    FlutterSecureStorage.setMockInitialValues(secure);
    authHeaders = <String?>[];
  });
  tearDown(() async => db.close());

  FrappeClient client() => FrappeClient(
    'http://x',
    httpClient: MockClient((req) async {
      switch (req.url.path) {
        case '/api/method/mobile_auth.login':
          return http.Response(
            jsonEncode({
              'access_token': 'AT-login',
              'refresh_token': 'RT-login',
              'user': 'field@example.org',
              'full_name': 'Field Worker',
            }),
            200,
          );
        case '/api/method/mobile_auth.refresh_token':
          return http.Response(
            jsonEncode({
              'access_token': 'AT-refreshed',
              'refresh_token': 'RT-refreshed',
            }),
            200,
          );
        default:
          authHeaders.add(req.headers['Authorization']);
          return http.Response('{}', 200);
      }
    }),
  );

  Future<void> insertLegacyRow() => db.authTokenDao.insertToken(
    AuthTokenEntity(
      accessToken: 'AT-legacy',
      refreshToken: 'RT-legacy',
      user: 'field@example.org',
      fullName: 'Field Worker',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );

  group('login while secure storage refuses writes', () {
    test('succeeds and the session uses the new token', () async {
      final c = client();
      final auth = AuthService.forTesting(
        c,
        database: db,
        storage: _RefusingStorage(),
      );

      await auth.login('field@example.org', 'pw');

      expect(auth.isAuthenticated, isTrue);
      await c.rest.call('ping');
      expect(authHeaders.last, 'Bearer AT-login');
    });

    test('never falls back to writing the token into the database', () async {
      final auth = AuthService.forTesting(
        client(),
        database: db,
        storage: _RefusingStorage(),
      );

      await auth.login('field@example.org', 'pw');

      final row = await db.authTokenDao.getCurrentToken();
      expect(row, isNotNull);
      expect(row!.accessToken, isEmpty);
      expect(row.refreshToken, isEmpty);
      expect(row.user, 'field@example.org');
      expect(secure.containsKey(_accessKey), isFalse);
      expect(secure.containsKey(_refreshKey), isFalse);
    });

    test('the next cold start asks for a login, and it works again', () async {
      final storage = _RefusingStorage();
      await AuthService.forTesting(
        client(),
        database: db,
        storage: storage,
      ).login('field@example.org', 'pw');

      final c = client();
      final coldStart = AuthService.forTesting(
        c,
        database: db,
        storage: storage,
      );
      expect(await coldStart.restoreSession(isOnline: false), isFalse);

      await coldStart.login('field@example.org', 'pw');
      await c.rest.call('ping');
      expect(authHeaders.last, 'Bearer AT-login');
    });

    test('a write that fails once is retried after a delete', () async {
      final storage = _RefusingStorage(failingWrites: 1);
      await AuthService.forTesting(
        client(),
        database: db,
        storage: storage,
      ).login('field@example.org', 'pw');

      expect(secure[_accessKey], 'AT-login');
      expect(secure[_refreshKey], 'RT-login');
      final c = client();
      final coldStart = AuthService.forTesting(
        c,
        database: db,
        storage: storage,
      );
      expect(await coldStart.restoreSession(isOnline: false), isTrue);
      await c.rest.call('ping');
      expect(authHeaders.last, 'Bearer AT-login');
    });
  });

  test('a refresh while secure storage refuses writes keeps the session, '
      'with no stale pair left in storage', () async {
    await db.authTokenDao.insertToken(
      AuthTokenEntity(
        accessToken: '',
        refreshToken: '',
        user: 'field@example.org',
        createdAt: _agedCreatedAt(),
      ),
    );
    secure[_accessKey] = 'AT-old';
    secure[_refreshKey] = 'RT-old';
    final c = client();
    final auth = AuthService.forTesting(
      c,
      database: db,
      storage: _RefusingStorage(),
    );

    expect(await auth.restoreSession(isOnline: true), isTrue);

    await c.rest.call('ping');
    expect(authHeaders.last, 'Bearer AT-refreshed');
    expect(secure.containsKey(_accessKey), isFalse);
    expect(secure.containsKey(_refreshKey), isFalse);
    final row = await db.authTokenDao.getCurrentToken();
    expect(row!.accessToken, isEmpty);
    expect(row.refreshToken, isEmpty);
  });

  group('migration while secure storage refuses writes', () {
    test('keeps the session on the database copy', () async {
      await insertLegacyRow();
      final c = client();
      final auth = AuthService.forTesting(
        c,
        database: db,
        storage: _RefusingStorage(),
      );

      expect(await auth.restoreSession(isOnline: false), isTrue);

      await c.rest.call('ping');
      expect(authHeaders.last, 'Bearer AT-legacy');
      expect(auth.currentUserInfo?.email, 'field@example.org');
    });

    test('leaves the row intact so no credential is lost', () async {
      await insertLegacyRow();
      final auth = AuthService.forTesting(
        client(),
        database: db,
        storage: _RefusingStorage(),
      );

      await auth.restoreSession(isOnline: false);

      final row = await db.authTokenDao.getCurrentToken();
      expect(row!.accessToken, 'AT-legacy');
      expect(row.refreshToken, 'RT-legacy');
      expect(secure.containsKey(_accessKey), isFalse);
    });

    test('is retried on the next start once storage works', () async {
      await insertLegacyRow();
      await AuthService.forTesting(
        client(),
        database: db,
        storage: _RefusingStorage(),
      ).restoreSession(isOnline: false);

      final c = client();
      final auth = AuthService.forTesting(c, database: db);
      expect(await auth.restoreSession(isOnline: false), isTrue);

      expect(secure[_accessKey], 'AT-legacy');
      expect(secure[_refreshKey], 'RT-legacy');
      final row = await db.authTokenDao.getCurrentToken();
      expect(row!.accessToken, isEmpty);
      expect(row.refreshToken, isEmpty);
      await c.rest.call('ping');
      expect(authHeaders.last, 'Bearer AT-legacy');
    });
  });

  test('logout drops a token held for the session only', () async {
    final auth = AuthService.forTesting(
      client(),
      database: db,
      storage: _RefusingStorage(),
    );
    await auth.login('field@example.org', 'pw');

    await auth.logout(clearDatabase: false);

    expect(auth.isAuthenticated, isFalse);
    expect(await db.authTokenDao.getCurrentToken(), isNull);
    expect(await auth.restoreSession(isOnline: false), isFalse);
  });
}
