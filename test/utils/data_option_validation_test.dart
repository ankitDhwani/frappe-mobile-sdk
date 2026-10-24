import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/utils/data_option_validation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A Data field with options Email, Phone, Name or URL is checked by Frappe
/// on save (`BaseDocument._validate_data_fields`). Offline, the SDK only hears
/// that at sync, so the form checks it with the same rules first.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  String? e(String options, String value) => dataOptionError(options, value);

  test('Email: each address in the list must be valid', () {
    expect(e('Email', 'person@example.com'), isNull);
    expect(e('Email', 'a@example.com, b@example.org'), isNull);
    expect(e('Email', 'Person <person@example.com>'), isNull);
    expect(e('Email', 'abc'), 'abc is not a valid Email Address');
    expect(e('Email', 'a@example.com, nope'), isNotNull);
  });

  test('Phone: digits and + - _ , . * # ( ) spaces, up to 20', () {
    expect(e('Phone', '+91 98765-43210'), isNull);
    expect(e('Phone', '98765abc'), '98765abc is not a valid Phone Number');
    expect(e('Phone', '1' * 21), isNotNull);
  });

  test('Name: words with apostrophes and hyphens, any script', () {
    expect(e('Name', "Anne-Marie O'Neil"), isNull);
    expect(e('Name', 'राम कुमार'), isNull);
    expect(e('Name', 'Bad  Name!'), isNotNull);
  });

  test('URL: a scheme with a host or path, or a site path', () {
    expect(e('URL', 'https://example.com/a?b=1'), isNull);
    expect(e('URL', '/files/report.pdf'), isNull);
    expect(e('URL', 'not a url'), "'not a url' is not a valid URL");
  });

  test('empty values and other options are not checked', () {
    expect(e('Email', ''), isNull);
    expect(e('Barcode', 'anything'), isNull);
  });

  for (final mode in FormBuilderMode.values) {
    testWidgets('$mode: an invalid email blocks the save', (tester) async {
      Map<String, dynamic>? out;
      void Function()? submit;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: DocTypeMeta(
                name: 'Contact Entry',
                fields: [
                  DocField(
                    fieldname: 'email',
                    fieldtype: 'Data',
                    options: 'Email',
                    label: 'Email',
                  ),
                ],
              ),
              mode: mode,
              onSubmit: (d) => out = d,
              registerSubmit: (fn) => submit = fn,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('data_email')), 'abc');
      await tester.pumpAndSettle();
      submit!();
      await tester.pumpAndSettle();
      expect(out, isNull);
      expect(find.text('abc is not a valid Email Address'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('data_email')),
        'person@example.com',
      );
      await tester.pumpAndSettle();
      submit!();
      await tester.pumpAndSettle();
      expect(out?['email'], 'person@example.com');
    });
  }
}
