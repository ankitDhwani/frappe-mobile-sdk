// Legacy-mode FrappeFormBuilder: fetch_from, dependent-Link clearing and
// default seeding, checked against Frappe Desk and against the SDK's own
// reactive engine (FormController), which the legacy path must agree with.
//
// Desk references (Frappe v16):
//   * link.js `validate_link_and_fetch`: when the Link is cleared
//     (`if (!value) update_dependant_fields()`), every fetch_from target is set
//     to "".
//   * create_new.js `get_default_value`: default "Today" -> today's date;
//     default "now" on a Datetime -> the current datetime.
//   * form_controller.dart: link-filter clearing sets the dependent Link to
//     null (exact source-field match), and fetch_from ignores a stale response
//     whose source changed since dispatch.
//
// Link fields here have no LinkOptionService, so they render as a plain text
// input (key `link_text_<fieldname>`), which lets a test type a value.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart'
    show ChangeSource;
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

DocTypeMeta _fetchMeta() => DocTypeMeta(
  name: 'Task',
  fields: [
    DocField(
      fieldname: 'customer',
      fieldtype: 'Link',
      label: 'Customer',
      options: 'Customer',
    ),
    DocField(
      fieldname: 'customer_name',
      fieldtype: 'Data',
      label: 'Customer Name',
      fetchFrom: 'customer.customer_name',
    ),
    DocField(
      fieldname: 'territory',
      fieldtype: 'Data',
      label: 'Territory',
      fetchFrom: 'customer.territory',
    ),
  ],
);

class _Harness {
  Map<String, dynamic>? submitted;
  void Function()? submit;
  final changes = <({String field, Map<String, dynamic> snapshot})>[];

  Widget build({
    required DocTypeMeta meta,
    Map<String, dynamic>? initialData,
    Future<Map<String, dynamic>?> Function(String, String)? fetch,
  }) => MaterialApp(
    home: Scaffold(
      body: FrappeFormBuilder(
        meta: meta,
        initialData: initialData,
        fetchLinkedDocument: fetch,
        onSubmit: (d) => submitted = d,
        registerSubmit: (fn) => submit = fn,
        onFieldChange:
            (
              String name,
              dynamic value,
              Map<String, dynamic> data, {
              ChangeSource source = ChangeSource.user,
            }) {
              changes.add((field: name, snapshot: data));
              return null;
            },
      ),
    ),
  );

  Future<Map<String, dynamic>> save(WidgetTester tester) async {
    submitted = null;
    submit!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(submitted, isNotNull, reason: 'the form should validate and save');
    return submitted!;
  }
}

Future<Map<String, dynamic>?> _customerLookup(String doctype, String name) =>
    Future.value({
      'name': name,
      'customer_name': 'Name of $name',
      'territory': 'North',
    });

void main() {
  group('fetch_from', () {
    testWidgets('picking a Link fills its fetch_from targets', (tester) async {
      final h = _Harness();
      final asked = <String>[];
      await tester.pumpWidget(
        h.build(
          meta: _fetchMeta(),
          fetch: (dt, name) {
            asked.add('$dt/$name');
            return _customerLookup(dt, name);
          },
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('link_text_customer')),
        'CUST-1',
      );
      await tester.pump();
      await tester.pump();

      expect(asked, ['Customer/CUST-1']);
      expect(find.text('Name of CUST-1'), findsOneWidget);
      final saved = await h.save(tester);
      expect(saved['customer'], 'CUST-1');
      expect(saved['customer_name'], 'Name of CUST-1');
      expect(saved['territory'], 'North');
    });

    testWidgets('a prefilled Link fetches its targets on first frame', (
      tester,
    ) async {
      final h = _Harness();
      final asked = <String>[];
      await tester.pumpWidget(
        h.build(
          meta: _fetchMeta(),
          initialData: const {'customer': 'CUST-9'},
          fetch: (dt, name) {
            asked.add(name);
            return _customerLookup(dt, name);
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(asked, ['CUST-9']);
      final saved = await h.save(tester);
      expect(saved['customer_name'], 'Name of CUST-9');
    });

    testWidgets('a lookup that returns null leaves the targets alone', (
      tester,
    ) async {
      final h = _Harness();
      await tester.pumpWidget(
        h.build(
          meta: _fetchMeta(),
          initialData: const {'customer_name': 'typed by hand'},
          fetch: (_, _) => Future.value(null),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('link_text_customer')),
        'CUST-404',
      );
      await tester.pump();
      await tester.pump();
      final saved = await h.save(tester);
      expect(saved['customer_name'], 'typed by hand');
    });

    testWidgets('a lookup that throws does not break the form', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(
        h.build(
          meta: _fetchMeta(),
          fetch: (_, _) => Future.error(StateError('offline')),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('link_text_customer')),
        'CUST-2',
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      final saved = await h.save(tester);
      expect(saved['customer'], 'CUST-2');
    });

    testWidgets('a fetched Link target cascades into its own fetch_from', (
      tester,
    ) async {
      final meta = DocTypeMeta(
        name: 'Task',
        fields: [
          DocField(fieldname: 'project', fieldtype: 'Link', options: 'Project'),
          DocField(
            fieldname: 'customer',
            fieldtype: 'Link',
            options: 'Customer',
            fetchFrom: 'project.customer',
          ),
          DocField(
            fieldname: 'customer_name',
            fieldtype: 'Data',
            fetchFrom: 'customer.customer_name',
          ),
        ],
      );
      final h = _Harness();
      final asked = <String>[];
      await tester.pumpWidget(
        h.build(
          meta: meta,
          fetch: (dt, name) {
            asked.add('$dt/$name');
            if (dt == 'Project') return Future.value({'customer': 'CUST-7'});
            return _customerLookup(dt, name);
          },
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('link_text_project')),
        'PROJ-1',
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(asked, ['Project/PROJ-1', 'Customer/CUST-7']);
      final saved = await h.save(tester);
      expect(saved['customer'], 'CUST-7');
      expect(saved['customer_name'], 'Name of CUST-7');
    });

    testWidgets(
      'clearing the Link blanks every fetch_from target (Desk link.js)',
      (tester) async {
        final h = _Harness();
        await tester.pumpWidget(
          h.build(meta: _fetchMeta(), fetch: _customerLookup),
        );
        final link = find.byKey(const ValueKey('link_text_customer'));
        await tester.enterText(link, 'CUST-1');
        await tester.pump();
        await tester.pump();
        expect(find.text('Name of CUST-1'), findsOneWidget);

        await tester.enterText(link, '');
        await tester.pump();
        await tester.pump();
        final saved = await h.save(tester);
        expect(
          saved['customer_name'] ?? '',
          '',
          reason: 'the previous customer\'s name must not survive the clear',
        );
        expect(saved['territory'] ?? '', '');
      },
      skip: true, // BUG SDK-14
      // clearing a Link leaves its fetch_from targets holding the
      // previous linked document's values (both engines skip fetch on an empty
      // value; Desk sets targets to "")
    );

    testWidgets(
      'a slow response for an older pick does not overwrite a newer pick',
      (tester) async {
        final pending = <String, Completer<Map<String, dynamic>?>>{};
        final h = _Harness();
        await tester.pumpWidget(
          h.build(
            meta: _fetchMeta(),
            fetch: (dt, name) =>
                (pending[name] = Completer<Map<String, dynamic>?>()).future,
          ),
        );
        final link = find.byKey(const ValueKey('link_text_customer'));
        await tester.enterText(link, 'CUST-A');
        await tester.pump();
        await tester.enterText(link, 'CUST-B');
        await tester.pump();

        // Newer answer lands first, the stale one last.
        pending['CUST-B']!.complete({'customer_name': 'B', 'territory': 'B'});
        await tester.pump();
        pending['CUST-A']!.complete({'customer_name': 'A', 'territory': 'A'});
        await tester.pump();
        await tester.pump();

        final saved = await h.save(tester);
        expect(saved['customer'], 'CUST-B');
        expect(
          saved['customer_name'],
          'B',
          reason:
              'FormController drops a response whose source changed since '
              'dispatch; the legacy engine must not apply CUST-A\'s data to a '
              'form that now links CUST-B',
        );
      },
      skip: true, // BUG SDK-15
      // legacy _handleFetchFrom has no latest-wins guard; an out-
      // of-order response writes the OLD link's values into the form
    );
  });

  group('dependent Link clearing (link_filters)', () {
    DocTypeMeta meta() => DocTypeMeta(
      name: 'Task',
      fields: [
        DocField(fieldname: 'region', fieldtype: 'Data', label: 'Region'),
        DocField(
          fieldname: 'region_group',
          fieldtype: 'Data',
          label: 'Region Group',
        ),
        DocField(
          fieldname: 'contact',
          fieldtype: 'Link',
          label: 'Contact',
          options: 'Contact',
          linkFilters: '[["Contact","group","=","eval:doc.region_group"]]',
        ),
      ],
    );

    const initial = {'region': 'R1', 'region_group': 'G1', 'contact': 'CT-1'};

    testWidgets(
      'editing a field whose NAME IS A PREFIX of the filter source keeps the '
      'dependent Link',
      (tester) async {
        final h = _Harness();
        await tester.pumpWidget(h.build(meta: meta(), initialData: initial));
        await tester.enterText(find.byKey(const ValueKey('data_region')), 'R2');
        await tester.pump();

        final change = h.changes.lastWhere((c) => c.field == 'region');
        expect(
          change.snapshot['contact'],
          'CT-1',
          reason:
              'contact filters on region_group, not region; the reactive '
              'engine matches the source field exactly',
        );
      },
      skip: true, // BUG SDK-16
      // the legacy clear regex `eval:doc.<field>` has no word
      // boundary, so editing `region` clears a Link filtered on
      // `doc.region_group`
    );

    testWidgets('editing an unrelated field keeps the dependent Link', (
      tester,
    ) async {
      final meta2 = DocTypeMeta(
        name: 'Task',
        fields: [
          DocField(fieldname: 'notes', fieldtype: 'Data'),
          ...meta().fields,
        ],
      );
      final h = _Harness();
      await tester.pumpWidget(h.build(meta: meta2, initialData: initial));
      await tester.enterText(find.byKey(const ValueKey('data_notes')), 'x');
      await tester.pump();
      final change = h.changes.lastWhere((c) => c.field == 'notes');
      expect(change.snapshot['contact'], 'CT-1');
    });

    testWidgets('editing the filter source drops the Link from handler data', (
      tester,
    ) async {
      final h = _Harness();
      await tester.pumpWidget(h.build(meta: meta(), initialData: initial));
      await tester.enterText(
        find.byKey(const ValueKey('data_region_group')),
        'G2',
      );
      await tester.pump();
      final change = h.changes.lastWhere((c) => c.field == 'region_group');
      expect(change.snapshot.containsKey('contact'), isFalse);
    });

    testWidgets(
      'editing the filter source also drops the stale Link from the save',
      (tester) async {
        final h = _Harness();
        await tester.pumpWidget(h.build(meta: meta(), initialData: initial));
        await tester.enterText(
          find.byKey(const ValueKey('data_region_group')),
          'G2',
        );
        await tester.pump();
        final saved = await h.save(tester);
        expect(
          saved['contact'] ?? '',
          '',
          reason:
              'handlers were told contact is cleared; the payload must agree '
              '(FormController sets it to null)',
        );
      },
      skip: true, // BUG SDK-17
      // the legacy clear removes the Link only from _formData; the
      // FormBuilder field state still holds it, so the stale value is saved
      // while onFieldChange saw it as cleared
    );
  });

  group('default seeding', () {
    String today() {
      final n = DateTime.now();
      return '${n.year}-${n.month.toString().padLeft(2, '0')}-'
          '${n.day.toString().padLeft(2, '0')}';
    }

    testWidgets('Date default "Today" seeds today\'s date', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(
        h.build(
          meta: DocTypeMeta(
            name: 'Task',
            fields: [
              DocField(
                fieldname: 'due_on',
                fieldtype: 'Date',
                defaultValue: 'Today',
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      final saved = await h.save(tester);
      expect(saved['due_on'], today());
    });

    testWidgets('a hidden field default is submitted', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(
        h.build(
          meta: DocTypeMeta(
            name: 'Task',
            fields: [
              DocField(fieldname: 'subject', fieldtype: 'Data'),
              DocField(
                fieldname: 'kind',
                fieldtype: 'Data',
                hidden: true,
                defaultValue: 'General',
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      final saved = await h.save(tester);
      expect(saved['kind'], 'General');
    });

    testWidgets('a data default is submitted when untouched', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(
        h.build(
          meta: DocTypeMeta(
            name: 'Task',
            fields: [
              DocField(
                fieldname: 'status',
                fieldtype: 'Data',
                defaultValue: 'Open',
              ),
              DocField(fieldname: 'flag', fieldtype: 'Check'),
              DocField(fieldname: 'qty', fieldtype: 'Int'),
            ],
          ),
        ),
      );
      await tester.pump();
      final saved = await h.save(tester);
      expect(saved['status'], 'Open');
      expect(saved['flag'], anyOf(0, false));
    });

    testWidgets(
      'Datetime default "Now" seeds a datetime, not the literal keyword',
      (tester) async {
        final h = _Harness();
        await tester.pumpWidget(
          h.build(
            meta: DocTypeMeta(
              name: 'Task',
              fields: [
                DocField(fieldname: 'subject', fieldtype: 'Data'),
                DocField(
                  fieldname: 'logged_at',
                  fieldtype: 'Datetime',
                  defaultValue: 'Now',
                ),
              ],
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'form must render');
        final saved = await h.save(tester);
        expect(saved['logged_at'], isNot('Now'));
        expect(
          DateTime.tryParse(saved['logged_at'].toString()),
          isNotNull,
          reason: 'create_new.js: default "now" -> system_datetime()',
        );
      },
      skip: true, // BUG SDK-18
      // only Date+"today" is resolved; a Datetime default "Now" is
      // seeded as the string "Now"
    );

    testWidgets(
      'Date default "Today" is still resolved after initialData changes',
      (tester) async {
        final meta = DocTypeMeta(
          name: 'Task',
          fields: [
            DocField(fieldname: 'subject', fieldtype: 'Data'),
            DocField(
              fieldname: 'due_on',
              fieldtype: 'Date',
              defaultValue: 'Today',
            ),
          ],
        );
        final h = _Harness();
        await tester.pumpWidget(
          h.build(meta: meta, initialData: const {'subject': 'a'}),
        );
        await tester.pump();
        // Host rebuilds with different initial data -> didUpdateWidget re-seeds.
        await tester.pumpWidget(
          h.build(meta: meta, initialData: const {'subject': 'b'}),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final saved = await h.save(tester);
        expect(saved['due_on'], today());
      },
      skip: true, // BUG SDK-19
      // didUpdateWidget re-seeds defaults without the "Today"
      // conversion (and skips hidden fields), unlike initState
    );

    testWidgets(
      'a hidden field default survives an initialData change',
      (tester) async {
        final meta = DocTypeMeta(
          name: 'Task',
          fields: [
            DocField(fieldname: 'subject', fieldtype: 'Data'),
            DocField(
              fieldname: 'kind',
              fieldtype: 'Data',
              hidden: true,
              defaultValue: 'General',
            ),
          ],
        );
        final h = _Harness();
        await tester.pumpWidget(
          h.build(meta: meta, initialData: const {'subject': 'a'}),
        );
        await tester.pump();
        await tester.pumpWidget(
          h.build(meta: meta, initialData: const {'subject': 'b'}),
        );
        await tester.pump();
        final saved = await h.save(tester);
        expect(saved['kind'], 'General');
      },
      skip: true, // BUG SDK-19
      // didUpdateWidget re-seeds defaults only for non-hidden
      // fields, so a hidden default is dropped from the save
    );
  });

  group('empty stored values', () {
    testWidgets('a null Date value renders an empty picker', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(
        h.build(
          meta: DocTypeMeta(
            name: 'Task',
            fields: [
              DocField(fieldname: 'subject', fieldtype: 'Data'),
              DocField(fieldname: 'due_on', fieldtype: 'Date'),
            ],
          ),
          initialData: const {'subject': 's', 'due_on': null},
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final saved = await h.save(tester);
      expect(saved['subject'], 's');
    });

    testWidgets(
      'an empty-string Date value renders an empty picker',
      (tester) async {
        final h = _Harness();
        await tester.pumpWidget(
          h.build(
            meta: DocTypeMeta(
              name: 'Task',
              fields: [
                DocField(fieldname: 'subject', fieldtype: 'Data'),
                DocField(fieldname: 'due_on', fieldtype: 'Date'),
              ],
            ),
            initialData: const {'subject': 's', 'due_on': ''},
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final saved = await h.save(tester);
        expect(saved['subject'], 's');
      },
      skip: true, // BUG SDK-25
      // a Date value of "" (the SDK's own submit fills "" for empty
      // non-Check fields) reaches FormBuilder.initialValue, and
      // FormBuilderDateTimePicker casts it `as DateTime?` -> TypeError, the
      // form fails to build
    );
  });
}
