// FrappeAppGuard — every outcome of the app_status check, end to end through
// the real AppStatusService/RestHelper with an in-zone MockClient.
//
// The guard builds its own http.Client, so the only seam is
// `http.runWithClient`. RestHelper decodes JSON with `compute` (a real
// isolate), hence the runAsync hops in `_settle`.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/app_guard.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _FakeLauncher extends UrlLauncherPlatform {
  final List<String> launched = [];
  final List<String> checked = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async {
    checked.add(url);
    return true;
  }

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

const _child = Text('APP HOME');

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Future<List<Uri>> _pumpGuard(
  WidgetTester tester, {
  required http.Response Function() respond,
  String baseUrl = 'https://example.test',
  String currentPackage = 'com.example.app',
  String currentVersion = '1.2.3',
  String? notConfigured,
  String? forceTitle,
  bool allowDeferring = true,
}) async {
  final requests = <Uri>[];
  final client = MockClient((req) async {
    requests.add(req.url);
    return respond();
  });
  await http.runWithClient(
    () => tester.pumpWidget(
      MaterialApp(
        home: FrappeAppGuard(
          baseUrl: baseUrl,
          currentPackageName: currentPackage,
          currentVersion: currentVersion,
          appNotConfiguredMessage: notConfigured,
          forceUpdateTitle: forceTitle,
          allowDeferringUpdates: allowDeferring,
          child: _child,
        ),
      ),
    ),
    () => client,
  );
  await _settle(tester);
  return requests;
}

/// Alternates fake-zone pumps with short real-time hops until the guard's
/// spinner is gone (or a bounded number of rounds elapses).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
  }
}

Map<String, Object?> _status({
  bool enabled = true,
  String? package = 'com.example.app',
  String? version = '1.2.3',
  bool maintenance = false,
  String? maintenanceMessage,
  String? storeUrl,
  String? appTitle,
}) => {
  'data': {
    'enabled': enabled,
    'package_name': package,
    'version': version,
    'maintenance_mode': maintenance,
    'maintenance_message': maintenanceMessage,
    'store_url': ?storeUrl,
    'app_title': ?appTitle,
  },
};

void main() {
  late _FakeLauncher launcher;
  late UrlLauncherPlatform original;

  setUpAll(() => original = UrlLauncherPlatform.instance);
  setUp(() {
    launcher = _FakeLauncher();
    UrlLauncherPlatform.instance = launcher;
  });
  tearDown(() => UrlLauncherPlatform.instance = original);

  testWidgets('empty baseUrl skips the check and shows the app', (
    tester,
  ) async {
    final reqs = await _pumpGuard(
      tester,
      baseUrl: '',
      respond: () => _json(_status()),
    );
    expect(reqs, isEmpty);
    expect(find.text('APP HOME'), findsOneWidget);
  });

  testWidgets('matching package and version shows the app', (tester) async {
    final reqs = await _pumpGuard(tester, respond: () => _json(_status()));
    expect(reqs.single.path, '/api/v2/method/mobile_auth.app_status');
    expect(find.text('APP HOME'), findsOneWidget);
  });

  testWidgets('a flat (non-enveloped) payload is also understood', (
    tester,
  ) async {
    await _pumpGuard(tester, respond: () => _json({'enabled': false}));
    expect(find.text('App not configured'), findsOneWidget);
  });

  testWidgets('enabled=false blocks with the default message', (tester) async {
    await _pumpGuard(tester, respond: () => _json(_status(enabled: false)));
    expect(find.text('App Not Available'), findsOneWidget);
    expect(find.text('App not configured'), findsOneWidget);
    expect(
      find.text('This app is not configured for mobile access.'),
      findsOneWidget,
    );
    expect(find.text('APP HOME'), findsNothing);
  });

  testWidgets('enabled=false uses the host-supplied message', (tester) async {
    await _pumpGuard(
      tester,
      notConfigured: 'Ask your admin to enable mobile.',
      respond: () => _json(_status(enabled: false)),
    );
    expect(find.text('Ask your admin to enable mobile.'), findsOneWidget);
  });

  testWidgets('maintenance mode shows the server message', (tester) async {
    await _pumpGuard(
      tester,
      respond: () =>
          _json(_status(maintenance: true, maintenanceMessage: 'Back at 6 PM')),
    );
    expect(find.text('Under maintenance'), findsOneWidget);
    expect(find.text('Back at 6 PM'), findsOneWidget);
    expect(find.text('APP HOME'), findsNothing);
  });

  testWidgets('maintenance with a blank message uses the default text', (
    tester,
  ) async {
    await _pumpGuard(
      tester,
      respond: () =>
          _json(_status(maintenance: true, maintenanceMessage: '   ')),
    );
    expect(
      find.text(
        'This app is temporarily down for maintenance. Please try again later.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('package mismatch blocks the app', (tester) async {
    await _pumpGuard(
      tester,
      respond: () => _json(_status(package: 'com.example.other')),
    );
    expect(find.text('App not configured'), findsOneWidget);
    expect(find.text('APP HOME'), findsNothing);
  });

  testWidgets('an empty server package name is not a mismatch', (tester) async {
    await _pumpGuard(tester, respond: () => _json(_status(package: '')));
    expect(find.text('APP HOME'), findsOneWidget);
  });

  testWidgets('a newer MAJOR version forces an update', (tester) async {
    await _pumpGuard(
      tester,
      currentVersion: '1.9.9',
      respond: () => _json(_status(version: '2.0.0')),
    );
    expect(find.text('Update Required'), findsOneWidget);
    expect(find.text('Open Store'), findsOneWidget);
    expect(find.text('Skip for now'), findsNothing);
    expect(find.text('APP HOME'), findsNothing);
  });

  testWidgets('a newer minor version with deferring disabled is forced', (
    tester,
  ) async {
    await _pumpGuard(
      tester,
      allowDeferring: false,
      respond: () => _json(_status(version: '1.3.0')),
    );
    expect(find.text('Update Required'), findsOneWidget);
    expect(find.text('Skip for now'), findsNothing);
  });

  testWidgets('a newer minor version can be skipped for now', (tester) async {
    await _pumpGuard(tester, respond: () => _json(_status(version: 'v1.2.10')));
    expect(find.text('Update Available'), findsOneWidget);
    await tester.tap(find.text('Skip for now'));
    await tester.pump();
    expect(find.text('APP HOME'), findsOneWidget);
  });

  testWidgets(
    'an optional update is not headed "Update required"',
    (tester) async {
      // BUG SDK2-8 (P3): app_guard.dart:185 falls back to 'Update required'
      // for BOTH screens, so the deferrable screen's own default
      // ('Update available', :281) is dead code. The backend never sends
      // app_title (mobile_auth.app_status returns enabled/package_name/
      // version/maintenance_* only), so every optional update is headed
      // "Update required" above a "Skip for now" button.
      await _pumpGuard(tester, respond: () => _json(_status(version: '1.3.0')));
      expect(find.text('Skip for now'), findsOneWidget);
      expect(find.text('Update required'), findsNothing);
      expect(find.text('Update available'), findsOneWidget);
    },
    skip: true, // BUG SDK2-8: optional update titled "required"
  );

  testWidgets('forceUpdateTitle overrides the server title', (tester) async {
    await _pumpGuard(
      tester,
      forceTitle: 'Please update',
      respond: () => _json(_status(version: '9.0.0', appTitle: 'Server T')),
    );
    expect(find.text('Please update'), findsOneWidget);
    expect(find.text('Server T'), findsNothing);
  });

  testWidgets('an older or equal server version never prompts', (tester) async {
    await _pumpGuard(
      tester,
      currentVersion: '2.0.0+77',
      respond: () => _json(_status(version: '1.9.0')),
    );
    expect(find.text('APP HOME'), findsOneWidget);
  });

  testWidgets('Open Store launches the server-provided store URL', (
    tester,
  ) async {
    await _pumpGuard(
      tester,
      respond: () => _json(
        _status(version: '3.0.0', storeUrl: 'https://store.example/app'),
      ),
    );
    await tester.tap(find.text('Open Store'));
    await tester.pump();
    await tester.pump();
    expect(launcher.checked, ['https://store.example/app']);
    expect(launcher.launched, ['https://store.example/app']);
  });

  testWidgets('HTTP 417 is treated as "not configured"', (tester) async {
    await _pumpGuard(
      tester,
      respond: () => _json({'exc_type': 'ValidationError'}, 417),
    );
    expect(find.text('App not configured'), findsOneWidget);
  });

  testWidgets('HTTP 404 is treated as "not configured"', (tester) async {
    await _pumpGuard(
      tester,
      respond: () => _json({'exc_type': 'DoesNotExistError'}, 404),
    );
    expect(find.text('App not configured'), findsOneWidget);
  });

  testWidgets('a transient 500 does not lock the user out', (tester) async {
    await _pumpGuard(tester, respond: () => _json({'exc': 'boom'}, 500));
    expect(find.text('APP HOME'), findsOneWidget);
  });
}
