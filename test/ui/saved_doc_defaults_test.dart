import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Desk applies `set_default_values` to NEW documents only. Frappe leaves null
/// fields out of a saved document it returns, so a saved record's empty field
/// is absent from initialData. Seeding its `default` there would write the
/// current user (`__user`), the current time (`now`) or the literal default on
/// the next save of a record whose field was deliberately left empty, or that
/// the user has just cleared.
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
  DateTime clock() => DateTime(2026, 10, 13, 9, 5, 7);
  final timestamp = RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$');

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
        fieldname: 'logged_at',
        fieldtype: 'Datetime',
        label: 'Logged At',
        defaultValue: 'now',
      ),
      DocField(
        fieldname: 'status',
        fieldtype: 'Data',
        label: 'Status',
        defaultValue: 'Open',
      ),
      DocField(
        fieldname: 'priority',
        fieldtype: 'Select',
        label: 'Priority',
        options: 'Low\nHigh',
        defaultValue: 'High',
      ),
    ],
  );
  const defaulted = ['logged_by', 'logged_at', 'status', 'priority'];

  void expectNoDefaults(Map<String, dynamic> payload) {
    for (final f in defaulted) {
      expect(payload[f], anyOf(isNull, ''), reason: '$f got a default');
    }
    expect(payload['logged_by'], isNot(user.name));
    expect(payload['logged_at'], isNot(matches(timestamp)));
  }

  void expectDefaults(Map<String, dynamic> payload) {
    expect(payload['logged_by'], user.name);
    expect(payload['logged_at'], matches(timestamp));
    expect(payload['status'], 'Open');
    expect(payload['priority'], 'High');
  }

  group('FormController', () {
    FormController controller([Map<String, dynamic>? data]) {
      final c = FormController(
        meta: meta(),
        initialData: data,
        sessionUser: user,
        now: clock,
      );
      addTearDown(c.dispose);
      return c;
    }

    for (final identity in const <Map<String, dynamic>>[
      {'name': 'DOC-1'},
      {'server_name': 'DOC-1'},
      {'mobile_uuid': 'u-1'},
    ]) {
      test('a saved document ($identity) with the fields absent gets no '
          'default', () {
        final c = controller(identity);
        for (final f in defaulted) {
          expect(c.getValue(f), isNull, reason: '$f was seeded');
        }
        expectNoDefaults(c.buildSubmitData());
      });
    }

    test('a field the user clears on a saved document stays cleared', () {
      final c = controller(const {
        'name': 'DOC-1',
        'logged_by': 'other.user@example.com',
        'logged_at': '2026-01-02 03:04:05',
        'status': 'Closed',
        'priority': 'Low',
      });
      for (final f in defaulted) {
        c.setValue(f, null, source: ChangeSource.user);
      }
      expectNoDefaults(c.buildSubmitData());
    });

    test('a saved document keeps its own values', () {
      final c = controller(const {
        'name': 'DOC-1',
        'logged_by': 'other.user@example.com',
        'status': 'Closed',
      });
      final p = c.buildSubmitData();
      expect(p['logged_by'], 'other.user@example.com');
      expect(p['status'], 'Closed');
      expect(p['logged_at'], anyOf(isNull, ''));
      expect(p['priority'], anyOf(isNull, ''));
    });

    test('a new document still gets its defaults', () {
      final c = controller();
      expect(c.getValue('logged_by'), user.name);
      expect(c.getValue('logged_at'), '2026-10-13 09:05:07');
      expect(c.getValue('status'), 'Open');
      expect(c.getValue('priority'), 'High');
      expectDefaults(c.buildSubmitData());
    });

    test('a prefilled new document gets defaults for the other fields', () {
      final c = controller(const {'status': 'Draft'});
      final p = c.buildSubmitData();
      expect(p['status'], 'Draft');
      expect(p['logged_by'], user.name);
      expect(p['priority'], 'High');
    });

    test('reset to a saved document stops applying defaults', () {
      final c = controller();
      c.reset(initialData: const {'name': 'DOC-1'});
      for (final f in defaulted) {
        expect(c.getValue(f), isNull, reason: '$f was seeded');
      }
      expectNoDefaults(c.buildSubmitData());
    });

    test('reset to a new document applies defaults again', () {
      final c = controller(const {'name': 'DOC-1'});
      c.reset();
      expect(c.getValue('logged_by'), user.name);
      expectDefaults(c.buildSubmitData());
    });
  });

  // The field widget of an empty, defaulted field on a saved document must
  // not re-enter the controller as a user edit when the form opens: no
  // reaction fires and the form does not open dirty.
  testWidgets('reactive: opening a saved document is not an edit', (
    tester,
  ) async {
    final changed = <String>[];
    final c = FormController(
      meta: meta(),
      initialData: const {'name': 'DOC-1'},
      sessionUser: user,
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta(),
            mode: FormBuilderMode.reactive,
            controller: c,
            initialData: const {'name': 'DOC-1'},
            sessionUser: user,
            onSubmit: (_) {},
            onFieldChange: (name, value, data, {source = ChangeSource.user}) {
              changed.add(name);
              return null;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(changed, isEmpty);
    expect(c.isDirty.value, isFalse);
    for (final f in defaulted) {
      expect(c.getValue(f), isNull, reason: '$f changed on open');
    }
  });

  for (final mode in FormBuilderMode.values) {
    group('$mode FrappeFormBuilder', () {
      Future<Map<String, dynamic>> save(
        WidgetTester tester, {
        Map<String, dynamic>? initialData,
      }) async {
        Map<String, dynamic>? out;
        void Function()? submit;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FrappeFormBuilder(
                meta: meta(),
                mode: mode,
                sessionUser: user,
                initialData: initialData,
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
        expect(out, isNotNull, reason: 'the form should save');
        return out!;
      }

      testWidgets('a saved document with the fields absent gets no default', (
        tester,
      ) async {
        expectNoDefaults(
          await save(tester, initialData: const {'name': 'DOC-1'}),
        );
        // Nor shown: a field displaying its default while the save sends it
        // empty would show the user a value that is never saved.
        expect(find.text(user.name), findsNothing);
        expect(find.text('__user'), findsNothing);
        expect(find.text('Open'), findsNothing);
      });

      // A mandatory field with a default, empty on a saved document, is
      // missing (as in Desk), not filled in by the default and saved.
      Future<Map<String, dynamic>?> saveRequired(
        WidgetTester tester, {
        Map<String, dynamic>? initialData,
      }) async {
        Map<String, dynamic>? out;
        void Function()? submit;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FrappeFormBuilder(
                meta: DocTypeMeta(
                  name: 'Meeting Log',
                  fields: <DocField>[
                    DocField(
                      fieldname: 'code',
                      fieldtype: 'Data',
                      label: 'Code',
                      reqd: true,
                      defaultValue: 'C-1',
                    ),
                  ],
                ),
                mode: mode,
                initialData: initialData,
                onSubmit: (d) => out = d,
                registerSubmit: (fn) => submit = fn,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        submit!();
        await tester.pumpAndSettle();
        return out;
      }

      testWidgets('a mandatory field with a default, empty on a saved '
          'document, blocks the save', (tester) async {
        expect(
          await saveRequired(tester, initialData: const {'name': 'DOC-1'}),
          isNull,
        );
      });

      testWidgets('a mandatory field with a default saves it on a new '
          'document', (tester) async {
        expect((await saveRequired(tester))?['code'], 'C-1');
      });

      testWidgets('a saved document with the fields cleared to null gets no '
          'default', (tester) async {
        expectNoDefaults(
          await save(
            tester,
            initialData: const {
              'name': 'DOC-1',
              'logged_by': null,
              'logged_at': null,
              'status': null,
              'priority': null,
            },
          ),
        );
      });

      testWidgets('a new document still gets its defaults', (tester) async {
        expectDefaults(await save(tester));
      });
    });
  }
}
