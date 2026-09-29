// QueryBuilder.where — the operator form must survive a null value.
//
// `where(field, value)` is the documented equality shorthand, and
// `where(field, op, value)` the explicit form. The implementation tells them
// apart with `value == null`, so an explicit operator paired with a null
// value (a nullable variable, an "is not set" check) is silently re-read as
// the shorthand: `where('status', '!=', null)` becomes `status = '!='`, a
// filter that matches nothing and raises no error.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/doctype_service.dart';
import 'package:frappe_mobile_sdk/src/api/query_builder.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const bool _runBugs = bool.fromEnvironment('RUN_BUGS');

void main() {
  late List<Map<String, String>> sent;
  late QueryBuilder q;

  setUp(() {
    sent = [];
    final rest = RestHelper(
      'https://frappe.test',
      client: MockClient((req) async {
        sent.add(req.url.queryParameters);
        return http.Response(
          jsonEncode({
            'message': [
              {'name': 'T-1'},
            ],
          }),
          200,
        );
      }),
    );
    q = QueryBuilder(DoctypeService(rest), 'Task');
  });

  List<dynamic> filtersSent() => jsonDecode(sent.single['filters']!) as List;

  test('two-argument form is equality', () async {
    await q.where('status', 'Open').get();
    expect(filtersSent(), [
      ['Task', 'status', '=', 'Open'],
    ]);
  });

  test('three-argument form keeps the operator', () async {
    await q.where('qty', '>=', 5).get();
    expect(filtersSent(), [
      ['Task', 'qty', '>=', 5],
    ]);
  });

  test(
    'three-argument form with a null value keeps the operator',
    () async {
      await q.where('status', '!=', null).get();
      expect(filtersSent(), [
        ['Task', 'status', '!=', null],
      ]);
    },
    skip: _runBugs
        ? null
        : "BUG N-17: where(field, op, null) is rewritten to field = 'op'",
  );

  test(
    'orderBy / limit / select reach the wire; first() takes one row',
    () async {
      final row = await q
          .select(['name', 'status'])
          .orderBy('modified', descending: true)
          .limit(10, start: 30)
          .first();

      expect(row, {'name': 'T-1'});
      final p = sent.single;
      expect(jsonDecode(p['fields']!), ['name', 'status']);
      expect(p['order_by'], 'modified desc');
      expect(p['limit_page_length'], '1', reason: 'first() overrides limit');
      expect(p['limit_start'], '0');
    },
  );

  test('filters() appends pre-built clauses verbatim', () async {
    await q
        .filters([
          [
            'status',
            'in',
            ['A', 'B'],
          ],
        ])
        .where('owner', 'x')
        .get();
    expect(filtersSent(), [
      [
        'status',
        'in',
        ['A', 'B'],
      ],
      ['Task', 'owner', '=', 'x'],
    ]);
  });
}
