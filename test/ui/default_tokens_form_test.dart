import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Default tokens on a new document, resolved as Desk resolves them
/// (`frappe.model.get_default_value`) instead of saved as their text. A Time
/// or Datetime field defaulting to `now` threw while building, and `__user`
/// reached the server as the literal text "__user".
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const user = SessionUser(
    name: 'field.user@example.com',
    fullName: 'Field User',
    roles: [],
    permissions: {},
    userDefaults: {},
    extras: {},
  );

  DocTypeMeta meta() => DocTypeMeta(
    name: 'Meeting Log',
    fields: <DocField>[
      DocField(
        fieldname: 'logged_by',
        fieldtype: 'Data',
        label: 'Logged By',
        defaultValue: '__user',
      ),
      DocField(
        fieldname: 'logged_by_name',
        fieldtype: 'Data',
        label: 'Logged By Name',
        defaultValue: 'user_fullname',
      ),
      DocField(
        fieldname: 'logged_at',
        fieldtype: 'Datetime',
        label: 'Logged At',
        defaultValue: 'now',
      ),
      DocField(
        fieldname: 'start_time',
        fieldtype: 'Time',
        label: 'Start Time',
        defaultValue: 'now',
      ),
    ],
  );

  for (final mode in FormBuilderMode.values) {
    group('$mode', () {
      Future<Map<String, dynamic>> save(
        WidgetTester tester, {
        SessionUser? sessionUser,
      }) async {
        Map<String, dynamic>? out;
        void Function()? submit;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FrappeFormBuilder(
                meta: meta(),
                mode: mode,
                sessionUser: sessionUser,
                onSubmit: (d) => out = d,
                registerSubmit: (fn) => submit = fn,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'fields build');
        submit!();
        await tester.pumpAndSettle();
        return out!;
      }

      testWidgets('tokens are resolved for the signed-in user', (tester) async {
        final p = await save(tester, sessionUser: user);
        expect(p['logged_by'], 'field.user@example.com');
        expect(p['logged_by_name'], 'Field User');
        expect(
          p['logged_at'],
          matches(RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$')),
        );
        expect(p['start_time'], matches(RegExp(r'^\d\d:\d\d:\d\d$')));
      });

      testWidgets('with no signed-in user no token text is saved', (
        tester,
      ) async {
        final p = await save(tester);
        expect(p['logged_by'], isNot('__user'));
        expect(p['logged_by_name'], isNot('user_fullname'));
      });
    });
  }
}
