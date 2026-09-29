// Field widgets against Frappe's own field semantics (framework source:
// frappe/model/base_document.py, frappe/model/create_new.py,
// frappe/utils/__init__.py). Each assertion is what the server or desk does
// with the same input, not what the widget happens to do today.
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/check_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/data_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/numeric_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/phone_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/select_field.dart';

Future<GlobalKey<FormBuilderState>> _host(
  WidgetTester tester,
  Widget child,
) async {
  final key = GlobalKey<FormBuilderState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FormBuilder(key: key, child: child),
      ),
    ),
  );
  await tester.pump();
  return key;
}

DocField _f(
  String type, {
  String name = 'f',
  String label = 'Amount',
  bool reqd = false,
  bool readOnly = false,
  String? options,
  String? defaultValue,
  int? length,
}) => DocField(
  fieldname: name,
  fieldtype: type,
  label: label,
  reqd: reqd,
  readOnly: readOnly,
  options: options,
  defaultValue: defaultValue,
  length: length,
);

void main() {
  group('NumericField (Int / Float / Currency / Percent)', () {
    testWidgets('Float parses to a double; clearing emits null', (
      tester,
    ) async {
      final changes = <Object?>[];
      await _host(
        tester,
        NumericField(field: _f('Float'), onChanged: changes.add),
      );
      await tester.enterText(find.byType(TextField), '12.5');
      await tester.enterText(find.byType(TextField), '');
      expect(changes, [12.5, null]);
    });

    testWidgets('Int 0 is a value, not "empty"', (tester) async {
      final changes = <Object?>[];
      final key = await _host(
        tester,
        NumericField(
          field: _f('Int', reqd: true),
          value: 0,
          onChanged: changes.add,
        ),
      );
      expect(find.text('0'), findsOneWidget);
      expect(key.currentState!.validate(), isTrue);
      await tester.enterText(find.byType(TextField), '');
      await tester.enterText(find.byType(TextField), '0');
      expect(changes, [null, 0]);
      expect(changes.last, isA<int>());
    });

    testWidgets('Int input cannot carry a decimal point', (tester) async {
      final changes = <Object?>[];
      await _host(
        tester,
        NumericField(field: _f('Int'), onChanged: changes.add),
      );
      await tester.enterText(find.byType(TextField), '-42');
      expect(changes.last, -42);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.keyboardType, const TextInputType.numberWithOptions());
    });

    testWidgets('required number rejects a lone minus sign', (tester) async {
      final key = await _host(
        tester,
        NumericField(field: _f('Int', reqd: true)),
      );
      await tester.enterText(find.byType(TextField), '-');
      expect(key.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('Please enter a valid number'), findsOneWidget);
    });

    testWidgets('required number that is empty says "is required"', (
      tester,
    ) async {
      final key = await _host(
        tester,
        NumericField(field: _f('Currency', reqd: true, label: 'Rate')),
      );
      expect(key.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('Rate is required'), findsOneWidget);
    });

    testWidgets('Currency shows a currency prefix, Percent a % suffix', (
      tester,
    ) async {
      await _host(
        tester,
        Column(
          children: [
            NumericField(field: _f('Currency', name: 'c'), value: 10),
            NumericField(field: _f('Percent', name: 'p'), value: 5),
          ],
        ),
      );
      final fields = tester.widgetList<TextField>(find.byType(TextField));
      expect(fields.first.decoration!.prefixText, isNotNull);
      expect(fields.last.decoration!.suffixText, '%');
    });

    testWidgets('meta default seeds the text when there is no value', (
      tester,
    ) async {
      await _host(
        tester,
        NumericField(field: _f('Float', defaultValue: '2.5')),
      );
      expect(find.text('2.5'), findsOneWidget);
    });

    testWidgets('read-only numeric is not editable', (tester) async {
      await _host(
        tester,
        NumericField(field: _f('Float', readOnly: true), value: 3),
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enabled, isFalse);
    });

    testWidgets(
      'an OPTIONAL number field does not silently drop malformed input',
      (tester) async {
        // BUG SDK2-13 (P2): numeric_field.dart validates the number only when
        // `field.reqd` (:48-58). For an optional Float, "1.2.3" passes
        // validation while onChanged emits null (:62-67): the user sees
        // "1.2.3" on screen and the document is saved with the field EMPTY.
        // Whether a string is a number does not depend on the field being
        // mandatory — the same widget calls it invalid when reqd.
        final changes = <Object?>[];
        final key = await _host(
          tester,
          NumericField(field: _f('Float'), onChanged: changes.add),
        );
        await tester.enterText(find.byType(TextField), '1.2.3');
        final silentlyEmpty = changes.last == null;
        expect(key.currentState!.validate() == false || !silentlyEmpty, isTrue);
      },
      skip: true, // BUG SDK2-13: optional number garbage saved as null
    );
  });

  group('PhoneField (fieldtype Phone)', () {
    testWidgets('a 10-digit number is stored with the dial code and valid', (
      tester,
    ) async {
      final changes = <Object?>[];
      final key = await _host(
        tester,
        PhoneField(
          field: _f('Phone', label: 'Mobile'),
          onChanged: changes.add,
        ),
      );
      await tester.enterText(find.byType(TextField), '9876543210');
      expect(changes.last, '+919876543210');
      expect(key.currentState!.validate(), isTrue);
    });

    testWidgets('stored "+91-9876543210" displays the bare number', (
      tester,
    ) async {
      await _host(
        tester,
        PhoneField(field: _f('Phone'), value: '+91-9876543210'),
      );
      expect(find.text('9876543210'), findsOneWidget);
    });

    test('numberFromStored strips only a real country-code prefix', () {
      expect(PhoneField.numberFromStored('919876543210'), '9876543210');
      // A 10-digit number that merely starts with 9-1 keeps both digits.
      expect(PhoneField.numberFromStored('9198765432'), '9198765432');
      expect(PhoneField.numberFromStored('+91'), '');
      expect(PhoneField.numberFromStored(null), '');
      expect(PhoneField.toStored(' 98-76 '), '+919876');
      expect(PhoneField.toStored(''), '');
    });

    testWidgets('optional and empty is valid; required and empty is not', (
      tester,
    ) async {
      final optional = await _host(tester, PhoneField(field: _f('Phone')));
      expect(optional.currentState!.validate(), isTrue);

      final required = await _host(
        tester,
        PhoneField(field: _f('Phone', reqd: true, label: 'Mobile')),
      );
      expect(required.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('Mobile is required'), findsOneWidget);
    });

    testWidgets(
      'an 8-digit number is rejected (the dial code is not part of it)',
      (tester) async {
        // BUG SDK2-12 (P2): phone_field.dart `_validate` (:68-76, :73) counts
        // digits of the STORED value "+91xxxxxxxx", so the dial code's "9","1" make an
        // 8-digit entry look like 10 digits and it passes. The server runs
        // validate_phone_number_with_country_code on every Phone field
        // (frappe/model/base_document.py:924-926 →
        // frappe/utils/__init__.py:106-126, phonenumbers.is_valid_number),
        // so the record is accepted on the device and rejected at sync.
        final key = await _host(tester, PhoneField(field: _f('Phone')));
        await tester.enterText(find.byType(TextField), '12345678');
        expect(key.currentState!.validate(), isFalse);
        await tester.pump();
        expect(
          find.text('Please enter a valid 10-digit mobile number'),
          findsOneWidget,
        );
      },
      skip: true, // BUG SDK2-12: 8-digit phone passes validation
    );
  });

  group('SelectField defaults', () {
    testWidgets(
      'a Select whose first option is blank is NOT auto-filled',
      (tester) async {
        // BUG SDK2-14 (P2): select_field.dart drops blank options (:44) before
        // deciding to pre-select (:203-209), so options "\nApproved" (blank first =
        // "leave unset") look like a single option and the widget writes
        // "Approved" into the document (post-frame onChanged). Frappe's
        // default for a Select without an explicit default is the FIRST
        // line of options — here "" — both server-side
        // (frappe/model/create_new.py:117-118) and in desk
        // (public/js/frappe/model/create_new.js:107-113).
        final changes = <Object?>[];
        await _host(
          tester,
          SelectField(
            field: _f('Select', options: '\nApproved', label: 'Status'),
            onChanged: changes.add,
          ),
        );
        await tester.pump();
        expect(changes, isEmpty);
      },
      skip: true, // BUG SDK2-14: leading-blank Select auto-filled
    );

    testWidgets('a value outside the options is not shown as selected', (
      tester,
    ) async {
      final changes = <Object?>[];
      await _host(
        tester,
        SelectField(
          field: _f('Select', options: 'Open\nClosed', label: 'Status'),
          value: 'Archived',
          onChanged: changes.add,
        ),
      );
      await tester.pump();
      expect(find.text('Archived'), findsNothing);
      expect(changes, isEmpty);
    });
  });

  group('CheckField (0/1)', () {
    testWidgets('int 1 / "0" / default "1" map to on / off / on', (
      tester,
    ) async {
      await _host(
        tester,
        Column(
          children: [
            CheckField(
              field: _f('Check', name: 'a', label: 'A'),
              value: 1,
            ),
            CheckField(
              field: _f('Check', name: 'b', label: 'B'),
              value: '0',
            ),
            CheckField(
              field: _f('Check', name: 'c', label: 'C', defaultValue: '1'),
            ),
          ],
        ),
      );
      final switches = tester
          .widgetList<Switch>(find.byType(Switch))
          .map((s) => s.value)
          .toList();
      expect(switches, [true, false, true]);
    });

    testWidgets('toggling emits Frappe ints, not bools', (tester) async {
      final changes = <Object?>[];
      await _host(
        tester,
        CheckField(
          field: _f('Check', label: 'Done'),
          value: 0,
          onChanged: changes.add,
        ),
      );
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(changes, [1, 0]);
    });
  });

  group('DataField', () {
    testWidgets('Data is capped at varchar(140) when no length is set', (
      tester,
    ) async {
      final changes = <Object?>[];
      await _host(
        tester,
        DataField(
          field: _f('Data', label: 'Title'),
          onChanged: changes.add,
        ),
      );
      await tester.enterText(find.byType(TextField), 'x' * 150);
      await tester.pump();
      expect((changes.last as String).length, 140);
      expect(find.text('140/140'), findsOneWidget);
    });

    testWidgets('an explicit DocField.length overrides the 140 default', (
      tester,
    ) async {
      final changes = <Object?>[];
      await _host(
        tester,
        DataField(
          field: _f('Data', label: 'Code', length: 5),
          onChanged: changes.add,
        ),
      );
      await tester.enterText(find.byType(TextField), 'ABCDEFG');
      expect(changes.last, 'ABCDE');
    });

    testWidgets('a Phone-typed DataField keeps the + prefix', (tester) async {
      final changes = <Object?>[];
      final key = await _host(
        tester,
        DataField(
          field: _f('Phone', label: 'Contact'),
          value: '919876543210',
          onChanged: changes.add,
        ),
      );
      expect(find.text('+919876543210'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '14155550123');
      expect(changes.last, '+14155550123');
      expect(key.currentState!.validate(), isFalse); // text lacks "+"
      await tester.enterText(find.byType(TextField), '+1 415');
      expect(key.currentState!.validate(), isFalse);
      await tester.pump();
      expect(
        find.text('Please enter a valid phone number with country code'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), '+1 (415) 555-0123');
      expect(key.currentState!.validate(), isTrue);
    });
  });
}
