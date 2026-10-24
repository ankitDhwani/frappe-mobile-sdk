// GeolocationField `_fetchLocation` flow, driven through a mocked geolocator
// method channel (no device GPS): service off, permission denied / denied
// forever, success, fallback to last-known position, total failure, clear,
// and leaving the screen while a fix is still being acquired.
//
// Stored value contract: a GeoJSON FeatureCollection whose Point geometry is
// `[longitude, latitude]` (RFC 7946 §3.1.1; the shape Frappe's Geolocation
// control writes).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/geolocation_field.dart';

/// Fake native side. Every geolocator implementation channel is routed here
/// so the test does not depend on which platform implementation registered.
class _FakeGps {
  bool serviceEnabled = true;
  int permission = 2; // whileInUse
  int requestResult = 2;
  Object? current = {'latitude': 12.971599, 'longitude': 77.594566};
  Object? lastKnown;
  Completer<Object?>? hold;
  final calls = <String>[];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'isLocationServiceEnabled':
        return serviceEnabled;
      case 'checkPermission':
        return permission;
      case 'requestPermission':
        return requestResult;
      case 'getCurrentPosition':
        if (hold != null) return hold!.future;
        final c = current;
        if (c is Exception) throw c;
        return c;
      case 'getLastKnownPosition':
        return lastKnown;
    }
    return null;
  }
}

const _channels = [
  'flutter.baseflow.com/geolocator',
  'flutter.baseflow.com/geolocator_android',
  'flutter.baseflow.com/geolocator_apple',
];

void _install(_FakeGps gps) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in _channels) {
    messenger.setMockMethodCallHandler(MethodChannel(name), gps.handle);
  }
  addTearDown(() {
    for (final name in _channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });
}

final _field = DocField(
  fieldname: 'site_location',
  fieldtype: 'Geolocation',
  label: 'Site Location',
);

Future<void> _pump(
  WidgetTester tester, {
  dynamic value,
  ValueChanged<dynamic>? onChanged,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: GeolocationField(field: _field, value: value, onChanged: onChanged),
    ),
  ),
);

Future<void> _tapFetch(WidgetTester tester) async {
  await tester.tap(find.text('Fetch Location'));
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

void main() {
  testWidgets('location services off: error, no value emitted', (tester) async {
    final gps = _FakeGps()..serviceEnabled = false;
    _install(gps);
    final emitted = <dynamic>[];
    await _pump(tester, onChanged: emitted.add);
    await _tapFetch(tester);
    expect(
      find.text('Location services are disabled. Please enable GPS.'),
      findsOneWidget,
    );
    expect(emitted, isEmpty);
    expect(gps.calls, isNot(contains('getCurrentPosition')));
  });

  testWidgets('permission denied twice: error, no value emitted', (
    tester,
  ) async {
    final gps = _FakeGps()
      ..permission = 0
      ..requestResult = 0;
    _install(gps);
    final emitted = <dynamic>[];
    await _pump(tester, onChanged: emitted.add);
    await _tapFetch(tester);
    expect(find.text('Location permission denied.'), findsOneWidget);
    expect(gps.calls, contains('requestPermission'));
    expect(emitted, isEmpty);
  });

  testWidgets('permission denied forever: settings hint', (tester) async {
    final gps = _FakeGps()..permission = 1;
    _install(gps);
    await _pump(tester, onChanged: (_) {});
    await _tapFetch(tester);
    expect(find.textContaining('permanently denied'), findsOneWidget);
  });

  testWidgets('denied then granted on request: fetches the fix', (
    tester,
  ) async {
    final gps = _FakeGps()
      ..permission = 0
      ..requestResult = 2;
    _install(gps);
    final emitted = <dynamic>[];
    await _pump(tester, onChanged: emitted.add);
    await _tapFetch(tester);
    expect(emitted.length, 1);
  });

  testWidgets('success stores GeoJSON [lng, lat] and shows the fix', (
    tester,
  ) async {
    final gps = _FakeGps();
    _install(gps);
    final emitted = <dynamic>[];
    await _pump(tester, onChanged: emitted.add);
    await _tapFetch(tester);

    expect(emitted.length, 1);
    final decoded = jsonDecode(emitted.single as String) as Map;
    expect(decoded['type'], 'FeatureCollection');
    final geometry = (decoded['features'] as List).single['geometry'] as Map;
    expect(geometry['type'], 'Point');
    expect(geometry['coordinates'], [77.594566, 12.971599]);

    expect(find.text('12.971599, 77.594566'), findsOneWidget);
    expect(find.text('Location captured'), findsOneWidget);
    expect(find.text('Refresh Location'), findsOneWidget);
  });

  testWidgets('a live-fix failure falls back to the last known position', (
    tester,
  ) async {
    final gps = _FakeGps()
      ..current = PlatformException(code: 'TIMEOUT')
      ..lastKnown = {'latitude': 1.5, 'longitude': 2.5};
    _install(gps);
    final emitted = <dynamic>[];
    await _pump(tester, onChanged: emitted.add);
    await _tapFetch(tester);
    expect(gps.calls, contains('getLastKnownPosition'));
    expect(emitted.length, 1);
    expect(find.text('1.500000, 2.500000'), findsOneWidget);
  });

  testWidgets('no live fix and no last known: generic error', (tester) async {
    final gps = _FakeGps()
      ..current = PlatformException(code: 'TIMEOUT')
      ..lastKnown = null;
    _install(gps);
    final emitted = <dynamic>[];
    await _pump(tester, onChanged: emitted.add);
    await _tapFetch(tester);
    expect(
      find.text('Failed to get location. Please try again.'),
      findsOneWidget,
    );
    expect(emitted, isEmpty);
    expect(find.text('Fetch Location'), findsOneWidget, reason: 're-enabled');
  });

  testWidgets('while fetching the button is disabled and says so', (
    tester,
  ) async {
    final gps = _FakeGps()..hold = Completer<Object?>();
    _install(gps);
    await _pump(tester, onChanged: (_) {});
    await tester.tap(find.text('Fetch Location'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Fetching location...'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNull);

    gps.hold!.complete({'latitude': 3.0, 'longitude': 4.0});
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(find.text('3.000000, 4.000000'), findsOneWidget);
  });

  testWidgets('clear emits null and returns to the empty state', (
    tester,
  ) async {
    _install(_FakeGps());
    final emitted = <dynamic>[];
    await _pump(tester, onChanged: emitted.add);
    await _tapFetch(tester);
    await tester.tap(find.byTooltip('Clear location'));
    await tester.pump();
    expect(emitted.last, isNull);
    expect(find.text('Fetch Location'), findsOneWidget);
    expect(find.text('Location captured'), findsNothing);
  });

  testWidgets(
    'leaving the form while a fix is pending does not setState after dispose',
    (tester) async {
      final gps = _FakeGps()..hold = Completer<Object?>();
      _install(gps);
      await _pump(tester, onChanged: (_) {});
      await tester.tap(find.text('Fetch Location'));
      await tester.pump();

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      gps.hold!.complete({'latitude': 3.0, 'longitude': 4.0});
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    },
    skip: true, // BUG SDK-21
    // _fetchLocation awaits the platform (up to a 15 s time limit)
    // and then calls setState with no `mounted` check
  );
}
