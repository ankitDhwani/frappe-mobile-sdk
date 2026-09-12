import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/child_table_cells.dart';

DocTypeMeta _meta() => DocTypeMeta.fromJson({
      'name': 'TestChildDoc',
      'fields': [
        {'fieldname': 'size', 'fieldtype': 'Data', 'label': 'Size',
         'in_list_view': 1},
        {'fieldname': 'source', 'fieldtype': 'Link', 'label': 'Source',
         'options': 'TestSource', 'in_list_view': 1},
        {'fieldname': 'notes', 'fieldtype': 'Data', 'label': 'Notes'},
        {'fieldname': 'nested', 'fieldtype': 'Table', 'label': 'Nested',
         'options': 'Other', 'in_list_view': 1},
      ],
    });

void main() {
  test('childListViewFields keeps declared columns and drops Table types', () {
    final names = childListViewFields(_meta()).map((f) => f.fieldname).toList();
    expect(names, ['size', 'source']);
  });

  test('isChildSystemKey excludes bookkeeping and companion columns', () {
    expect(isChildSystemKey('mobile_uuid'), isTrue);
    expect(isChildSystemKey('sync_status'), isTrue);
    expect(isChildSystemKey('source__display'), isTrue);
    expect(isChildSystemKey('size'), isFalse);
  });

  test('resolveChildListViewCells resolves a Link to its title', () async {
    final cells = await resolveChildListViewCells(
      const {'size': '500g', 'source': 'SRC-001'},
      _meta(),
      childListViewFields(_meta()),
      (doctype, name) async => doctype == 'TestSource' ? 'Bank Loan' : null,
    );
    expect(cells.map((e) => '${e.key}=${e.value}').toList(),
        ['Size=500g', 'Source=Bank Loan']);
  });

  test('a declared but empty column renders an em dash', () async {
    final cells = await resolveChildListViewCells(
      const {'size': '500g'},
      _meta(),
      childListViewFields(_meta()),
      (_, __) async => null,
    );
    expect(cells.length, 2);
    expect(cells.last.value, '—');
  });

  test('an unresolvable Link falls back to the raw id', () async {
    final cells = await resolveChildListViewCells(
      const {'size': '', 'source': 'SRC-404'},
      _meta(),
      childListViewFields(_meta()),
      (_, __) async => null,
    );
    expect(cells.last.value, 'SRC-404');
  });

  test('resolveChildRowTitle prefers the declared title_field', () async {
    final meta = DocTypeMeta.fromJson({
      'name': 'TestChildDoc',
      'title_field': 'label_field',
      'fields': [
        {'fieldname': 'other', 'fieldtype': 'Data', 'label': 'Other'},
        {'fieldname': 'label_field', 'fieldtype': 'Data', 'label': 'Label'},
      ],
    });
    final t = await resolveChildRowTitle(
        const {'other': 'x', 'label_field': 'Chosen'}, meta, 0, null);
    expect(t, 'Chosen');
  });

  test('resolveChildRowTitle falls back to field order, then Row #N', () async {
    final meta = DocTypeMeta.fromJson({
      'name': 'TestChildDoc',
      'fields': [
        {'fieldname': 'first', 'fieldtype': 'Data', 'label': 'First'},
      ],
    });
    expect(await resolveChildRowTitle(const {'first': 'A'}, meta, 0, null),
        'First: A');
    expect(await resolveChildRowTitle(const {}, meta, 2, null), 'Row #3');
  });
}
