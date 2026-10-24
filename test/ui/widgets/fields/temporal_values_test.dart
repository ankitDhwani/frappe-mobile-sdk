import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/datetime_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/time_field.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Date, Datetime and Time values the way Frappe stores them: `YYYY-MM-DD`,
/// `YYYY-MM-DD HH:mm:ss` and `HH:mm:ss`, and an empty one as null
/// (`frappe.datetime` / `ControlDate.parse`). An empty value saved as `''`
/// crashed the field when the document was opened again.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  DocTypeMeta meta() => DocTypeMeta(
    name: 'Visit',
    fields: <DocField>[
      DocField(fieldname: 'title', fieldtype: 'Data', label: 'Title'),
      DocField(fieldname: 'd', fieldtype: 'Date', label: 'Visit Date'),
      DocField(fieldname: 'dt', fieldtype: 'Datetime', label: 'Logged At'),
      DocField(fieldname: 't', fieldtype: 'Time', label: 'Start Time'),
    ],
  );

  Future<({Map<String, dynamic>? Function() submitted, void Function() submit})>
  pump(
    WidgetTester tester, {
    FormBuilderMode mode = FormBuilderMode.legacy,
    Map<String, dynamic>? initialData,
  }) async {
    Map<String, dynamic>? out;
    void Function()? submitFn;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta(),
            mode: mode,
            initialData: initialData,
            onSubmit: (data) => out = data,
            registerSubmit: (fn) => submitFn = fn,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (submitted: () => out, submit: () => submitFn!());
  }

  for (final mode in FormBuilderMode.values) {
    group('$mode', () {
      testWidgets('an empty date, datetime or time is saved as null', (
        tester,
      ) async {
        final h = await pump(tester, mode: mode);
        h.submit();
        await tester.pumpAndSettle();
        final p = h.submitted()!;
        expect(p['d'], isNull);
        expect(p['dt'], isNull);
        expect(p['t'], isNull);
      });

      testWidgets('a document saved with empty-string dates opens', (
        tester,
      ) async {
        // What earlier SDK versions stored for an empty optional date.
        await pump(
          tester,
          mode: mode,
          initialData: {'name': 'DOC-1', 'd': '', 'dt': '', 't': ''},
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Visit Date'), findsWidgets);
      });

      testWidgets('a value stored in ISO form still shows its date', (
        tester,
      ) async {
        await pump(
          tester,
          mode: mode,
          initialData: {'name': 'DOC-1', 'd': '2026-10-13T00:00:00.000'},
        );
        expect(tester.takeException(), isNull);
        expect(find.text('2026-10-13'), findsOneWidget);
      });
    });
  }

  group('picked values use the Frappe format', () {
    Future<Object?> pick(
      WidgetTester tester,
      String fieldtype,
      DateTime? value,
    ) async {
      Object? emitted = 'not called';
      final field = DocField(fieldname: 'x', fieldtype: fieldtype, label: 'X');
      Widget child;
      switch (fieldtype) {
        case 'Date':
          child = DateField(field: field, onChanged: (v) => emitted = v);
        case 'Datetime':
          child = DatetimeField(field: field, onChanged: (v) => emitted = v);
        default:
          child = TimeField(
            field: field,
            value: '09:15:00',
            onChanged: (v) => emitted = v,
          );
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FormBuilder(child: child)),
        ),
      );
      final state = tester.state<FormBuilderFieldState>(
        find.byType(FormBuilderDateTimePicker),
      );
      state.didChange(value);
      await tester.pump();
      return emitted;
    }

    testWidgets('Date', (tester) async {
      expect(await pick(tester, 'Date', DateTime(2026, 10, 13)), '2026-10-13');
    });

    testWidgets('Datetime', (tester) async {
      expect(
        await pick(tester, 'Datetime', DateTime(2026, 10, 13, 14, 30, 5)),
        '2026-10-13 14:30:05',
      );
    });

    testWidgets('Time cleared reports null', (tester) async {
      expect(await pick(tester, 'Time', null), isNull);
    });

    testWidgets('Date cleared reports null', (tester) async {
      expect(await pick(tester, 'Date', null), isNull);
    });
  });
}
