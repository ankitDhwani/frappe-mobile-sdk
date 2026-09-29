// Widget tests for DocumentListScreen: empty state, row rendering, search,
// paging boundaries, sorting and permission gating.
//
// The fake resolver honours page/pageSize exactly like the real one, so a
// test that seeds N rows can tell whether the screen can reach all N.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/query_result.dart';
import 'package:frappe_mobile_sdk/src/query/unified_resolver.dart';
import 'package:frappe_mobile_sdk/src/services/meta_service.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/sync_service.dart';
import 'package:frappe_mobile_sdk/src/ui/document_list_screen.dart';

class _FakeResolver extends Fake implements UnifiedResolver {
  _FakeResolver(this.rows);

  final List<Map<String, Object?>> rows;
  final List<({int page, int pageSize, String? orderBy})> calls = [];

  @override
  Future<QueryResult<Map<String, Object?>>> resolve({
    required String doctype,
    List<List> filters = const [],
    List<List> orFilters = const [],
    String? orderBy,
    int page = 0,
    int pageSize = 50,
    bool includeFailed = false,
  }) async {
    calls.add((page: page, pageSize: pageSize, orderBy: orderBy));
    final start = page * pageSize;
    final slice = start >= rows.length
        ? <Map<String, Object?>>[]
        : rows.sublist(start, (start + pageSize).clamp(0, rows.length));
    return QueryResult.ofRows(slice, pageSize, const {});
  }
}

class _OfflineSync extends Fake implements SyncService {
  @override
  Future<bool> isOnline() async => false;
}

class _FakeRepo extends Fake implements OfflineRepository {}

class _FakeMetaService extends Fake implements MetaService {}

String _pad(int i) => i.toString().padLeft(3, '0');

/// `task-001` .. `task-<n>`, each with a server name and increasing
/// creation/modified timestamps.
List<Map<String, Object?>> _rows(int n) => [
  for (var i = 1; i <= n; i++)
    {
      'name': 'TASK-${_pad(i)}',
      'subject': 'task-${_pad(i)}',
      'seq': i,
      'creation': '2026-01-01 00:00:${_pad(i).substring(1)}',
      'modified': '2026-02-01 00:00:${_pad(i).substring(1)}',
    },
];

DocTypeMeta _meta({
  String? sortField = 'seq',
  String? sortOrder = 'asc',
  Map<String, dynamic>? metaData,
  List<DocField>? extraFields,
}) => DocTypeMeta(
  name: 'Task',
  label: 'Task',
  titleField: 'subject',
  sortField: sortField,
  sortOrder: sortOrder,
  metaData: metaData,
  fields: [
    DocField(fieldname: 'subject', fieldtype: 'Data', label: 'Subject'),
    DocField(
      fieldname: 'seq',
      fieldtype: 'Int',
      label: 'Seq',
      inListView: true,
      idx: 2,
    ),
    ...?extraFields,
  ],
);

Future<_FakeResolver> _pump(
  WidgetTester tester, {
  required List<Map<String, Object?>> rows,
  DocTypeMeta? meta,
  List<String>? userRoles,
}) async {
  final resolver = _FakeResolver(rows);
  await tester.pumpWidget(
    MaterialApp(
      home: DocumentListScreen(
        doctype: 'Task',
        meta: meta ?? _meta(),
        repository: _FakeRepo(),
        resolver: resolver,
        syncService: _OfflineSync(),
        metaService: _FakeMetaService(),
        userRoles: userRoles,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump();
  return resolver;
}

/// A tall surface so a whole 20-row page is built at once.
void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

List<String> _visibleTitles(WidgetTester tester) => [
  for (final t in tester.widgetList<ListTile>(find.byType(ListTile)))
    (t.title as Text).data!,
];

void main() {
  testWidgets('no rows: empty state with refresh and create actions', (
    tester,
  ) async {
    final resolver = await _pump(tester, rows: const []);
    expect(find.text('No documents found'), findsOneWidget);
    expect(find.text('Refresh from Server'), findsOneWidget);
    expect(find.text('Create New'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);

    final before = resolver.calls.length;
    await tester.tap(find.text('Refresh from Server'));
    await tester.pump();
    await tester.pump();
    expect(resolver.calls.length, before + 1);
  });

  testWidgets('rows show title, server id, and a local marker', (tester) async {
    await _pump(
      tester,
      rows: [
        {'name': 'TASK-001', 'subject': 'Write report', 'seq': 1},
        {'mobile_uuid': 'local-1', 'subject': 'Draft only', 'seq': 2},
      ],
    );
    expect(find.text('Write report'), findsOneWidget);
    expect(find.text('ID: TASK-001'), findsOneWidget);
    expect(find.text('Draft only'), findsOneWidget);
    expect(find.text('Local (not synced)'), findsOneWidget);
  });

  testWidgets('a Link title field shows its resolved __display title', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'Task',
      titleField: 'customer',
      sortField: 'seq',
      sortOrder: 'asc',
      fields: [
        DocField(
          fieldname: 'customer',
          fieldtype: 'Link',
          options: 'Customer',
          label: 'Customer',
        ),
        DocField(fieldname: 'seq', fieldtype: 'Int'),
      ],
    );
    await _pump(
      tester,
      meta: meta,
      rows: [
        {
          'name': 'TASK-1',
          'customer': 'CUST-0001',
          'customer__display': 'Acme Traders',
          'seq': 1,
        },
      ],
    );
    expect(find.text('Acme Traders'), findsOneWidget);
    expect(find.text('CUST-0001'), findsNothing);
  });

  testWidgets('status chip appears only when the doctype has a status field', (
    tester,
  ) async {
    await _pump(
      tester,
      meta: _meta(
        extraFields: [
          DocField(fieldname: 'status', fieldtype: 'Select', label: 'Status'),
        ],
      ),
      rows: [
        {'name': 'T-1', 'subject': 'one', 'seq': 1, 'status': 'Open'},
        {'name': 'T-2', 'subject': 'two', 'seq': 2, 'status': 'null'},
      ],
    );
    expect(find.widgetWithText(Chip, 'Open'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'null'), findsNothing);
  });

  group('paging', () {
    testWidgets('45 rows: 3 pages, edges neither dropped nor duplicated', (
      tester,
    ) async {
      _tallView(tester);
      await _pump(tester, rows: _rows(45));
      expect(find.text('Page 1 of 3'), findsOneWidget);

      final page1 = _visibleTitles(tester);
      expect(page1.length, 20);
      expect(page1.first, 'task-001');
      expect(page1.last, 'task-020');

      await tester.tap(find.byIcon(Icons.chevron_left).first);
      await tester.pump();
      expect(find.text('Page 1 of 3'), findsOneWidget, reason: 'no page 0');

      await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
      await tester.pump();
      expect(find.text('Page 2 of 3'), findsOneWidget);
      final page2 = _visibleTitles(tester);
      expect(page2.first, 'task-021');
      expect(page2.last, 'task-040');

      await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
      await tester.pump();
      expect(find.text('Page 3 of 3'), findsOneWidget);
      final page3 = _visibleTitles(tester);
      expect(page3, [for (var i = 41; i <= 45; i++) 'task-${_pad(i)}']);

      final all = [...page1, ...page2, ...page3];
      expect(all.toSet().length, 45);
    });

    testWidgets('exactly one page of rows shows no pager', (tester) async {
      await _pump(tester, rows: _rows(20));
      expect(find.textContaining('Page '), findsNothing);
    });

    testWidgets(
      'every row is reachable when the doctype has more than 100 rows',
      (tester) async {
        final resolver = await _pump(tester, rows: _rows(130));
        expect(
          find.text('Page 1 of 7'),
          findsOneWidget,
          reason: '130 rows / 20 per page = 7 pages',
        );
        await tester.enterText(find.byType(TextField), 'task-130');
        await tester.pump();
        expect(find.text('task-130'), findsOneWidget);
        expect(resolver.calls, isNotEmpty);
      },
      skip: true, // BUG SDK-10
      // _fetchViaResolver loads only page 0 with pageSize 100 and
      // never pages further; rows 101+ are unreachable by paging or search
    );
  });

  group('search', () {
    testWidgets('filters by title and by server id, case-insensitively', (
      tester,
    ) async {
      await _pump(tester, rows: _rows(30));
      await tester.enterText(find.byType(TextField), 'TASK-007');
      await tester.pump();
      expect(find.text('task-007'), findsOneWidget);
      expect(find.text('task-008'), findsNothing);
    });

    testWidgets('a server id that does not appear in the title still matches', (
      tester,
    ) async {
      final rows = <Map<String, Object?>>[
        {
          'name': 'TASK-900',
          'subject': 'Alpha',
          'seq': 1,
          'modified': '2026-02-01 00:00:01',
        },
        {
          'name': 'TASK-901',
          'subject': 'Beta',
          'seq': 2,
          'modified': '2026-02-01 00:00:02',
        },
      ];
      await _pump(tester, rows: rows);
      await tester.enterText(find.byType(TextField), 'task-901');
      await tester.pump();
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets('a new query returns to page 1', (tester) async {
      await _pump(tester, rows: _rows(45));
      await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
      await tester.pump();
      expect(find.text('Page 2 of 3'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'task-0');
      await tester.pump();
      // 45 rows all contain "task-0" -> still 3 pages, but back on page 1.
      expect(find.text('Page 1 of 3'), findsOneWidget);
      expect(find.text('task-001'), findsOneWidget);
    });

    testWidgets('no match leaves an empty list, not the empty state', (
      tester,
    ) async {
      await _pump(tester, rows: _rows(5));
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump();
      expect(find.byType(ListTile), findsNothing);
      expect(find.byType(TextField), findsOneWidget, reason: 'search stays');
    });
  });

  group('sorting', () {
    testWidgets('meta sort_order desc puts the highest sort value first', (
      tester,
    ) async {
      await _pump(
        tester,
        rows: _rows(5),
        meta: _meta(sortOrder: 'desc'),
      );
      final titles = _visibleTitles(tester);
      expect(titles.first, 'task-005');
      expect(titles.last, 'task-001');
    });

    testWidgets('choosing the active sort field again reverses the order', (
      tester,
    ) async {
      await _pump(tester, rows: _rows(5));
      expect(_visibleTitles(tester).first, 'task-001');

      await tester.tap(find.byIcon(Icons.sort));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Seq').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_visibleTitles(tester).first, 'task-005');
    });

    testWidgets('numeric sort values compare as numbers, not text', (
      tester,
    ) async {
      await _pump(
        tester,
        rows: [
          {'name': 'A', 'subject': 'nine', 'seq': 9},
          {'name': 'B', 'subject': 'ten', 'seq': 10},
          {'name': 'C', 'subject': 'two', 'seq': 2},
        ],
      );
      expect(_visibleTitles(tester), ['two', 'nine', 'ten']);
    });

    testWidgets(
      'with no sort configured the newest document comes first',
      (tester) async {
        await _pump(
          tester,
          rows: _rows(5),
          meta: _meta(sortField: null, sortOrder: null),
        );
        expect(
          _visibleTitles(tester).first,
          'task-005',
          reason: 'Frappe base_list.js: sort_order = meta.sort_order || "desc"',
        );
      },
      skip: true, // BUG SDK-11
      // a null sort_order defaults to ascending (oldest first);
      // Frappe desk defaults to "desc"
    );
  });

  group('permissions', () {
    final readOnlyPerms = <String, dynamic>{
      'permissions': [
        {'role': 'Viewer', 'permlevel': 0, 'read': 1, 'write': 0, 'create': 0},
      ],
    };

    testWidgets('no create permission hides the FAB and Create New', (
      tester,
    ) async {
      await _pump(
        tester,
        rows: const [],
        meta: _meta(metaData: readOnlyPerms),
        userRoles: const ['Viewer'],
      );
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text('Create New'), findsNothing);
      expect(find.text('Refresh from Server'), findsOneWidget);
    });

    testWidgets('no write permission: tapping a row opens nothing', (
      tester,
    ) async {
      await _pump(
        tester,
        rows: _rows(2),
        meta: _meta(metaData: readOnlyPerms),
        userRoles: const ['Viewer'],
      );
      await tester.tap(find.text('task-001'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(DocumentListScreen), findsOneWidget);
      expect(find.text('task-001'), findsOneWidget);
    });
  });
}
