// The value a Date field hands to the form when the user PICKS a date.
//
// Frappe stores and serialises a Date as `YYYY-MM-DD` (frappe.utils
// `DATE_FORMAT = "%Y-%m-%d"`; Desk's date control `parse` returns
// `frappe.datetime.user_to_str(value)` in that shape). Everything else in the
// SDK treats a Date as that text too: rows pulled from the server hold
// `YYYY-MM-DD`, FilterParser compares it as text, `eval:` expressions compare
// `doc.a == doc.b` as strings. A picked value must therefore be the same
// shape, or a locally created record stops matching server-pulled ones.
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/date_field.dart';

void main() {
  Future<List<dynamic>> pickDay15(WidgetTester tester, dynamic value) async {
    final emitted = <dynamic>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormBuilder(
            child: DateField(
              field: DocField(
                fieldname: 'due_on',
                fieldtype: 'Date',
                label: 'Due On',
              ),
              value: value,
              onChanged: emitted.add,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('date_due_on')));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('15'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    return emitted;
  }

  testWidgets('picking a day emits a value for that day', (tester) async {
    final emitted = await pickDay15(tester, '2026-03-02');
    expect(emitted, isNotEmpty);
    final picked = DateTime.parse(emitted.last as String);
    expect([picked.year, picked.month, picked.day], [2026, 3, 15]);
    expect(find.text('2026-03-15'), findsOneWidget, reason: 'display format');
  });

  testWidgets(
    'picking a day emits the Frappe Date format YYYY-MM-DD',
    (tester) async {
      final emitted = await pickDay15(tester, '2026-03-02');
      expect(
        emitted.last,
        '2026-03-15',
        reason: 'not an ISO datetime such as 2026-03-15T00:00:00.000',
      );
    },
    skip: true, // BUG SDK-24
    // DateField emits DateTime.toIso8601String() ("...T00:00:00.000")
    // for a Date field, so device-picked dates never equal server dates
  );
}
