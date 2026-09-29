// ChildTableField add / edit / view / remove sheets and their failure paths,
// with a minimal host form builder that registers a submit returning a fixed
// row payload.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/child_table_field.dart';

final _field = DocField(
  fieldname: 'items',
  fieldtype: 'Table',
  label: 'Task Items',
  options: 'Task Item',
);

final _childMeta = DocTypeMeta(
  name: 'Task Item',
  fields: [
    DocField(
      fieldname: 'item_code',
      fieldtype: 'Data',
      label: 'Item',
      inListView: true,
    ),
    DocField(
      fieldname: 'qty',
      fieldtype: 'Int',
      label: 'Qty',
      inListView: true,
    ),
  ],
);

/// A child "form" that immediately registers a submit which emits [payload].
class _AutoForm extends StatefulWidget {
  const _AutoForm({
    required this.payload,
    required this.onSubmit,
    this.registerSubmit,
    this.readOnly = false,
  });
  final Map<String, dynamic> payload;
  final void Function(Map<String, dynamic>) onSubmit;
  final void Function(void Function())? registerSubmit;
  final bool readOnly;

  @override
  State<_AutoForm> createState() => _AutoFormState();
}

class _AutoFormState extends State<_AutoForm> {
  @override
  void initState() {
    super.initState();
    widget.registerSubmit?.call(() => widget.onSubmit(widget.payload));
  }

  @override
  Widget build(BuildContext context) =>
      Text(widget.readOnly ? 'child form (read-only)' : 'child form');
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<dynamic> rows,
    ValueChanged<List<dynamic>>? onChanged,
    Map<String, dynamic> payload = const {'item_code': 'NEW', 'qty': 9},
    Future<DocTypeMeta> Function(String)? getMeta,
    DocField? field,
    bool enabled = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChildTableField(
              field: field ?? _field,
              value: rows,
              enabled: enabled,
              onChanged: onChanged,
              getMeta: getMeta ?? (_) async => _childMeta,
              formBuilder:
                  (meta, data, onSubmit, {registerSubmit, readOnly = false}) =>
                      _AutoForm(
                        payload: payload,
                        onSubmit: onSubmit,
                        registerSubmit: registerSubmit,
                        readOnly: readOnly,
                      ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> openSheet(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  testWidgets('Add Row appends the submitted row stamped with its doctype', (
    tester,
  ) async {
    List<dynamic>? emitted;
    await pump(
      tester,
      rows: [
        {'item_code': 'A', 'qty': 1},
      ],
      onChanged: (v) => emitted = v,
    );
    await openSheet(tester, find.text('Add Row'));
    expect(find.text('child form'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(emitted, hasLength(2));
    expect(emitted!.last, {
      'item_code': 'NEW',
      'qty': 9,
      'doctype': 'Task Item',
    });
    expect(find.text('child form'), findsNothing);
  });

  testWidgets('editing keeps the row identity and replaces it in place', (
    tester,
  ) async {
    List<dynamic>? emitted;
    await pump(
      tester,
      rows: [
        {'item_code': 'A', 'qty': 1, 'name': 'row-1', 'mobile_uuid': 'u-1'},
        {'item_code': 'B', 'qty': 2},
      ],
      onChanged: (v) => emitted = v,
    );
    await openSheet(tester, find.byType(ListTile).first);
    expect(find.text('Edit Task Item'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(emitted, hasLength(2));
    final edited = emitted!.first as Map;
    expect(edited['item_code'], 'NEW');
    expect(edited['name'], 'row-1');
    expect(edited['mobile_uuid'], 'u-1');
    expect(edited['doctype'], 'Task Item');
    expect((emitted![1] as Map)['item_code'], 'B');
  });

  testWidgets('Remove in the edit sheet drops only that row', (tester) async {
    List<dynamic>? emitted;
    await pump(
      tester,
      rows: [
        {'item_code': 'A', 'qty': 1},
        {'item_code': 'B', 'qty': 2},
      ],
      onChanged: (v) => emitted = v,
    );
    await openSheet(tester, find.byType(ListTile).last);
    await tester.tap(find.text('Remove'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(emitted, [
      {'item_code': 'A', 'qty': 1},
    ]);
  });

  testWidgets('Cancel closes the sheet without emitting', (tester) async {
    var calls = 0;
    await pump(
      tester,
      rows: [
        {'item_code': 'A', 'qty': 1},
      ],
      onChanged: (_) => calls++,
    );
    await openSheet(tester, find.byType(ListTile).first);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, 0);
    expect(find.text('child form'), findsNothing);
  });

  testWidgets('the close (X) icon dismisses the sheet', (tester) async {
    await pump(
      tester,
      rows: [
        {'item_code': 'A', 'qty': 1},
      ],
      onChanged: (_) {},
    );
    await openSheet(tester, find.byType(ListTile).first);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('child form'), findsNothing);
  });

  testWidgets('a read-only table opens rows for viewing only', (tester) async {
    await pump(
      tester,
      rows: [
        {'item_code': 'A', 'qty': 1},
      ],
      enabled: false,
      onChanged: (_) {},
    );
    expect(find.byIcon(Icons.delete), findsNothing);
    await openSheet(tester, find.byType(ListTile).first);
    expect(find.text('View Task Item'), findsOneWidget);
    expect(find.text('child form (read-only)'), findsOneWidget);
    expect(find.text('Remove'), findsNothing);
    expect(find.text('Save'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('View Task Item'), findsNothing);
  });

  testWidgets('the row delete icon removes the row directly', (tester) async {
    List<dynamic>? emitted;
    await pump(
      tester,
      rows: [
        {'item_code': 'A', 'qty': 1},
        {'item_code': 'B', 'qty': 2},
      ],
      onChanged: (v) => emitted = v,
    );
    await tester.tap(find.byIcon(Icons.delete).first);
    await tester.pump();
    expect(emitted, [
      {'item_code': 'B', 'qty': 2},
    ]);
  });

  testWidgets('a child meta that cannot load explains on Add', (tester) async {
    var calls = 0;
    await pump(
      tester,
      rows: const [],
      onChanged: (_) => calls++,
      getMeta: (_) async => throw StateError('meta missing'),
    );
    await tester.tap(find.text('Add Row'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Error loading form:'), findsOneWidget);
    expect(find.text('child form'), findsNothing);
    expect(calls, 0);
  });

  testWidgets('a child meta that cannot load explains on edit', (tester) async {
    await pump(
      tester,
      rows: [
        {'item_code': 'A', 'qty': 1},
      ],
      onChanged: (_) {},
      getMeta: (_) async => throw StateError('meta missing'),
    );
    await tester.tap(find.byType(ListTile).first);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Error loading form:'), findsWidgets);
  });

  testWidgets('a non-map row renders as an empty card rather than crashing', (
    tester,
  ) async {
    await pump(tester, rows: ['not a row'], onChanged: (_) {});
    expect(find.byType(Card), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
