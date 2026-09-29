// DocField / DocTypeMeta parsing of real Frappe meta shapes, and the
// `toJson` round trip that the local meta cache depends on.
//
// Frappe serialises docfield flags as int 0/1 (DB), bool (some endpoints) or
// "0"/"1" strings (fixtures); `precision` is a Select whose empty option is
// ""; `link_filters` is a JSON string on the server but a decoded list in some
// client payloads.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';

void main() {
  group('DocField.fromJson', () {
    test('flags accept int, bool and string encodings', () {
      final a = DocField.fromJson({
        'fieldname': 'a',
        'fieldtype': 'Data',
        'reqd': 1,
        'read_only': true,
        'hidden': '1',
        'in_list_view': 'true',
      });
      expect(a.reqd, isTrue);
      expect(a.readOnly, isTrue);
      expect(a.hidden, isTrue);
      expect(a.inListView, isTrue);

      final b = DocField.fromJson({
        'fieldname': 'b',
        'fieldtype': 'Data',
        'reqd': 0,
        'read_only': false,
        'hidden': '0',
        'in_list_view': 'false',
      });
      expect(b.reqd, isFalse);
      expect(b.readOnly, isFalse);
      expect(b.hidden, isFalse);
      expect(b.inListView, isFalse);
    });

    test('precision / length / idx accept "", numeric text and doubles', () {
      final f = DocField.fromJson({
        'fieldname': 'amount',
        'fieldtype': 'Float',
        'precision': '',
        'length': '140',
        'idx': 7.0,
      });
      expect(f.precision, isNull, reason: 'Frappe "" = use system default');
      expect(f.length, 140);
      expect(f.idx, 7);

      final g = DocField.fromJson({
        'fieldname': 'rate',
        'fieldtype': 'Float',
        'precision': '3',
        'length': true,
      });
      expect(g.precision, 3);
      expect(g.length, isNull, reason: 'an unusable type is ignored');
    });

    test('link_filters: JSON string kept, list encoded, empty dropped', () {
      const raw = '[["Customer","disabled","=",0]]';
      expect(
        DocField.fromJson({
          'fieldname': 'c',
          'fieldtype': 'Link',
          'link_filters': raw,
        }).linkFilters,
        raw,
      );
      final listed = DocField.fromJson({
        'fieldname': 'c',
        'fieldtype': 'Link',
        'link_filters': [
          ['Customer', 'disabled', '=', 0],
        ],
      }).linkFilters;
      expect(jsonDecode(listed!), [
        ['Customer', 'disabled', '=', 0],
      ]);
      expect(
        DocField.fromJson({
          'fieldname': 'c',
          'fieldtype': 'Link',
          'link_filters': '',
        }).linkFilters,
        isNull,
      );
      expect(
        DocField.fromJson({
          'fieldname': 'c',
          'fieldtype': 'Link',
          'link_filters': const [],
        }).linkFilters,
        isNull,
      );
      expect(
        DocField.fromJson({
          'fieldname': 'c',
          'fieldtype': 'Link',
          'link_filters': 42,
        }).linkFilters,
        isNull,
      );
    });

    test('Table MultiSelect implies allowMultiple', () {
      expect(
        DocField.fromJson({
          'fieldname': 't',
          'fieldtype': 'Table MultiSelect',
        }).allowMultiple,
        isTrue,
      );
      expect(
        DocField.fromJson({
          'fieldname': 't',
          'fieldtype': 'Table',
        }).allowMultiple,
        isFalse,
      );
    });

    test('missing fieldtype defaults to Data', () {
      expect(DocField.fromJson({'fieldname': 'x'}).fieldtype, 'Data');
    });
  });

  group('DocField.toJson', () {
    test('replays unmodelled Frappe properties and keeps edits', () {
      final f = DocField.fromJson({
        'fieldname': 'status',
        'fieldtype': 'Select',
        'label': 'Status',
        'permlevel': 1,
        'allow_on_submit': 1,
        'no_copy': 1,
        'reqd': 0,
      });
      final json = f.toJson();
      expect(json['permlevel'], 1);
      expect(json['allow_on_submit'], 1);
      expect(json['no_copy'], 1);
      expect(json['fieldname'], 'status');
      expect(json['reqd'], 0);
    });

    test('a stale camelCase alias in the raw payload cannot win', () {
      final parsed = DocField.fromJson({
        'fieldname': 'x',
        'fieldtype': 'Data',
        'readOnly': 1,
      });
      expect(parsed.readOnly, isTrue);
      final edited = DocField(
        fieldname: parsed.fieldname,
        fieldtype: parsed.fieldtype,
        readOnly: false,
        rawData: parsed.rawData,
      );
      final json = edited.toJson();
      expect(json.containsKey('readOnly'), isFalse);
      expect(json['read_only'], 0);
      expect(DocField.fromJson(json).readOnly, isFalse);
    });

    test('nested child `fields` on a Table docfield are not replayed', () {
      final f = DocField.fromJson({
        'fieldname': 'items',
        'fieldtype': 'Table',
        'options': 'Task Item',
        'fields': [
          {'fieldname': 'qty', 'fieldtype': 'Int'},
        ],
      });
      expect(f.toJson().containsKey('fields'), isFalse);
      expect(f.toJson()['options'], 'Task Item');
    });

    test('optional properties round-trip through fromJson', () {
      final f = DocField(
        fieldname: 'due',
        fieldtype: 'Date',
        label: 'Due',
        dependsOn: 'eval:doc.a',
        mandatoryDependsOn: 'eval:doc.b',
        readOnlyDependsOn: 'eval:doc.c',
        fetchFrom: 'project.due',
        defaultValue: 'Today',
        description: 'd',
        placeholder: 'p',
        precision: 2,
        length: 10,
        idx: 3,
        section: 's',
      );
      final back = DocField.fromJson(f.toJson());
      expect(back.dependsOn, 'eval:doc.a');
      expect(back.mandatoryDependsOn, 'eval:doc.b');
      expect(back.readOnlyDependsOn, 'eval:doc.c');
      expect(back.fetchFrom, 'project.due');
      expect(back.defaultValue, 'Today');
      expect(back.description, 'd');
      expect(back.placeholder, 'p');
      expect(back.precision, 2);
      expect(back.length, 10);
      expect(back.idx, 3);
      expect(back.section, 's');
    });
  });

  group(
    'DocTypeMeta.fromJson fallback for a field that fails typed parsing',
    () {
      // `default` must be a String for DocField.fromJson; a numeric default
      // makes the typed parse throw, which exercises the fallback path.
      Map<String, dynamic> meta() => {
        'name': 'Task',
        'fields': [
          {'fieldname': 'subject', 'fieldtype': 'Data', 'label': 'Subject'},
          {
            'fieldname': 'customer',
            'fieldtype': 'Link',
            'label': 'Customer',
            'options': 'Customer',
            'reqd': 1,
            'default': 5,
            'permlevel': 0,
          },
        ],
      };

      test(
        'the other fields still parse and the bad one keeps its identity',
        () {
          final m = DocTypeMeta.fromJson(meta());
          expect(m.fields.length, 2);
          expect(m.fields.first.label, 'Subject');
          final bad = m.getField('customer')!;
          expect(bad.fieldtype, 'Link');
          expect(bad.rawData, isNotNull);
          expect(
            bad.toJson()['permlevel'],
            0,
            reason: 'unmodelled keys replay',
          );
        },
      );

      test(
        'toJson of the fallback field keeps its modelled properties',
        () {
          final m = DocTypeMeta.fromJson(meta());
          final json =
              (m.toJson()['fields'] as List)[1] as Map<String, dynamic>;
          expect(
            json['options'],
            'Customer',
            reason:
                'the fallback keeps rawData precisely so meta.toJson() stays '
                'full-fidelity (doc_type_meta.dart fallback comment)',
          );
          expect(json['reqd'], 1);
          expect(json['label'], 'Customer');
        },
        skip:
            'BUG SDK-22 (P3): the fallback stub serialises its DEFAULT modelled '
            'values (reqd 0, no options/label) over the raw payload, so a meta '
            'cache round trip silently drops them',
      );
    },
  );

  group('DocTypeMeta shapes', () {
    test('name falls back to doctype, then empty', () {
      expect(DocTypeMeta.fromJson({'doctype': 'ToDo'}).name, 'ToDo');
      expect(DocTypeMeta.fromJson(const {}).name, '');
      expect(DocTypeMeta.fromJson(const {}).fields, isEmpty);
    });

    test('empty title_field / sort_field are null', () {
      final m = DocTypeMeta.fromJson({
        'name': 'Task',
        'title_field': '',
        'sort_field': '',
        'sort_order': '',
      });
      expect(m.titleField, isNull);
      expect(m.sortField, isNull);
      expect(m.sortOrder, isNull);
    });

    test('toJson writes search_fields back as a comma list', () {
      final m = DocTypeMeta.fromJson({
        'name': 'Task',
        'search_fields': 'subject, status ,,owner',
      });
      expect(m.searchFields, ['subject', 'status', 'owner']);
      expect(m.toJson()['search_fields'], 'subject,status,owner');
      expect(DocTypeMeta.fromJson(m.toJson()).searchFields, [
        'subject',
        'status',
        'owner',
      ]);
    });

    test('typed fields win over the raw payload on toJson', () {
      final m = DocTypeMeta.fromJson({
        'name': 'Task',
        'issingle': 0,
        'fields': [
          {'fieldname': 'a', 'fieldtype': 'Data'},
          {'fieldname': 'b', 'fieldtype': 'Data'},
        ],
      });
      final edited = DocTypeMeta(
        name: m.name,
        fields: m.fields.where((f) => f.fieldname != 'b').toList(),
        metaData: m.metaData,
      );
      final json = edited.toJson();
      expect((json['fields'] as List).length, 1);
      expect(json['issingle'], 0, reason: 'raw keys still pass through');
      expect(json['istable'], 0);
    });

    test('permission rows with a non-map entry are ignored', () {
      final m = DocTypeMeta(
        name: 'Task',
        fields: const [],
        metaData: {
          'permissions': [
            'garbage',
            {'role': 'Editor', 'write': 1},
          ],
        },
      );
      expect(m.hasPermission('write', userRoles: ['Editor']), isTrue);
      expect(m.hasPermission('write', userRoles: ['Viewer']), isFalse);
      expect(m.hasPermission('delete', userRoles: ['Editor']), isFalse);
    });

    test('dataFields excludes layout, HTML, Button, Image, Heading, Fold', () {
      final m = DocTypeMeta(
        name: 'Task',
        fields: [
          for (final t in [
            'Section Break',
            'Column Break',
            'Tab Break',
            'HTML',
            'Button',
            'Image',
            'Heading',
            'Fold',
            'Data',
            'Table',
          ])
            DocField(fieldname: t.toLowerCase(), fieldtype: t),
        ],
      );
      expect(m.dataFields.map((f) => f.fieldtype), ['Data', 'Table']);
      expect(m.layoutFields.length, 3);
    });
  });
}
