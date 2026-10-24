import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/utils/field_defaults.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// On a new document Desk gives a Select with no default its first option
/// (`frappe.model.set_default_values`). Left empty instead, fields gated on
/// that value (`eval:doc.phase=='Existing'`) stay hidden on a new form, and
/// the save sends an empty value Desk would never send.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Object? d(String? options, {String? def}) => typedDefaultValue(
    DocField(
      fieldname: 'f',
      fieldtype: 'Select',
      options: options,
      defaultValue: def,
    ),
  );

  test('a Select with no default starts on its first option', () {
    expect(d('Existing\nNew'), 'Existing');
    expect(d('Existing\nNew', def: 'New'), 'New');
  });

  test('a list that starts blank, or no options, stays empty', () {
    expect(d('\nA\nB'), isNull);
    expect(d(null), isNull);
    expect(d(''), isNull);
  });

  DocTypeMeta meta() => DocTypeMeta(
    name: 'Promotion Entry',
    fields: <DocField>[
      DocField(
        fieldname: 'phase',
        fieldtype: 'Select',
        label: 'Phase',
        options: 'Existing\nNew',
      ),
      DocField(
        fieldname: 'existing_channel',
        fieldtype: 'Data',
        label: 'Existing Channel',
        dependsOn: "eval:doc.phase=='Existing'",
      ),
    ],
  );

  for (final mode in FormBuilderMode.values) {
    testWidgets('$mode: a new form starts on the first option', (tester) async {
      Map<String, dynamic>? out;
      void Function()? submit;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: meta(),
              mode: mode,
              onSubmit: (d) => out = d,
              registerSubmit: (fn) => submit = fn,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Existing Channel'), findsOneWidget);
      submit!();
      await tester.pumpAndSettle();
      expect(out!['phase'], 'Existing');
    });
  }

  testWidgets('a saved document keeps its own value', (tester) async {
    Map<String, dynamic>? out;
    void Function()? submit;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta(),
            initialData: const {'name': 'PE-1', 'phase': 'New'},
            onSubmit: (d) => out = d,
            registerSubmit: (fn) => submit = fn,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    submit!();
    await tester.pumpAndSettle();
    expect(out!['phase'], 'New');
  });

  // Frappe omits null fields from a saved document it returns, so an unset
  // Select is ABSENT from initialData. Desk applies set_default_values to new
  // documents only; seeding the first option here would write it on the next
  // save of a document whose Select was deliberately left empty.
  for (final mode in FormBuilderMode.values) {
    testWidgets('$mode: a saved document with the Select unset is NOT given '
        'the first option', (tester) async {
      Map<String, dynamic>? out;
      void Function()? submit;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: meta(),
              mode: mode,
              initialData: const {'name': 'PE-1'},
              onSubmit: (d) => out = d,
              registerSubmit: (fn) => submit = fn,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      submit!();
      await tester.pumpAndSettle();
      expect(out!['phase'], anyOf(isNull, ''));
    });
  }

  test('isNewDocumentData: no name, server_name or mobile_uuid', () {
    expect(isNewDocumentData(null), isTrue);
    expect(isNewDocumentData(const {'phase': 'New'}), isTrue);
    expect(isNewDocumentData(const {'name': 'PE-1'}), isFalse);
    expect(isNewDocumentData(const {'server_name': 'PE-1'}), isFalse);
    expect(isNewDocumentData(const {'mobile_uuid': 'u-1'}), isFalse);
  });

  // Desk applies set_default_values to new documents only: an explicit default
  // is not applied to a saved document either (saved_doc_defaults_test.dart).
  test('typedDefaultValue: a saved document gets neither an explicit default '
      'nor the first option', () {
    final withDefault = DocField(
      fieldname: 'phase',
      fieldtype: 'Select',
      options: 'New\nOld',
      defaultValue: 'Old',
    );
    final noDefault = DocField(
      fieldname: 'phase',
      fieldtype: 'Select',
      options: 'New\nOld',
    );
    expect(typedDefaultValue(withDefault, newDocument: false), isNull);
    expect(typedDefaultValue(noDefault, newDocument: false), isNull);
    expect(typedDefaultValue(withDefault), 'Old');
    expect(typedDefaultValue(noDefault), 'New');
  });
}
