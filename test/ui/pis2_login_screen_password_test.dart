// LoginScreen — password path, validation, error surfacing, base-URL input,
// autoLogin, and which login methods are offered.
//
// The screen is driven through its public callbacks (`passwordLogin`) and a
// test double of AuthService whose client is pre-wired, so no secure-storage
// or network call is ever made.
import 'dart:async';

import 'package:app_links_platform_interface/app_links_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/app_config.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';
import 'package:frappe_mobile_sdk/src/ui/login_screen.dart';
import 'package:frappe_mobile_sdk/src/ui/login_screen_style.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeAppLinks extends AppLinksPlatform {
  Uri? initial;
  Object? initialError;
  final StreamController<String> links = StreamController<String>.broadcast();

  @override
  Future<Uri?> getInitialLink() async {
    if (initialError != null) throw initialError!;
    return initial;
  }

  @override
  Stream<String> get stringLinkStream => links.stream;

  @override
  Stream<Uri> get uriLinkStream => links.stream.map(Uri.parse);
}

class _FakeAuth extends AuthService {
  _FakeAuth() : super.forTesting(FrappeClient('https://example.test'));

  final List<List<String>> loginCalls = [];
  Future<Map<String, dynamic>> Function(String, String)? onLogin;

  @override
  Future<Map<String, dynamic>> login(String username, String password) {
    loginCalls.add([username, password]);
    return onLogin?.call(username, password) ??
        Future.value(<String, dynamic>{'user': username});
  }

  @override
  Future<List<Map<String, dynamic>>> fetchSocialLoginProviders() async =>
      const [];
}

AppConfig _config({
  bool password = true,
  bool oauth = false,
  bool social = false,
  bool mobile = false,
  String? clientId,
}) => AppConfig(
  baseUrl: 'https://example.test',
  doctypes: const [],
  loginConfig: LoginConfig(
    enablePasswordLogin: password,
    enableOAuth: oauth,
    enableSocialLogin: social,
    enableMobileLogin: mobile,
    oauthClientId: clientId,
    autoDiscoverSocialProviders: false,
  ),
);

class _Recorder {
  final List<List<String>> calls = [];
  int successes = 0;
  Object? throwThis;
  Completer<Map<String, dynamic>?>? pending;

  Future<Map<String, dynamic>?> login(String u, String p) async {
    calls.add([u, p]);
    if (pending != null) return pending!.future;
    if (throwThis != null) throw throwThis!;
    return <String, dynamic>{'user': u};
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required AuthService auth,
  AppConfig? config,
  String? initialBaseUrl,
  _Recorder? recorder,
  VoidCallback? onSuccess,
  AppDatabase? database,
  String? initialUsername,
  String? initialPassword,
  bool autoLogin = false,
  LoginScreenStyle? style,
  Future<Map<String, dynamic>?> Function(String)? sendOtp,
  Future<Map<String, dynamic>?> Function(String, String)? verifyOtp,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: LoginScreen(
        authService: auth,
        appConfig: config,
        initialBaseUrl: initialBaseUrl,
        passwordLogin: recorder?.login,
        onLoginSuccess: onSuccess,
        database: database,
        initialUsername: initialUsername,
        initialPassword: initialPassword,
        autoLogin: autoLogin,
        style: style,
        sendLoginOtp: sendOtp,
        verifyLoginOtp: verifyOtp,
      ),
    ),
  );
  await tester.pump();
}

Finder _field(String label) => find.widgetWithText(TextFormField, label);

Future<void> _tapLogin(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ElevatedButton, 'Login'));
  await tester.pump();
}

void main() {
  late _FakeAppLinks links;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    links = _FakeAppLinks();
    AppLinksPlatform.instance = links;
  });

  tearDown(() async {
    await links.links.close();
  });

  group('which login methods are offered', () {
    testWidgets('no method enabled shows the configuration notice only', (
      tester,
    ) async {
      await _pump(tester, auth: _FakeAuth(), config: _config(password: false));
      expect(
        find.text(
          'No login methods enabled. Configure login_config in AppConfig.',
        ),
        findsOneWidget,
      );
      expect(find.byType(TextFormField), findsNothing);
    });

    testWidgets(
      'mobile login enabled without OTP callbacks is not a usable method',
      (tester) async {
        await _pump(
          tester,
          auth: _FakeAuth(),
          config: _config(password: false, mobile: true),
        );
        expect(find.textContaining('No login methods enabled'), findsOneWidget);
      },
    );

    testWidgets('password only: no OR divider, no mobile button', (
      tester,
    ) async {
      await _pump(tester, auth: _FakeAuth(), config: _config());
      expect(_field('Username / Email'), findsOneWidget);
      expect(_field('Password'), findsOneWidget);
      expect(find.text('OR'), findsNothing);
      expect(find.text('Login with mobile'), findsNothing);
      expect(find.text('Login with OAuth'), findsNothing);
    });

    testWidgets('password + mobile OTP shows the OR divider', (tester) async {
      await _pump(
        tester,
        auth: _FakeAuth(),
        config: _config(mobile: true),
        sendOtp: (_) async => {'tmp_id': 't'},
        verifyOtp: (_, _) async => {},
      );
      expect(find.text('OR'), findsOneWidget);
      expect(find.text('Login with mobile'), findsOneWidget);
    });

    testWidgets('password + OAuth shows OR divider and OAuth button', (
      tester,
    ) async {
      await _pump(
        tester,
        auth: _FakeAuth(),
        config: _config(oauth: true, clientId: 'cid'),
      );
      expect(find.text('OR'), findsOneWidget);
      expect(find.text('Login with OAuth'), findsOneWidget);
    });

    testWidgets('custom style overrides the icon size and title style', (
      tester,
    ) async {
      await _pump(
        tester,
        auth: _FakeAuth(),
        config: _config(),
        style: const LoginScreenStyle(
          iconSize: 33,
          titleStyle: TextStyle(fontSize: 11),
        ),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.login).first);
      expect(icon.size, 33);
      final title = tester.widget<Text>(find.text('Login to Frappe'));
      expect(title.style?.fontSize, 11);
    });
  });

  group('validation', () {
    testWidgets('empty username and password are rejected before any call', (
      tester,
    ) async {
      final rec = _Recorder();
      await _pump(tester, auth: _FakeAuth(), config: _config(), recorder: rec);
      await _tapLogin(tester);
      expect(find.text('Please enter username'), findsOneWidget);
      expect(find.text('Please enter password'), findsOneWidget);
      expect(rec.calls, isEmpty);
    });

    testWidgets(
      'whitespace-only username is rejected (it is trimmed to "" before send)',
      (tester) async {
        // BUG SDK2-1 (P3): login_screen.dart:575 validates `value.isEmpty`
        // but :376 sends `text.trim()`, so "   " passes validation and an
        // EMPTY username is sent to the server. Basis: the same file's
        // autoLogin guard (:141) treats a blank-after-trim username as absent.
        final rec = _Recorder();
        await _pump(
          tester,
          auth: _FakeAuth(),
          config: _config(),
          recorder: rec,
        );
        await tester.enterText(_field('Username / Email'), '   ');
        await tester.enterText(_field('Password'), 'secret');
        await _tapLogin(tester);
        expect(rec.calls, isEmpty);
        expect(find.text('Please enter username'), findsOneWidget);
      },
      skip: true, // BUG SDK2-1: blank username accepted
    );

    testWidgets('base URL input appears only without config or initial URL', (
      tester,
    ) async {
      final rec = _Recorder();
      await _pump(tester, auth: _FakeAuth(), recorder: rec);
      expect(_field('Base URL'), findsOneWidget);

      await tester.enterText(_field('Username / Email'), 'u');
      await tester.enterText(_field('Password'), 'p');
      await _tapLogin(tester);
      expect(find.text('Please enter base URL'), findsOneWidget);

      await tester.enterText(_field('Base URL'), 'not a url');
      await _tapLogin(tester);
      expect(find.text('Please enter a valid URL'), findsOneWidget);
      expect(rec.calls, isEmpty);

      await tester.enterText(_field('Base URL'), 'https://example.test');
      await _tapLogin(tester);
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Please enter a valid URL'), findsNothing);
      expect(rec.calls, [
        ['u', 'p'],
      ]);
    });

    testWidgets('initialBaseUrl hides the base URL input', (tester) async {
      await _pump(
        tester,
        auth: _FakeAuth(),
        initialBaseUrl: 'https://example.test',
      );
      expect(_field('Base URL'), findsNothing);
      expect(_field('Username / Email'), findsOneWidget);
    });
  });

  group('password login', () {
    testWidgets(
      'trims the username, keeps the password verbatim, reports success',
      (tester) async {
        final rec = _Recorder();
        var success = 0;
        await _pump(
          tester,
          auth: _FakeAuth(),
          config: _config(),
          recorder: rec,
          onSuccess: () => success++,
        );
        await tester.enterText(_field('Username / Email'), '  user@x.test ');
        await tester.enterText(_field('Password'), ' p w ');
        await _tapLogin(tester);
        await tester.pump(const Duration(milliseconds: 150));
        expect(rec.calls, [
          ['user@x.test', ' p w '],
        ]);
        expect(success, 1);
      },
    );

    testWidgets('while pending the button is disabled and shows a spinner', (
      tester,
    ) async {
      final rec = _Recorder()..pending = Completer();
      var success = 0;
      await _pump(
        tester,
        auth: _FakeAuth(),
        config: _config(),
        recorder: rec,
        onSuccess: () => success++,
      );
      await tester.enterText(_field('Username / Email'), 'u');
      await tester.enterText(_field('Password'), 'p');
      await _tapLogin(tester);

      final btn = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(btn.onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(success, 0);

      rec.pending!.complete({'user': 'u'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(success, 1);
    });

    testWidgets('plain Exception message is shown without the prefix', (
      tester,
    ) async {
      final rec = _Recorder()..throwThis = Exception('Server said no');
      var success = 0;
      await _pump(
        tester,
        auth: _FakeAuth(),
        config: _config(),
        recorder: rec,
        onSuccess: () => success++,
      );
      await tester.enterText(_field('Username / Email'), 'u');
      await tester.enterText(_field('Password'), 'p');
      await _tapLogin(tester);
      await tester.pump();
      expect(find.text('Server said no'), findsOneWidget);
      expect(find.byIcon(Icons.error), findsOneWidget);
      expect(success, 0);
      // Button is usable again after the failure.
      final btn = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(btn.onPressed, isNotNull);
    });

    testWidgets(
      'an AuthException (wrong password) is shown as a readable message',
      (tester) async {
        // BUG SDK2-2 (P2): login_screen.dart:403 (also :241 :306 :362 :447
        // :473) strips the substring "Exception: " from e.toString().
        // AuthException.toString() is "AuthException: <msg> (Status: 401)"
        // (api/exceptions.dart:27), so the user reads
        // "AuthInvalid login credentials (Status: 401)" — the class name is
        // glued onto the message. AuthService.login rethrows exactly this
        // type on a 401 (auth_service.dart:299).
        final rec = _Recorder()
          ..throwThis = AuthException('Invalid login credentials', 401);
        await _pump(
          tester,
          auth: _FakeAuth(),
          config: _config(),
          recorder: rec,
        );
        await tester.enterText(_field('Username / Email'), 'u');
        await tester.enterText(_field('Password'), 'p');
        await _tapLogin(tester);
        await tester.pump();
        expect(
          find.textContaining('Invalid login credentials'),
          findsOneWidget,
        );
        expect(find.textContaining('AuthInvalid'), findsNothing);
      },
      skip: true, // BUG SDK2-2: error text mangled
    );

    testWidgets(
      'a NetworkException is shown as a readable message',
      (tester) async {
        // BUG SDK2-2: same root cause — NetworkException.toString() is
        // "NetworkException: <msg>" (exceptions.dart:43) → "Network<msg>".
        final rec = _Recorder()
          ..throwThis = NetworkException('No internet connection');
        await _pump(
          tester,
          auth: _FakeAuth(),
          config: _config(),
          recorder: rec,
        );
        await tester.enterText(_field('Username / Email'), 'u');
        await tester.enterText(_field('Password'), 'p');
        await _tapLogin(tester);
        await tester.pump();
        expect(find.text('No internet connection'), findsOneWidget);
      },
      skip: true, // BUG SDK2-2: error text mangled
    );

    testWidgets(
      'password login in progress never shows the browser hand-off message',
      (tester) async {
        // BUG SDK2-3 (P3): login_screen.dart:814 renders "Complete login in
        // browser, then return here" whenever `_isLoading && _enableOAuth` —
        // so a plain PASSWORD login on a site that also enables OAuth tells the
        // user to go to a browser that was never opened; the Login button
        // (:610) also drops its own spinner in that configuration.
        final rec = _Recorder()..pending = Completer();
        await _pump(
          tester,
          auth: _FakeAuth(),
          config: _config(oauth: true, clientId: 'cid'),
          recorder: rec,
        );
        await tester.enterText(_field('Username / Email'), 'u');
        await tester.enterText(_field('Password'), 'p');
        await _tapLogin(tester);
        expect(rec.calls, hasLength(1));
        expect(
          find.text('Complete login in browser, then return here'),
          findsNothing,
        );
        rec.pending!.complete({'user': 'u'});
        await tester.pump(const Duration(milliseconds: 150));
      },
      skip: true, // BUG SDK2-3: wrong browser message
    );

    testWidgets('without passwordLogin and without database: explains why', (
      tester,
    ) async {
      final auth = _FakeAuth();
      await _pump(tester, auth: auth, config: _config());
      await tester.enterText(_field('Username / Email'), 'u');
      await tester.enterText(_field('Password'), 'p');
      await _tapLogin(tester);
      await tester.pump();
      expect(
        find.text(
          'Database not set. LoginScreen requires database for stateless login.',
        ),
        findsOneWidget,
      );
      expect(auth.loginCalls, isEmpty);
    });

    testWidgets('without passwordLogin but with database: AuthService.login', (
      tester,
    ) async {
      final db = (await tester.runAsync(AppDatabase.inMemoryDatabase))!;
      addTearDown(() => tester.runAsync(db.close));
      final auth = _FakeAuth();
      var success = 0;
      await _pump(
        tester,
        auth: auth,
        config: _config(),
        database: db,
        onSuccess: () => success++,
      );
      await tester.enterText(_field('Username / Email'), ' u ');
      await tester.enterText(_field('Password'), 'p');
      await _tapLogin(tester);
      await tester.pump(const Duration(milliseconds: 150));
      expect(auth.loginCalls, [
        ['u', 'p'],
      ]);
      expect(success, 1);
    });
  });

  group('autoLogin', () {
    testWidgets('logs in once after the first frame with pre-filled values', (
      tester,
    ) async {
      final rec = _Recorder();
      var success = 0;
      await _pump(
        tester,
        auth: _FakeAuth(),
        config: _config(),
        recorder: rec,
        initialUsername: 'demo@x.test',
        initialPassword: 'pw',
        autoLogin: true,
        onSuccess: () => success++,
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(rec.calls, [
        ['demo@x.test', 'pw'],
      ]);
      expect(success, 1);
    });

    testWidgets('does not fire for a blank username or empty password', (
      tester,
    ) async {
      final rec = _Recorder();
      await _pump(
        tester,
        auth: _FakeAuth(),
        config: _config(),
        recorder: rec,
        initialUsername: '  ',
        initialPassword: 'pw',
        autoLogin: true,
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(rec.calls, isEmpty);
      // Pre-fill still happens even though auto-login is suppressed.
      expect(find.text('pw'), findsOneWidget);
    });
  });

  group('initial deep link', () {
    testWidgets('a non-OAuth initial link is ignored', (tester) async {
      links.initial = Uri.parse('https://example.test/some/page?code=abc');
      await _pump(tester, auth: _FakeAuth(), config: _config());
      await tester.pump();
      expect(find.byIcon(Icons.error), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets(
      'an OAuth callback with no login in flight (no verifier) is ignored',
      (tester) async {
        links.initial = Uri.parse(
          'frappemobilesdk://oauth/callback?code=abc&state=s',
        );
        await _pump(
          tester,
          auth: _FakeAuth(),
          config: _config(oauth: true, clientId: 'cid'),
        );
        await tester.pump();
        expect(find.byIcon(Icons.error), findsNothing);
        expect(
          find.text('Complete login in browser, then return here'),
          findsNothing,
        );
      },
    );

    testWidgets('a failing getInitialLink does not break the screen', (
      tester,
    ) async {
      links.initialError = StateError('no channel');
      await _pump(tester, auth: _FakeAuth(), config: _config());
      await tester.pump();
      expect(_field('Username / Email'), findsOneWidget);
    });
  });
}
