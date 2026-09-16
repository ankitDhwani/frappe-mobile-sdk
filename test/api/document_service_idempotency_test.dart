import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/document_service.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';

/// M8 — the guard's WIRING into [DocumentService], at the HTTP boundary.
///
/// `create_idempotency_test.dart` covers the guard in isolation with a fake
/// create function. That says nothing about whether `createDocument` routes
/// through it at all, nor about the two-call lookup shape — which is the part
/// that talks to a real server and so the part most likely to drift. These
/// drive the real `RestHelper` against a mock transport and assert on the
/// actual requests.
http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

void main() {
  /// Every request the service issued, in order.
  late List<http.BaseRequest> seen;

  setUp(() => seen = []);

  DocumentService svc(
    Future<http.Response> Function(http.Request req) handler,
  ) => DocumentService(
    RestHelper(
      'http://x',
      client: MockClient((req) async {
        seen.add(req);
        return handler(req);
      }),
    ),
  );

  List<http.BaseRequest> posts() =>
      seen.where((r) => r.method == 'POST').toList();
  List<http.BaseRequest> gets() =>
      seen.where((r) => r.method == 'GET').toList();

  test(
    'a payload with no mobile_uuid issues exactly one POST, no lookup',
    () async {
      final s = svc(
        (_) async => _json({
          'data': {'name': 'DOC-1'},
        }),
      );
      await s.createDocument('Item', {'item_code': 'X'});

      expect(posts(), hasLength(1));
      expect(
        gets(),
        isEmpty,
        reason: 'nothing to key on, so nothing to look up',
      );
    },
  );

  test('a blank mobile_uuid is stripped from the wire body', () async {
    // Empty is worse than absent: a unique index permits many NULLs but only
    // one empty string.
    final s = svc(
      (_) async => _json({
        'data': {'name': 'DOC-1'},
      }),
    );
    await s.createDocument('Item', {'item_code': 'X', 'mobile_uuid': '  '});

    final body = jsonDecode((posts().single as http.Request).body) as Map;
    expect(body.containsKey('mobile_uuid'), isFalse);
  });

  test(
    'a retry of the same uuid issues ONE POST and resolves via lookup',
    () async {
      final s = svc((req) async {
        if (req.method == 'POST')
          return _json({
            'data': {'name': 'DOC-1'},
          });
        if (req.url.path.contains('get_list')) {
          return _json({
            'message': [
              {'name': 'DOC-1'},
            ],
          });
        }
        return _json({
          'data': {'name': 'DOC-1', 'mobile_uuid': 'u-1'},
        });
      });

      await s.createDocument('Item', {'item_code': 'X', 'mobile_uuid': 'u-1'});
      final second = await s.createDocument('Item', {
        'item_code': 'X',
        'mobile_uuid': 'u-1',
      });

      expect(posts(), hasLength(1), reason: 'the retry must not write again');
      expect(second['name'], 'DOC-1');
    },
  );

  test('the lookup is two calls, in the documented shape', () async {
    // Pinned because this is the part that talks to a real server: a projection
    // list query to answer identity, then a full fetch so the returned document
    // is the same shape a real create returns.
    final s = svc((req) async {
      if (req.method == 'POST')
        return _json({
          'data': {'name': 'DOC-7'},
        });
      if (req.url.path.contains('get_list')) {
        return _json({
          'message': [
            {'name': 'DOC-7'},
          ],
        });
      }
      return _json({
        'data': {'name': 'DOC-7', 'qty': 3},
      });
    });

    await s.createDocument('Item', {'mobile_uuid': 'u-2'});
    await s.createDocument('Item', {'mobile_uuid': 'u-2'});

    final lookups = gets();
    expect(lookups, hasLength(2));

    final list = lookups.first.url;
    expect(list.path, contains('frappe.client.get_list'));
    expect(list.queryParameters['doctype'], 'Item');
    expect(list.queryParameters['filters'], contains('mobile_uuid'));
    expect(list.queryParameters['fields'], '["name"]');
    expect(list.queryParameters['limit_page_length'], '1');
    // Oldest first: where the unique index is absent two rows CAN share a uuid,
    // and a retry means the one an earlier attempt created.
    expect(list.queryParameters['order_by'], 'creation asc');

    expect(lookups.last.url.path, contains('/api/resource/Item/DOC-7'));
  });

  test('a lookup that finds nothing lets the create proceed', () async {
    final s = svc((req) async {
      if (req.method == 'POST')
        return _json({
          'data': {'name': 'DOC-2'},
        });
      return _json({'message': <dynamic>[]});
    });

    await s.createDocument('Item', {'mobile_uuid': 'u-3'});
    final second = await s.createDocument('Item', {'mobile_uuid': 'u-3'});

    expect(posts(), hasLength(2), reason: 'no existing doc, so write it');
    expect(second['name'], 'DOC-2');
  });

  test('resetCreateIdempotency clears the remembered history', () async {
    final s = svc((req) async {
      if (req.method == 'POST')
        return _json({
          'data': {'name': 'DOC-3'},
        });
      return _json({'message': <dynamic>[]});
    });

    await s.createDocument('Item', {'mobile_uuid': 'u-4'});
    s.resetCreateIdempotency();
    await s.createDocument('Item', {'mobile_uuid': 'u-4'});

    // With the key forgotten the second save is not treated as a retry, so it
    // does not pay for a lookup.
    expect(gets(), isEmpty);
    expect(posts(), hasLength(2));
  });
}
