import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// B1(r2) — the hook has to be reachable from the layer a HOST uses.
///
/// Round 1 wired `onResolvedExisting` to `DocumentService`, round 2 to
/// `FrappeClient`; both were pinned by tests that constructed those layers
/// directly, and both times the production value stayed null. The reason is
/// that a host never builds either one: `FrappeSDK` builds `AuthService`, and
/// `AuthService.initialize()` — the statement after its constructor — is what
/// builds `FrappeClient`. `sdk.auth` does not exist until that has already
/// handed the null down.
///
/// So this file deliberately starts at [FrappeSDK]. A test one layer lower
/// cannot fail when the wiring stops one layer higher, which is exactly what
/// happened twice.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('FrappeSDK threads onResolvedExisting down to createDocument', () async {
    final reported = <String>[];
    final db = await AppDatabase.inMemoryDatabase();

    final sdk = FrappeSDK.forTesting(
      'http://x',
      db,
      onResolvedExisting: (doctype, uuid, existing, payload) =>
          reported.add('$doctype/$uuid/' + (existing['name'] as String)),
      httpClient: MockClient((req) async {
        if (req.method == 'POST') {
          return http.Response(
            jsonEncode({
              'data': {'name': 'DOC-9'},
            }),
            200,
          );
        }
        if (req.url.path.contains('get_list')) {
          return http.Response(
            jsonEncode({
              'message': [
                {'name': 'DOC-9'},
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'data': {'name': 'DOC-9', 'mobile_uuid': 'u-sdk'},
          }),
          200,
        );
      }),
    );

    // Second create with the same key is the one that resolves rather than
    // inserting again.
    await sdk.api.document.createDocument('Item', {'mobile_uuid': 'u-sdk'});
    await sdk.api.document.createDocument('Item', {'mobile_uuid': 'u-sdk'});

    expect(
      reported,
      ['Item/u-sdk/DOC-9'],
      reason:
          'a listener given to FrappeSDK must reach the DocumentService that '
          'the SDK itself builds — the layer a host actually configures',
    );
  });

  test('the production constructor accepts the listener', () {
    // The production path assigns this onto AuthService BEFORE initialize()
    // reads it (_doInitialize). That assignment cannot run here without
    // FlutterSecureStorage, so this pins the half that can: the parameter
    // exists on the constructor a host calls, and survives onto the instance.
    // Without it there is no way to supply the hook at all.
    String? seen;
    final sdk = FrappeSDK(
      baseUrl: 'http://x',
      onResolvedExisting: (doctype, uuid, existing, payload) =>
          seen = '$doctype/$uuid',
    );

    expect(sdk.onResolvedExisting, isNotNull);
    sdk.onResolvedExisting!('Item', 'u-1', const {'name': 'DOC-1'}, const {});
    expect(seen, 'Item/u-1');
  });
}
