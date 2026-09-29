// Executes the SQL that FilterParser.toSql emits against a real in-memory
// SQLite table, and asserts WHICH ROWS come back.
//
// The other filter_parser tests compare SQL strings and bind params. A string
// assertion cannot tell whether the query answers the question Frappe answers,
// so these tests run the query instead. The expected row sets follow Frappe's
// own list-query semantics (frappe/model/db_query.py `prepare_filter_condition`
// and `get_between_date_filter`, v16):
//
//   * `between` on a Date field uses DATE-ONLY bounds (`format_date`), so a
//     row dated on either bound is included.
//   * `not in` coalesces the column with `ifnull(col, '')`, so a row whose
//     value is NULL is NOT excluded by `not in ('X')`.
//   * `in` coalesces when the value list contains `''`, so `in ('', 'X')`
//     matches a NULL row.
//   * `!=` and `=` coalesce text columns with `''`.
//   * `timespan` is rewritten to `between` over the resolved date range.
//
// Date values are stored locally exactly as Frappe serialises them over REST:
// `YYYY-MM-DD` text.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/filter_errors.dart';
import 'package:frappe_mobile_sdk/src/query/filter_parser.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _table = 'docs__task';

DocField _f(String n, String t) =>
    DocField(fieldname: n, fieldtype: t, label: n);

final DocTypeMeta _meta = DocTypeMeta(
  name: 'Task',
  titleField: 'subject',
  fields: [
    _f('subject', 'Data'),
    _f('status', 'Data'),
    _f('due_on', 'Date'),
    _f('closed_at', 'Datetime'),
    _f('priority', 'Int'),
    _f('seq', 'Int'),
  ],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  var uuid = 0;

  Future<void> insert(Map<String, Object?> values) async {
    uuid++;
    await db.insert(_table, {
      'mobile_uuid': 'u$uuid',
      'local_modified': uuid,
      ...values,
    });
  }

  /// Runs [filters] / [orFilters] through the parser and returns the
  /// `subject` of every matching row, sorted.
  Future<List<String>> subjects(
    List<List> filters, {
    List<List> orFilters = const [],
    String? orderBy,
    int page = 0,
    int pageSize = 500,
    bool sort = true,
  }) async {
    final pq = FilterParser.toSql(
      meta: _meta,
      tableName: _table,
      filters: filters,
      orFilters: orFilters,
      orderBy: orderBy,
      page: page,
      pageSize: pageSize,
    );
    final rows = await db.rawQuery(pq.sql, pq.params);
    final out = [for (final r in rows) r['subject'] as String];
    if (sort) out.sort();
    return out;
  }

  setUp(() async {
    uuid = 0;
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in buildParentSchemaDDL(_meta, tableName: _table)) {
      await db.execute(s);
    }
  });

  tearDown(() async {
    await db.close();
  });

  group('between on a Date column (Frappe: date-only bounds, inclusive)', () {
    setUp(() async {
      await insert({'subject': 'before', 'due_on': '2026-08-31'});
      await insert({'subject': 'first-day', 'due_on': '2026-09-01'});
      await insert({'subject': 'middle', 'due_on': '2026-09-15'});
      await insert({'subject': 'last-day', 'due_on': '2026-09-30'});
      await insert({'subject': 'after', 'due_on': '2026-10-01'});
      await insert({'subject': 'no-date'});
    });

    test(
      'keeps rows strictly inside the range and drops rows outside',
      () async {
        final got = await subjects([
          [
            'due_on',
            'between',
            ['2026-09-01', '2026-09-30'],
          ],
        ]);
        expect(got, contains('middle'));
        expect(got, isNot(contains('before')));
        expect(got, isNot(contains('after')));
        expect(got, isNot(contains('no-date')));
      },
    );

    test('includes a row dated on the END bound', () async {
      final got = await subjects([
        [
          'due_on',
          'between',
          ['2026-09-01', '2026-09-30'],
        ],
      ]);
      expect(got, contains('last-day'));
    });

    test(
      'includes a row dated on the START bound',
      () async {
        final got = await subjects([
          [
            'due_on',
            'between',
            ['2026-09-01', '2026-09-30'],
          ],
        ]);
        expect(
          got,
          ['first-day', 'last-day', 'middle'],
          reason:
              'Frappe get_between_date_filter formats both bounds with '
              'format_date for a Date field, so 2026-09-01 is inside '
              "['2026-09-01', '2026-09-30']. Offline the start bound becomes "
              "'2026-09-01 00:00:00', and '2026-09-01' sorts BEFORE it as text.",
        );
      },
      skip:
          'BUG SDK-1: Date `between` pads the start bound with 00:00:00, so '
          'offline lists drop every row dated on the first day of the range',
    );

    test(
      'a single-day range [d, d] returns that day',
      () async {
        final got = await subjects([
          [
            'due_on',
            'between',
            ['2026-09-15', '2026-09-15'],
          ],
        ]);
        expect(got, ['middle']);
      },
      skip: 'BUG SDK-1: same root cause — the only matching row is dropped',
    );
  });

  group('between on a Datetime column', () {
    setUp(() async {
      await insert({'subject': 'start', 'closed_at': '2026-09-01 00:00:00'});
      await insert({'subject': 'noon', 'closed_at': '2026-09-15 12:30:00'});
      await insert({'subject': 'end', 'closed_at': '2026-09-30 23:59:59'});
      await insert({'subject': 'late', 'closed_at': '2026-10-01 00:00:00'});
    });

    test('date-only bounds widen to the whole start/end day', () async {
      final got = await subjects([
        [
          'closed_at',
          'between',
          ['2026-09-01', '2026-09-30'],
        ],
      ]);
      expect(got, ['end', 'noon', 'start']);
    });

    test('explicit datetime bounds are used verbatim', () async {
      final got = await subjects([
        [
          'closed_at',
          'between',
          ['2026-09-15 12:00:00', '2026-09-15 13:00:00'],
        ],
      ]);
      expect(got, ['noon']);
    });
  });

  group('timespan on a Date column', () {
    String ymd(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

    test(
      '"today" matches a row dated today',
      () async {
        // FrappeTimespan resolves against the UTC calendar day, so seed the
        // row with the same day to isolate the bound-format question.
        final today = ymd(DateTime.now().toUtc());
        await insert({'subject': 'due-today', 'due_on': today});
        final got = await subjects([
          ['due_on', 'timespan', 'today'],
        ]);
        expect(got, ['due-today']);
      },
      skip:
          'BUG SDK-2: timespan bounds are "YYYY-MM-DD 00:00:00".."23:59:59", '
          'so a Date value "YYYY-MM-DD" never satisfies >= start: "today" is '
          'always empty for Date fields',
    );

    test('"this year" does not match a row from last year', () async {
      final lastYear = DateTime.now().toUtc().year - 1;
      await insert({'subject': 'old', 'due_on': '$lastYear-06-15'});
      final got = await subjects([
        ['due_on', 'timespan', 'this year'],
      ]);
      expect(got, isEmpty);
    });

    test('a null timespan value is a FilterParseError', () {
      expect(
        () => FilterParser.toSql(
          meta: _meta,
          tableName: _table,
          filters: [
            ['due_on', 'timespan', null],
          ],
        ),
        throwsA(isA<FilterParseError>()),
      );
    });
  });

  group('NULL handling (Frappe coalesces with ifnull)', () {
    setUp(() async {
      await insert({'subject': 'open', 'status': 'Open'});
      await insert({'subject': 'closed', 'status': 'Closed'});
      await insert({'subject': 'blank', 'status': ''});
      await insert({'subject': 'null'});
    });

    test('!= keeps rows whose value is NULL or empty', () async {
      final got = await subjects([
        ['status', '!=', 'Closed'],
      ]);
      expect(got, ['blank', 'null', 'open']);
    });

    test('= "" matches NULL as well as the empty string', () async {
      final got = await subjects([
        ['status', '=', ''],
      ]);
      expect(got, ['blank', 'null']);
    });

    test('in ["Open"] does not match NULL', () async {
      final got = await subjects([
        [
          'status',
          'in',
          ['Open'],
        ],
      ]);
      expect(got, ['open']);
    });

    test(
      'not in ["Closed"] keeps the NULL row',
      () async {
        final got = await subjects([
          [
            'status',
            'not in',
            ['Closed'],
          ],
        ]);
        expect(
          got,
          ['blank', 'null', 'open'],
          reason:
              'db_query.py coalesces the column for `not in` ("column values '
              'might contain null"), so Frappe returns the NULL row.',
        );
      },
      skip:
          'BUG SDK-3: `not in` emits a bare `col NOT IN (...)`; SQL NULL NOT IN '
          '(...) is NULL, so offline lists drop rows whose field is unset',
    );

    test(
      'in ["", "Open"] matches the NULL row (list contains "")',
      () async {
        final got = await subjects([
          [
            'status',
            'in',
            ['', 'Open'],
          ],
        ]);
        expect(got, ['blank', 'null', 'open']);
      },
      skip:
          'BUG SDK-4: `in` with an empty-string member is not coalesced, so '
          'NULL rows are dropped where Frappe keeps them',
    );

    test('is set / is not set treat NULL and "" alike', () async {
      expect(
        await subjects([
          ['status', 'is', 'set'],
        ]),
        ['closed', 'open'],
      );
      expect(
        await subjects([
          ['status', 'is', 'not set'],
        ]),
        ['blank', 'null'],
      );
    });

    test(
      'empty in-list matches nothing, empty not-in matches everything',
      () async {
        expect(
          await subjects([
            ['status', 'in', const []],
          ]),
          isEmpty,
        );
        expect(
          await subjects([
            ['status', 'not in', const []],
          ]),
          ['blank', 'closed', 'null', 'open'],
        );
      },
    );
  });

  group('AND + OR composition', () {
    setUp(() async {
      await insert({'subject': 'a1', 'status': 'Open', 'priority': 1});
      await insert({'subject': 'a2', 'status': 'Open', 'priority': 2});
      await insert({'subject': 'a3', 'status': 'Open', 'priority': 3});
      await insert({'subject': 'b1', 'status': 'Closed', 'priority': 1});
    });

    test('filters AND (or_filters OR-ed together)', () async {
      final got = await subjects(
        [
          ['status', '=', 'Open'],
        ],
        orFilters: [
          ['priority', '=', 1],
          ['priority', '=', 3],
        ],
      );
      expect(got, [
        'a1',
        'a3',
      ], reason: 'b1 matches an or_filter but fails the AND-ed status filter');
    });

    test('numeric comparisons compare as numbers', () async {
      expect(
        await subjects([
          ['priority', '>=', 2],
        ]),
        ['a2', 'a3'],
      );
      expect(
        await subjects([
          ['priority', '<', 2],
        ]),
        ['a1', 'b1'],
      );
    });
  });

  group('paging never drops or duplicates rows at page edges', () {
    setUp(() async {
      for (var i = 1; i <= 45; i++) {
        await insert({
          'subject': 'task-${i.toString().padLeft(3, '0')}',
          'seq': i,
        });
      }
    });

    test(
      'three pages of 20 over 45 rows cover each row exactly once',
      () async {
        final seen = <String>[];
        for (var p = 0; p < 3; p++) {
          seen.addAll(
            await subjects(
              const [],
              orderBy: 'seq asc',
              page: p,
              pageSize: 20,
              sort: false,
            ),
          );
        }
        expect(seen.length, 45);
        expect(seen.toSet().length, 45);
        expect(seen.first, 'task-001');
        expect(seen[19], 'task-020');
        expect(seen[20], 'task-021');
        expect(seen.last, 'task-045');
      },
    );

    test('a page past the end is empty', () async {
      expect(
        await subjects(
          const [],
          orderBy: 'seq asc',
          page: 3,
          pageSize: 20,
          sort: false,
        ),
        isEmpty,
      );
    });

    test('descending order reverses the page contents', () async {
      final first = await subjects(
        const [],
        orderBy: 'seq desc',
        page: 0,
        pageSize: 5,
        sort: false,
      );
      expect(first, [
        'task-045',
        'task-044',
        'task-043',
        'task-042',
        'task-041',
      ]);
    });
  });
}
