// LoginScreen — mobile OTP, OAuth (PKCE) and social-login paths.
//
// app_links and url_launcher are replaced at the platform-interface level so
// the OAuth redirect can be delivered deterministically; AuthService is a
// test double whose client is pre-wired (no secure storage, no network).
import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:app_links_platform_interface/app_links_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/models/app_config.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';
import 'package:frappe_mobile_sdk/src/ui/login_screen.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _FakeAppLinks extends AppLinksPlatform {
  final StreamController<String> links = StreamController<String>.broadcast();

  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Stream<String> get stringLinkStream => links.stream;

  @override
  Stream<Uri> get uriLinkStream => links.stream.map(Uri.parse);
}

class _FakeLauncher extends UrlLauncherPlatform {
  Future<bool> Function(String url) canLaunchImpl = (_) async => true;
  final List<String> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) => canLaunchImpl(url);

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

class _FakeAuth extends AuthService {
  _FakeAuth() : super.forTesting(FrappeClient('https://example.test'));

  final List<Map<String, String?>> oauthCalls = [];
  Object? oauthError;
  bool oauthResult = true;
  List<Map<String, dynamic>> providers = const [];
  final List<String> socialPrepared = [];

  @override
  Future<bool> loginWithOAuth({
    required String code,
    required String codeVerifier,
    required String clientId,
    required String redirectUri,
    String? clientSecret,
  }) async {
    oauthCalls.add({
      'code': code,
      'verifier': codeVerifier,
      'clientId': clientId,
      'redirectUri': redirectUri,
      'secret': clientSecret,
    });
    if (oauthError != null) throw oauthError!;
    return oauthResult;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchSocialLoginProviders() async =>
      providers;

  @override
  Future<Map<String, String>> prepareSocialOAuthLogin({
    required String provider,
    required String clientId,
    required String redirectUri,
    String scope = 'openid all',
    String? state,
  }) async {
    socialPrepared.add(provider);
    return {
      'authorize_url':
          'https://example.test/social?provider=$provider&state=social-state',
      'code_verifier': 'social-verifier',
      'state': 'social-state',
    };
  }
}

AppConfig _config({
  bool password = true,
  bool oauth = false,
  bool social = false,
  bool mobile = false,
  String? clientId,
  String? secret,
  List<SocialProviderConfig> providers = const [],
  bool discover = false,
}) => AppConfig(
  baseUrl: 'https://example.test',
  doctypes: const [],
  loginConfig: LoginConfig(
    enablePasswordLogin: password,
    enableOAuth: oauth,
    enableSocialLogin: social,
    enableMobileLogin: mobile,
    oauthClientId: clientId,
    oauthClientSecret: secret,
    socialProviders: providers,
    autoDiscoverSocialProviders: discover,
  ),
);

class _Otp {
  final List<String> sent = [];
  final List<List<String>> verified = [];
  Map<String, dynamic>? sendResponse = {'tmp_id': 'tmp-1'};
  Object? verifyError;

  Future<Map<String, dynamic>?> send(String mobile) async {
    sent.add(mobile);
    return sendResponse;
  }

  Future<Map<String, dynamic>?> verify(String tmpId, String otp) async {
    verified.add([tmpId, otp]);
    if (verifyError != null) throw verifyError!;
    return {'user': 'u'};
  }
}

Finder _field(String label) => find.widgetWithText(TextFormField, label);

void main() {
  // ONE app-links fake for the whole file: `AppLinks()` is a process-wide
  // singleton that caches its broadcast controller (and the upstream
  // subscription) across tests, so a per-test source stream would be missed
  // by every test after the first that listened.
  final links = _FakeAppLinks();
  late _FakeLauncher launcher;
  late UrlLauncherPlatform originalLauncher;

  StreamSubscription<Uri>? keepAlive;

  setUpAll(() {
    originalLauncher = UrlLauncherPlatform.instance;
    AppLinksPlatform.instance = links;
    // Keep the singleton's controller permanently subscribed (created here,
    // outside any widget-test zone). Otherwise the first screen that cancels
    // leaves the facade holding a half-torn-down controller whose async
    // onCancel never finishes inside the ended FakeAsync zone.
    keepAlive = AppLinks().uriLinkStream.listen((_) {});
  });

  tearDownAll(() async {
    await keepAlive?.cancel();
    await links.links.close();
  });

  setUp(() {
    launcher = _FakeLauncher();
    UrlLauncherPlatform.instance = launcher;
  });

  tearDown(() {
    UrlLauncherPlatform.instance = originalLauncher;
  });

  // The singleton's controller lives outside the widget-test FakeAsync zone,
  // so its hop is a REAL microtask: let the real loop run once, then pump.
  Future<void> deliver(WidgetTester tester, String link) async {
    await tester.runAsync(() async {
      links.links.add(link);
      await Future<void>.delayed(Duration.zero);
    });
  }

  Future<void> pump(
    WidgetTester tester, {
    required AuthService auth,
    required AppConfig config,
    _Otp? otp,
    VoidCallback? onSuccess,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          authService: auth,
          appConfig: config,
          sendLoginOtp: otp?.send,
          verifyLoginOtp: otp?.verify,
          onLoginSuccess: onSuccess,
        ),
      ),
    );
    await tester.pump();
  }

  group('mobile OTP', () {
    testWidgets('expands from the button and collapses back to password', (
      tester,
    ) async {
      await pump(
        tester,
        auth: _FakeAuth(),
        config: _config(mobile: true),
        otp: _Otp(),
      );
      await tester.tap(find.text('Login with mobile'));
      await tester.pump();
      expect(_field('Mobile number'), findsOneWidget);
      expect(_field('Username / Email'), findsNothing);
      expect(find.text('OR'), findsNothing);

      await tester.tap(find.text('Back to password'));
      await tester.pump();
      expect(_field('Username / Email'), findsOneWidget);
      expect(_field('Mobile number'), findsNothing);
    });

    testWidgets('password disabled: OTP section starts expanded, no back', (
      tester,
    ) async {
      await pump(
        tester,
        auth: _FakeAuth(),
        config: _config(password: false, mobile: true),
        otp: _Otp(),
      );
      expect(_field('Mobile number'), findsOneWidget);
      expect(find.text('Back to password'), findsNothing);
      expect(find.text('Send OTP'), findsOneWidget);
    });

    testWidgets('empty mobile number is refused without a call', (
      tester,
    ) async {
      final otp = _Otp();
      await pump(
        tester,
        auth: _FakeAuth(),
        config: _config(password: false, mobile: true),
        otp: otp,
      );
      await tester.enterText(_field('Mobile number'), '   ');
      await tester.tap(find.text('Send OTP'));
      await tester.pump();
      expect(find.text('Enter mobile number'), findsOneWidget);
      expect(otp.sent, isEmpty);
    });

    testWidgets('null send response is reported as a failure', (tester) async {
      final otp = _Otp()..sendResponse = null;
      await pump(
        tester,
        auth: _FakeAuth(),
        config: _config(password: false, mobile: true),
        otp: otp,
      );
      await tester.enterText(_field('Mobile number'), '+15550000000');
      await tester.tap(find.text('Send OTP'));
      await tester.pump();
      expect(find.text('Send OTP failed'), findsOneWidget);
      expect(_field('OTP'), findsNothing);
    });

    testWidgets('response without tmp_id surfaces the server message', (
      tester,
    ) async {
      final otp = _Otp()..sendResponse = {'message': 'Number not registered'};
      await pump(
        tester,
        auth: _FakeAuth(),
        config: _config(password: false, mobile: true),
        otp: otp,
      );
      await tester.enterText(_field('Mobile number'), '+15550000000');
      await tester.tap(find.text('Send OTP'));
      await tester.pump();
      expect(find.text('Number not registered'), findsOneWidget);
    });

    testWidgets('response without tmp_id or message: generic explanation', (
      tester,
    ) async {
      final otp = _Otp()..sendResponse = {'tmp_id': ''};
      await pump(
        tester,
        auth: _FakeAuth(),
        config: _config(password: false, mobile: true),
        otp: otp,
      );
      await tester.enterText(_field('Mobile number'), '+15550000000');
      await tester.tap(find.text('Send OTP'));
      await tester.pump();
      expect(find.text('No tmp_id in response'), findsOneWidget);
    });

    testWidgets('send → verify passes the tmp_id and the OTP', (tester) async {
      final otp = _Otp();
      var success = 0;
      await pump(
        tester,
        auth: _FakeAuth(),
        config: _config(password: false, mobile: true),
        otp: otp,
        onSuccess: () => success++,
      );
      await tester.enterText(_field('Mobile number'), ' +15550000000 ');
      await tester.tap(find.text('Send OTP'));
      await tester.pump();
      expect(otp.sent, ['+15550000000']);
      expect(_field('OTP'), findsOneWidget);
      // The number is locked once an OTP is out.
      final mobile = tester.widget<TextField>(
        find.descendant(
          of: _field('Mobile number'),
          matching: find.byType(TextField),
        ),
      );
      expect(mobile.enabled, isFalse);

      await tester.enterText(_field('OTP'), '123456');
      await tester.tap(find.text('Verify OTP'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(otp.verified, [
        ['tmp-1', '123456'],
      ]);
      expect(success, 1);
    });

    testWidgets('verify failure is shown and the user can retry', (
      tester,
    ) async {
      final otp = _Otp()..verifyError = Exception('Invalid OTP');
      var success = 0;
      await pump(
        tester,
        auth: _FakeAuth(),
        config: _config(password: false, mobile: true),
        otp: otp,
        onSuccess: () => success++,
      );
      await tester.enterText(_field('Mobile number'), '+15550000000');
      await tester.tap(find.text('Send OTP'));
      await tester.pump();
      await tester.enterText(_field('OTP'), '000000');
      await tester.tap(find.text('Verify OTP'));
      await tester.pump();
      expect(find.text('Invalid OTP'), findsOneWidget);
      expect(success, 0);
      final verify = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Verify OTP'),
      );
      expect(verify.onPressed, isNotNull);
    });

    testWidgets('Change number returns to the send step', (tester) async {
      final otp = _Otp();
      await pump(
        tester,
        auth: _FakeAuth(),
        config: _config(password: false, mobile: true),
        otp: otp,
      );
      await tester.enterText(_field('Mobile number'), '+15550000000');
      await tester.tap(find.text('Send OTP'));
      await tester.pump();
      await tester.tap(find.text('Change number'));
      await tester.pump();
      expect(find.text('Send OTP'), findsOneWidget);
      expect(_field('OTP'), findsNothing);
      // After changing number, verifying needs a fresh send.
      expect(find.text('Verify OTP'), findsNothing);
    });

    testWidgets(
      'tapping Verify with an empty OTP tells the user what is missing',
      (tester) async {
        // BUG SDK2-4 (P3): login_screen.dart:456 returns silently when the OTP
        // is empty — no call, no message. The same screen reports the
        // analogous empty-mobile case (:413 "Enter mobile number").
        final otp = _Otp();
        await pump(
          tester,
          auth: _FakeAuth(),
          config: _config(password: false, mobile: true),
          otp: otp,
        );
        await tester.enterText(_field('Mobile number'), '+15550000000');
        await tester.tap(find.text('Send OTP'));
        await tester.pump();
        await tester.tap(find.text('Verify OTP'));
        await tester.pump();
        expect(otp.verified, isEmpty);
        expect(find.byIcon(Icons.error), findsOneWidget);
      },
      skip: true, // BUG SDK2-4: empty OTP no feedback
    );
  });

  group('OAuth', () {
    testWidgets('missing client id is a visible configuration error', (
      tester,
    ) async {
      await pump(tester, auth: _FakeAuth(), config: _config(oauth: true));
      await tester.tap(find.text('Login with OAuth'));
      await tester.pump();
      expect(
        find.text('OAuth is enabled but oauth_client_id is not set in config'),
        findsOneWidget,
      );
      expect(launcher.launched, isEmpty);
    });

    testWidgets('browser unavailable: error, loading cleared', (tester) async {
      launcher.canLaunchImpl = (_) async => false;
      await pump(
        tester,
        auth: _FakeAuth(),
        config: _config(oauth: true, clientId: 'cid'),
      );
      await tester.tap(find.text('Login with OAuth'));
      await tester.pump();
      await tester.pump();
      expect(
        find.text(
          'Cannot open browser. Add https intent to AndroidManifest queries.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Complete login in browser, then return here'),
        findsNothing,
      );
      expect(launcher.launched, isEmpty);
    });

    Future<Uri> startOAuth(WidgetTester tester, _FakeAuth auth) async {
      await pump(
        tester,
        auth: auth,
        config: _config(oauth: true, clientId: 'cid', secret: 'sec'),
      );
      await tester.tap(find.text('Login with OAuth'));
      await tester.pump();
      await tester.pump();
      expect(launcher.launched, hasLength(1));
      return Uri.parse(launcher.launched.single);
    }

    testWidgets('opens a PKCE authorize URL and waits for the redirect', (
      tester,
    ) async {
      final auth = _FakeAuth();
      final url = await startOAuth(tester, auth);
      expect(url.queryParameters['client_id'], 'cid');
      expect(
        url.queryParameters['redirect_uri'],
        'frappemobilesdk://oauth/callback',
      );
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(url.queryParameters['code_challenge'], isNotEmpty);
      expect(url.queryParameters['state'], isNotEmpty);
      expect(
        find.text('Complete login in browser, then return here'),
        findsOneWidget,
      );
      final oauthBtn = tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text('Login with OAuth'),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
      );
      expect(oauthBtn.onPressed, isNull);
    });

    testWidgets('matching redirect exchanges the code and reports success', (
      tester,
    ) async {
      final auth = _FakeAuth();
      var success = 0;
      await pump(
        tester,
        auth: auth,
        config: _config(oauth: true, clientId: 'cid', secret: 'sec'),
        onSuccess: () => success++,
      );
      await tester.tap(find.text('Login with OAuth'));
      await tester.pump();
      await tester.pump();
      final state = Uri.parse(
        launcher.launched.single,
      ).queryParameters['state']!;
      await deliver(
        tester,
        'frappemobilesdk://oauth/callback?code=the-code&state=$state',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(auth.oauthCalls, hasLength(1));
      final call = auth.oauthCalls.single;
      expect(call['code'], 'the-code');
      expect(call['clientId'], 'cid');
      expect(call['secret'], 'sec');
      expect(call['redirectUri'], 'frappemobilesdk://oauth/callback');
      expect(call['verifier'], isNotEmpty);
      expect(success, 1);
    });

    testWidgets('mismatched state is rejected and nothing is exchanged', (
      tester,
    ) async {
      final auth = _FakeAuth();
      await startOAuth(tester, auth);
      await deliver(
        tester,
        'frappemobilesdk://oauth/callback?code=the-code&state=forged',
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('OAuth state mismatch. Please try again.'), findsOne);
      expect(auth.oauthCalls, isEmpty);
    });

    testWidgets(
      'a redirect that DROPS the state parameter is rejected',
      (tester) async {
        // BUG SDK2-5 (P3, spec conformance): login_screen.dart:202-204 only
        // rejects when `incomingState != null && incomingState != _oauthState`,
        // so a callback carrying a code but NO state is still exchanged.
        // RFC 6749 §4.1.2: when the authorization request carried `state`,
        // the redirect MUST carry the identical value, and the client should
        // treat its absence as a failed response. (PKCE S256 still protects
        // the token exchange; this is a conformance gap.)
        final auth = _FakeAuth();
        await startOAuth(tester, auth);
        await deliver(tester, 'frappemobilesdk://oauth/callback?code=injected');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(auth.oauthCalls, isEmpty);
      },
      skip: true, // BUG SDK2-5: missing state accepted
    );

    testWidgets('a redirect to another path is ignored', (tester) async {
      final auth = _FakeAuth();
      await startOAuth(tester, auth);
      await deliver(tester, 'frappemobilesdk://oauth/other?code=c');
      await tester.pump();
      expect(auth.oauthCalls, isEmpty);
      expect(
        find.text('Complete login in browser, then return here'),
        findsOneWidget,
      );
    });

    testWidgets('code exchange failure is shown and loading ends', (
      tester,
    ) async {
      final auth = _FakeAuth()..oauthError = Exception('invalid_grant');
      var success = 0;
      await pump(
        tester,
        auth: auth,
        config: _config(oauth: true, clientId: 'cid'),
        onSuccess: () => success++,
      );
      await tester.tap(find.text('Login with OAuth'));
      await tester.pump();
      await tester.pump();
      final state = Uri.parse(
        launcher.launched.single,
      ).queryParameters['state']!;
      await deliver(
        tester,
        'frappemobilesdk://oauth/callback?code=c&state=$state',
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('invalid_grant'), findsOneWidget);
      expect(
        find.text('Complete login in browser, then return here'),
        findsNothing,
      );
      expect(success, 0);
    });

    testWidgets('exchange returning false does not report success', (
      tester,
    ) async {
      final auth = _FakeAuth()..oauthResult = false;
      var success = 0;
      await pump(
        tester,
        auth: auth,
        config: _config(oauth: true, clientId: 'cid'),
        onSuccess: () => success++,
      );
      await tester.tap(find.text('Login with OAuth'));
      await tester.pump();
      await tester.pump();
      final state = Uri.parse(
        launcher.launched.single,
      ).queryParameters['state']!;
      await deliver(
        tester,
        'frappemobilesdk://oauth/callback?code=c&state=$state',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(auth.oauthCalls, hasLength(1));
      expect(success, 0);
    });

    testWidgets(
      'leaving the screen while the browser check is pending is safe',
      (tester) async {
        // BUG SDK2-6 (P3): _startOAuth awaits canLaunchUrl and then calls
        // setState on the "cannot launch" branch (login_screen.dart:293) and
        // in its catch (:305) without a `mounted` check. _startSocialOAuth
        // guards exactly this (:345, comment "Match _startOAuth") — the
        // original never got the guard. Result: setState() after dispose().
        final gate = Completer<bool>();
        launcher.canLaunchImpl = (_) => gate.future;
        await pump(
          tester,
          auth: _FakeAuth(),
          config: _config(oauth: true, clientId: 'cid'),
        );
        await tester.tap(find.text('Login with OAuth'));
        await tester.pump();
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        gate.complete(false);
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
      skip: true, // BUG SDK2-6: setState after dispose
    );
  });

  group('social login', () {
    testWidgets('configured providers render as Continue-with buttons', (
      tester,
    ) async {
      await pump(
        tester,
        auth: _FakeAuth(),
        config: _config(
          social: true,
          clientId: 'cid',
          providers: const [
            SocialProviderConfig(id: 'google', label: 'Google'),
            SocialProviderConfig(id: 'github', label: 'GitHub', iconUrl: '  '),
          ],
        ),
      );
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Continue with GitHub'), findsOneWidget);
      expect(find.byIcon(Icons.public), findsNWidgets(2));
    });

    testWidgets('auto-discovered providers replace the configured list', (
      tester,
    ) async {
      final auth = _FakeAuth()
        ..providers = [
          {'provider': 'office_365', 'name': 'Office 365'},
          {'provider': '  ', 'name': 'Blank id is dropped'},
        ];
      await pump(
        tester,
        auth: auth,
        config: _config(
          social: true,
          clientId: 'cid',
          discover: true,
          providers: const [
            SocialProviderConfig(id: 'google', label: 'Google'),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('Continue with Office 365'), findsOneWidget);
      expect(find.text('Continue with Google'), findsNothing);
      expect(find.textContaining('Blank id'), findsNothing);
    });

    testWidgets('discovery returning nothing keeps configured providers', (
      tester,
    ) async {
      await pump(
        tester,
        auth: _FakeAuth(),
        config: _config(
          social: true,
          clientId: 'cid',
          discover: true,
          providers: const [
            SocialProviderConfig(id: 'google', label: 'Google'),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('Continue with Google'), findsOneWidget);
    });

    testWidgets('provider tap without client id explains the requirement', (
      tester,
    ) async {
      final auth = _FakeAuth();
      await pump(
        tester,
        auth: auth,
        config: _config(
          social: true,
          providers: const [
            SocialProviderConfig(id: 'google', label: 'Google'),
          ],
        ),
      );
      await tester.tap(find.text('Continue with Google'));
      await tester.pump();
      expect(
        find.text(
          'OAuth is required for social login. Set oauth_client_id in config.',
        ),
        findsOneWidget,
      );
      expect(auth.socialPrepared, isEmpty);
    });

    testWidgets('provider tap launches that provider and completes login', (
      tester,
    ) async {
      final auth = _FakeAuth();
      var success = 0;
      await pump(
        tester,
        auth: auth,
        config: _config(
          social: true,
          clientId: 'cid',
          providers: const [
            SocialProviderConfig(id: 'google', label: 'Google'),
          ],
        ),
        onSuccess: () => success++,
      );
      await tester.tap(find.text('Continue with Google'));
      await tester.pump();
      await tester.pump();
      expect(auth.socialPrepared, ['google']);
      expect(launcher.launched.single, contains('provider=google'));

      await deliver(
        tester,
        'frappemobilesdk://oauth/callback?code=sc&state=social-state',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(auth.oauthCalls.single['verifier'], 'social-verifier');
      expect(auth.oauthCalls.single['code'], 'sc');
      expect(success, 1);
    });

    testWidgets('provider browser unavailable: error shown', (tester) async {
      launcher.canLaunchImpl = (_) async => false;
      await pump(
        tester,
        auth: _FakeAuth(),
        config: _config(
          social: true,
          clientId: 'cid',
          providers: const [
            SocialProviderConfig(id: 'google', label: 'Google'),
          ],
        ),
      );
      await tester.tap(find.text('Continue with Google'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Cannot open browser'), findsOneWidget);
      expect(launcher.launched, isEmpty);
    });
  });
}
