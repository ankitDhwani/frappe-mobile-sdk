import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Field status the way Desk decides it (`frappe.perm.get_field_display_status`):
/// a `set_only_once` field is read-only once the document is saved, an
/// `is_virtual` field is always read-only. "Saved" means it has a `name`, or,
/// for a record read from the offline store, a `server_name`; an offline record
/// that has not synced yet is still new (`__islocal`).
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final meta = DocTypeMeta.fromJson({
    'name': 'Framework Entry',
    'fields': [
      {
        'fieldname': 'owner_ref',
        'fieldtype': 'Data',
        'label': 'Owner Ref',
        'set_only_once': 1,
      },
      {
        'fieldname': 'computed_total',
        'fieldtype': 'Data',
        'label': 'Computed Total',
        'is_virtual': 1,
      },
      {'fieldname': 'note', 'fieldtype': 'Data', 'label': 'Note'},
      {
        'fieldname': 'saved_only',
        'fieldtype': 'Data',
        'label': 'Saved Only',
        'depends_on': 'eval:!doc.__islocal',
      },
    ],
  });

  bool enabled(WidgetTester t, String fieldname) => t
      .widget<FormBuilderTextField>(find.byKey(ValueKey('data_$fieldname')))
      .enabled;

  for (final mode in FormBuilderMode.values) {
    group('$mode', () {
      Future<void> pump(WidgetTester t, Map<String, dynamic>? data) async {
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FrappeFormBuilder(
                meta: meta,
                mode: mode,
                initialData: data,
                onSubmit: (_) {},
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
      }

      testWidgets('new document: set_only_once is editable', (t) async {
        await pump(t, null);
        expect(enabled(t, 'owner_ref'), isTrue);
        expect(enabled(t, 'computed_total'), isFalse);
        expect(enabled(t, 'note'), isTrue);
        expect(find.text('Saved Only'), findsNothing);
      });

      testWidgets('saved document: set_only_once is read-only', (t) async {
        await pump(t, {'name': 'FE-0001', 'owner_ref': 'EP-1'});
        expect(enabled(t, 'owner_ref'), isFalse);
        expect(enabled(t, 'note'), isTrue);
        expect(find.text('Saved Only'), findsOneWidget);
      });

      testWidgets('synced record from the offline store counts as saved', (
        t,
      ) async {
        await pump(t, {
          'server_name': 'FE-0001',
          'mobile_uuid': 'u-1',
          'owner_ref': 'EP-1',
        });
        expect(enabled(t, 'owner_ref'), isFalse);
        expect(find.text('Saved Only'), findsOneWidget);
      });

      testWidgets('offline record not yet synced is still new', (t) async {
        await pump(t, {'mobile_uuid': 'u-2', 'owner_ref': 'EP-1'});
        expect(enabled(t, 'owner_ref'), isTrue);
        expect(find.text('Saved Only'), findsNothing);
      });
    });
  }

  test('__islocal reads a server_name as saved', () {
    expect(
      DependsOnEvaluator.evaluate('eval:!doc.__islocal', {'server_name': 'X'}),
      isTrue,
    );
    expect(DependsOnEvaluator.evaluate('eval:!doc.__islocal', {}), isFalse);
  });
}
