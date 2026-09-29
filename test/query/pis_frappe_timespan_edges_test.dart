// Calendar-edge cases for FrappeTimespan, checked against Frappe v16
// `frappe/utils/data.py:get_timespan_date_range`.
//
// Frappe moves "today" with `add_to_date(today, months=±N)`, which uses
// dateutil `relativedelta`: the day is CLAMPED to the last day of the target
// month (Dec 31 - 3 months = Sep 30). It then takes the quarter/month that
// date falls in. Dart's `DateTime.utc(y, m - 3, d)` instead ROLLS an
// out-of-range day into the next month (Sep 31 -> Oct 1), which can land in
// the wrong quarter.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/filter_errors.dart';
import 'package:frappe_mobile_sdk/src/query/filter_parser.dart';
import 'package:frappe_mobile_sdk/src/query/frappe_timespan.dart';

TimespanRange _at(String keyword, int y, int m, int d, [int h = 10]) =>
    FrappeTimespan.resolve(keyword, now: () => DateTime.utc(y, m, d, h));

void main() {
  group('quarter keywords at month-end (relativedelta clamps the day)', () {
    test(
      'last quarter on Dec 31 is Q3 (Jul 1 - Sep 30)',
      () {
        final r = _at('last quarter', 2026, 12, 31);
        expect(r.start, '2026-07-01 00:00:00');
        expect(r.end, '2026-09-30 23:59:59');
      },
      skip: 'BUG SDK-5: Dec 31 minus 3 months rolls to Oct 1 -> returns Q4',
    );

    test(
      'next quarter on Mar 31 is Q2 (Apr 1 - Jun 30)',
      () {
        final r = _at('next quarter', 2026, 3, 31);
        expect(r.start, '2026-04-01 00:00:00');
        expect(r.end, '2026-06-30 23:59:59');
      },
      skip: 'BUG SDK-5: Mar 31 plus 3 months rolls to Jul 1 -> returns Q3',
    );

    test('last quarter on May 31 is Q1 of the same year', () {
      final r = _at('last quarter', 2026, 5, 31);
      expect(r.start, '2026-01-01 00:00:00');
      expect(r.end, '2026-03-31 23:59:59');
    });

    test('last quarter in January is Q4 of the previous year', () {
      final r = _at('last quarter', 2026, 1, 15);
      expect(r.start, '2025-10-01 00:00:00');
      expect(r.end, '2025-12-31 23:59:59');
    });

    test('next quarter on Aug 31 is Q4', () {
      final r = _at('next quarter', 2026, 8, 31);
      expect(r.start, '2026-10-01 00:00:00');
      expect(r.end, '2026-12-31 23:59:59');
    });

    test('next quarter in November is Q1 of the next year', () {
      final r = _at('next quarter', 2026, 11, 30);
      expect(r.start, '2027-01-01 00:00:00');
      expect(r.end, '2027-03-31 23:59:59');
    });

    test('this quarter on the last day of a quarter stays in it', () {
      final r = _at('this quarter', 2026, 9, 30, 23);
      expect(r.start, '2026-07-01 00:00:00');
      expect(r.end, '2026-09-30 23:59:59');
    });
  });

  group('month keywords at month-end', () {
    test('last month on Mar 31 is February (non-leap: 28 days)', () {
      final r = _at('last month', 2026, 3, 31);
      expect(r.start, '2026-02-01 00:00:00');
      expect(r.end, '2026-02-28 23:59:59');
    });

    test('next month on Jan 31 is February (leap year: 29 days)', () {
      final r = _at('next month', 2028, 1, 31);
      expect(r.start, '2028-02-01 00:00:00');
      expect(r.end, '2028-02-29 23:59:59');
    });

    test('last month in January is December of the previous year', () {
      final r = _at('last month', 2026, 1, 1);
      expect(r.start, '2025-12-01 00:00:00');
      expect(r.end, '2025-12-31 23:59:59');
    });

    test('next month in December is January of the next year', () {
      final r = _at('next month', 2026, 12, 31);
      expect(r.start, '2027-01-01 00:00:00');
      expect(r.end, '2027-01-31 23:59:59');
    });
  });

  group('day keywords', () {
    test('yesterday on Mar 1 of a leap year is Feb 29', () {
      final r = _at('yesterday', 2028, 3, 1);
      expect(r.start, '2028-02-29 00:00:00');
      expect(r.end, '2028-02-29 23:59:59');
    });

    test('tomorrow on Dec 31 is Jan 1 of the next year', () {
      final r = _at('tomorrow', 2026, 12, 31);
      expect(r.start, '2027-01-01 00:00:00');
      expect(r.end, '2027-01-01 23:59:59');
    });

    test(
      'last 7 days spans today-7 .. today (Frappe add_to_date(days=-7))',
      () {
        final r = _at('last 7 days', 2026, 3, 3);
        expect(r.start, '2026-02-24 00:00:00');
        expect(r.end, '2026-03-03 23:59:59');
      },
    );

    test('keyword matching ignores case and surrounding whitespace', () {
      final r = _at('  This Year ', 2026, 6, 1);
      expect(r.start, '2026-01-01 00:00:00');
      expect(r.end, '2026-12-31 23:59:59');
    });

    test('last year / next year cover whole calendar years', () {
      expect(_at('last year', 2026, 1, 1).start, '2025-01-01 00:00:00');
      expect(_at('last year', 2026, 1, 1).end, '2025-12-31 23:59:59');
      expect(_at('next year', 2026, 12, 31).start, '2027-01-01 00:00:00');
      expect(_at('next year', 2026, 12, 31).end, '2027-12-31 23:59:59');
    });
  });

  group('keywords Frappe v16 supports', () {
    test(
      'next 7 days spans today .. today+7',
      () {
        final r = _at('next 7 days', 2026, 9, 28);
        expect(r.start, '2026-09-28 00:00:00');
        expect(r.end, '2026-10-05 23:59:59');
      },
      skip: 'BUG SDK-6: "next N days" throws ArgumentError (unsupported)',
    );

    test(
      'next 30 days spans today .. today+30',
      () {
        final r = _at('next 30 days', 2026, 9, 28);
        expect(r.start, '2026-09-28 00:00:00');
        expect(r.end, '2026-10-28 23:59:59');
      },
      skip: 'BUG SDK-6: "next N days" throws ArgumentError (unsupported)',
    );

    test(
      'last 6 months = start of quarter(today-6m) .. end of quarter(today-3m)',
      () {
        // today 2026-09-28: today-6m = 2026-03-28 (Q1), today-3m = 2026-06-28 (Q2)
        final r = _at('last 6 months', 2026, 9, 28);
        expect(r.start, '2026-01-01 00:00:00');
        expect(r.end, '2026-06-30 23:59:59');
      },
      skip: 'BUG SDK-6: "last 6 months" throws ArgumentError (unsupported)',
    );

    test(
      'next 6 months = start of quarter(today+3m) .. end of quarter(today+6m)',
      () {
        // today 2026-09-28: +3m = 2026-12-28 (Q4), +6m = 2027-03-28 (Q1 2027)
        final r = _at('next 6 months', 2026, 9, 28);
        expect(r.start, '2026-10-01 00:00:00');
        expect(r.end, '2027-03-31 23:59:59');
      },
      skip: 'BUG SDK-6: "next 6 months" throws ArgumentError (unsupported)',
    );

    test('an unknown keyword from FrappeTimespan is an ArgumentError', () {
      expect(
        () => FrappeTimespan.resolve('fortnight'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'FilterParser reports an unknown timespan keyword as a FilterException',
      () {
        final meta = DocTypeMeta(
          name: 'Task',
          fields: [DocField(fieldname: 'due_on', fieldtype: 'Date')],
        );
        expect(
          () => FilterParser.toSql(
            meta: meta,
            tableName: 'docs__task',
            filters: [
              ['due_on', 'timespan', 'fortnight'],
            ],
          ),
          throwsA(isA<FilterException>()),
          reason:
              'Every other malformed/unsupported filter surfaces as a '
              'FilterParseError / UnsupportedFilterError (the two exported '
              'types); a raw ArgumentError escapes callers that catch those.',
        );
      },
      skip: 'BUG SDK-7: unknown timespan keyword escapes as ArgumentError',
    );
  });
}
