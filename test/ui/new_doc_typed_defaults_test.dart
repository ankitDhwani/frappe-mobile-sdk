import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// On a new document Desk types each default by field type before any
/// `depends_on` runs (`frappe.model.set_default_values`): a Check whose default
/// is "0" starts as the number 0. Seeded as the string "0" instead, a bare
/// `eval:doc.flag` reads it as true (a non-empty string), so every field gated
/// on a switch that is off is shown until the user flips the switch on and off.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  DocTypeMeta meta() => DocTypeMeta(
    name: 'Need Analysis',
    fields: <DocField>[
      DocField(
        fieldname: 'needs_support',
        fieldtype: 'Check',
        label: 'Needs Support?',
        defaultValue: '0',
      ),
      DocField(
        fieldname: 'support_note',
        fieldtype: 'Data',
        label: 'Support Note',
        dependsOn: 'eval:doc.needs_support',
      ),
      DocField(
        fieldname: 'support_detail',
        fieldtype: 'Data',
        label: 'Support Detail',
        dependsOn: 'eval:doc.needs_support==1;',
      ),
      DocField(
        fieldname: 'visits',
        fieldtype: 'Int',
        label: 'Visits',
        defaultValue: '2',
      ),
      DocField(
        fieldname: 'rate',
        fieldtype: 'Float',
        label: 'Rate',
        defaultValue: '2.5',
      ),
    ],
  );

  for (final mode in FormBuilderMode.values) {
    group('$mode', () {
      testWidgets(
        'fields under a switch that is off are hidden on a new form',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: FrappeFormBuilder(
                  meta: meta(),
                  mode: mode,
                  onSubmit: (_) {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text('Needs Support?'), findsWidgets);
          expect(find.text('Support Note'), findsNothing);
          expect(find.text('Support Detail'), findsNothing);

          // On, then off again: shown, then hidden.
          await tester.tap(find.byType(Switch).first);
          await tester.pumpAndSettle();
          expect(find.text('Support Note'), findsOneWidget);
          expect(find.text('Support Detail'), findsOneWidget);

          await tester.tap(find.byType(Switch).first);
          await tester.pumpAndSettle();
          expect(find.text('Support Note'), findsNothing);
          expect(find.text('Support Detail'), findsNothing);
        },
      );

      testWidgets('the save carries typed defaults, not their text', (
        tester,
      ) async {
        Map<String, dynamic>? submitted;
        void Function()? submit;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FrappeFormBuilder(
                meta: meta(),
                mode: mode,
                onSubmit: (data) => submitted = data,
                registerSubmit: (fn) => submit = fn,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        submit!();
        await tester.pumpAndSettle();

        expect(submitted, isNotNull);
        expect(submitted!['needs_support'], 0);
        expect(submitted!['visits'], 2);
        expect(submitted!['rate'], 2.5);
      });
    });
  }

  test('FormController seeds typed defaults', () {
    final c = FormController(meta: meta());
    expect(c.getValue('needs_support'), 0);
    expect(c.getValue('visits'), 2);
    expect(c.getValue('rate'), 2.5);
    c.dispose();
  });
}
