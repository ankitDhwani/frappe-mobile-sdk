// FormController (reactive engine) against the Frappe document contract:
// new-document defaults, mandatory semantics, async validation, dirty
// tracking, unknown-field robustness and focus lifecycle.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

FormController _c(List<DocField> fields, {Map<String, dynamic>? data}) =>
    FormController(
      meta: DocTypeMeta(name: 'Task', fields: fields),
      initialData: data,
    );

void main() {
  group('new-document defaults (frappe/model/create_new.py)', () {
    test(
      'a Select without a default starts on its FIRST option',
      () {
        // BUG SDK2-17 (P2, parity): form_controller.dart `_seedDefaults`
        // (:174) seeds `f.defaultValue` (null) for a Select. Frappe gives a new
        // document's Select its first option when no default is set —
        // server: frappe/model/create_new.py:117-118
        // (`return df.options.split("\n", 1)[0]`), desk:
        // public/js/frappe/model/create_new.js:107-113. So on a new Task,
        // `eval:doc.status=='Open'` is TRUE on desk and FALSE on mobile: the
        // dependent field is hidden and stripped from the payload.
        final c = _c([
          DocField(
            fieldname: 'status',
            fieldtype: 'Select',
            options: 'Open\nClosed',
          ),
          DocField(
            fieldname: 'open_note',
            fieldtype: 'Data',
            dependsOn: "eval:doc.status=='Open'",
          ),
        ]);
        addTearDown(c.dispose);
        expect(c.getValue('status'), 'Open');
        expect(c.uiStateOf('open_note').value.visible, isTrue);
      },
      skip: 'BUG SDK2-17: Select without default not seeded with option 1',
    );

    test('a Select whose first option is blank starts empty', () {
      final c = _c([
        DocField(
          fieldname: 'status',
          fieldtype: 'Select',
          options: '\nOpen\nClosed',
        ),
      ]);
      addTearDown(c.dispose);
      final v = c.getValue('status');
      expect(v == null || v == '', isTrue);
    });

    test('an explicit default wins over the first option', () {
      final c = _c([
        DocField(
          fieldname: 'status',
          fieldtype: 'Select',
          options: 'Open\nClosed',
          defaultValue: 'Closed',
        ),
      ]);
      addTearDown(c.dispose);
      expect(c.getValue('status'), 'Closed');
    });

    test('a new document is draft and local; a named one is not local', () {
      final fresh = _c([DocField(fieldname: 'a', fieldtype: 'Data')]);
      addTearDown(fresh.dispose);
      expect(fresh.getValue('docstatus'), 0);
      expect(fresh.getValue('__islocal'), 1);

      final saved = _c(
        [DocField(fieldname: 'a', fieldtype: 'Data')],
        data: {'name': 'TASK-0001', 'docstatus': 1},
      );
      addTearDown(saved.dispose);
      expect(saved.getValue('docstatus'), 1);
      expect(saved.getValue('__islocal'), isNull);
    });
  });

  group('mandatory semantics', () {
    test('0 and false are present values; blank strings are missing', () {
      final c = _c(
        [
          DocField(
            fieldname: 'qty',
            fieldtype: 'Int',
            label: 'Qty',
            reqd: true,
          ),
          DocField(
            fieldname: 'ok',
            fieldtype: 'Check',
            label: 'OK',
            reqd: true,
          ),
          DocField(
            fieldname: 'subject',
            fieldtype: 'Data',
            label: 'Subject',
            reqd: true,
          ),
        ],
        data: {'qty': 0, 'ok': false, 'subject': '   '},
      );
      addTearDown(c.dispose);
      expect(c.validate(), isFalse);
      expect(c.invalidFields.keys, ['subject']);
      expect(c.invalidFields['subject'], 'Subject is required');
      expect(c.firstInvalidField, 'subject');
    });

    test('an empty table is missing', () {
      final c = _c(
        [
          DocField(
            fieldname: 'items',
            fieldtype: 'Table',
            label: 'Items',
            reqd: true,
          ),
        ],
        data: {'items': <Map<String, dynamic>>[]},
      );
      addTearDown(c.dispose);
      expect(c.validate(), isFalse);
      c.setValue('items', [
        {'item_code': 'A'},
      ]);
      expect(c.validate(), isTrue);
    });

    test('a hidden field is never validated', () {
      final c = _c([
        DocField(fieldname: 'kind', fieldtype: 'Data'),
        DocField(
          fieldname: 'detail',
          fieldtype: 'Data',
          label: 'Detail',
          reqd: true,
          dependsOn: "eval:doc.kind=='x'",
        ),
      ]);
      addTearDown(c.dispose);
      expect(c.validate(), isTrue);
      c.setValue('kind', 'x');
      expect(c.validate(), isFalse);
      expect(c.validateField('detail'), isFalse);
    });

    test('mandatory_depends_on makes a field required at runtime', () {
      final c = _c([
        DocField(fieldname: 'kind', fieldtype: 'Data'),
        DocField(
          fieldname: 'reason',
          fieldtype: 'Data',
          label: 'Reason',
          mandatoryDependsOn: "eval:doc.kind=='other'",
        ),
      ]);
      addTearDown(c.dispose);
      expect(c.uiStateOf('reason').value.required, isFalse);
      c.setValue('kind', 'other');
      expect(c.uiStateOf('reason').value.required, isTrue);
      expect(c.validate(), isFalse);
      expect(c.invalidFields['reason'], 'Reason is required');
    });

    test(
      'the required message uses the display label for a blank label',
      () {
        // BUG SDK2-18 (P3): form_controller.dart:579 builds the message from
        // `f.label ?? field`, so a blank / zero-width label (which hosts use
        // to suppress duplicate headings — doc_field.dart displayLabel docs)
        // yields " is required" / "​ is required". The legacy engine
        // uses `field.displayLabel` (field_helpers.dart requiredValidator),
        // and the comment above this code says the two must agree.
        final field = DocField(
          fieldname: 'site_code',
          fieldtype: 'Data',
          label: '​',
          reqd: true,
        );
        final c = _c([field]);
        addTearDown(c.dispose);
        expect(c.validate(), isFalse);
        expect(c.invalidFields['site_code'], 'Site Code is required');
      },
      skip: 'BUG SDK2-18: required message ignores displayLabel',
    );

    test('field and cross-field validators report in declaration order', () {
      final c = _c([
        DocField(fieldname: 'a', fieldtype: 'Data'),
        DocField(fieldname: 'b', fieldtype: 'Data'),
      ]);
      addTearDown(c.dispose);
      c.addFieldValidator('b', (v, _) => v == 'bad' ? 'b is bad' : null);
      c.addCrossFieldValidator(
        (d) => d['a'] == d['b'] && d['a'] != null
            ? {'a': 'a must differ from b'}
            : null,
      );
      c.setValue('b', 'bad');
      expect(c.validate(), isFalse);
      expect(c.firstInvalidField, 'b');
      expect(c.errorListenableOf('b').value, 'b is bad');

      c.setValue('b', 'same');
      c.setValue('a', 'same');
      expect(c.validate(), isFalse);
      expect(c.invalidFields, {'a': 'a must differ from b'});
      expect(c.isValid.value, isFalse);
    });
  });

  group('async validation', () {
    test('an async rejection fails the form', () async {
      final c = _c([DocField(fieldname: 'code', fieldtype: 'Data')]);
      addTearDown(c.dispose);
      c.addAsyncFieldValidator('code', (v, _) async => 'already used');
      c.setValue('code', 'A1');
      expect(await c.validateAsync(), isFalse);
      expect(c.errorListenableOf('code').value, 'already used');
    });

    test(
      'a value edited while its async check runs is not reported valid',
      () async {
        // BUG SDK2-19 (P2): validateAsync (form_controller.dart:621-645;
        // stale `break` :632, `ok` kept at :643)
        // discards a result whose value changed mid-await (`break` on stale)
        // but leaves `ok` true, so the call returns VALID for a value that
        // was never checked. A duplicate/server check can be bypassed by
        // editing during the round-trip, then saving.
        final gate = Completer<void>();
        final checked = <Object?>[];
        final c = _c([DocField(fieldname: 'code', fieldtype: 'Data')]);
        addTearDown(c.dispose);
        c.addAsyncFieldValidator('code', (v, _) async {
          checked.add(v);
          await gate.future;
          return 'already used'; // every value is taken
        });
        c.setValue('code', 'A1');
        final result = c.validateAsync();
        c.setValue('code', 'A2'); // user edits during the round-trip
        gate.complete();
        final ok = await result;
        // Either the new value was checked too, or the form is not valid.
        expect(ok == false || checked.contains('A2'), isTrue);
      },
      skip: 'BUG SDK2-19: stale async validation reports the form valid',
    );
  });

  group('dirty tracking', () {
    test('1 -> 2 -> 1 is not dirty; markPristine rebaselines', () {
      final c = _c(
        [DocField(fieldname: 'n', fieldtype: 'Int')],
        data: {'n': 1},
      );
      addTearDown(c.dispose);
      c.setValue('n', 2);
      expect(c.isDirty.value, isTrue);
      c.setValue('n', 1);
      expect(c.isDirty.value, isFalse);
      c.setValue('n', 5);
      c.markPristine();
      expect(c.isDirty.value, isFalse);
    });

    test('companion __is_local keys never make a form dirty', () {
      final c = _c([
        DocField(fieldname: 'customer', fieldtype: 'Link', options: 'Customer'),
      ]);
      addTearDown(c.dispose);
      c.setValue('customer__is_local', 1);
      expect(c.isDirty.value, isFalse);
    });

    test(
      'an equal table value (new list, same rows) is not a change',
      () {
        // BUG SDK2-20 (P3): `_applyValue` (:251) and `_recomputeDirty` (:408)
        // compare with
        // `==`, which is identity for List/Map. Re-emitting a child table
        // with identical rows (every child-table widget rebuild does) marks
        // the form dirty — "unsaved changes" with nothing changed.
        final c = _c(
          [DocField(fieldname: 'items', fieldtype: 'Table', options: 'Item')],
          data: {
            'items': [
              {'item_code': 'A', 'qty': 1},
            ],
          },
        );
        addTearDown(c.dispose);
        c.setValue('items', [
          {'item_code': 'A', 'qty': 1},
        ]);
        expect(c.isDirty.value, isFalse);
      },
      skip: 'BUG SDK2-20: equal child-table value marks the form dirty',
    );
  });

  group('robustness for fields not in the meta', () {
    test('unknown fields are editable, valid and in tab 0', () {
      final c = _c([DocField(fieldname: 'a', fieldtype: 'Data')]);
      addTearDown(c.dispose);
      expect(c.uiStateOf('ghost').value.visible, isTrue);
      expect(c.uiStateOf('ghost').value.readOnly, isFalse);
      expect(c.validateField('ghost'), isTrue);
      expect(c.tabIndexOf('ghost'), 0);
      c.setValue('ghost', 'x');
      expect(c.getValue('ghost'), 'x');
      // A value for an unknown field still counts as a change.
      expect(c.isDirty.value, isTrue);
    });

    test('an unknown fetch source is ignored', () {
      final c = _c([
        DocField(fieldname: 'customer', fieldtype: 'Link', options: 'Customer'),
        DocField(
          fieldname: 'customer_name',
          fieldtype: 'Data',
          fetchFrom: 'customer.customer_name',
        ),
      ]);
      addTearDown(c.dispose);
      var fetches = 0;
      c.fetchLinkedDocument = (dt, name) async {
        fetches++;
        return {'customer_name': 'Acme'};
      };
      c.setValue('ghost', 'x');
      expect(fetches, 0);
    });
  });

  group('field lifecycle', () {
    test(
      'mounted / unmounted are reported, and are safe after dispose',
      () async {
        final c = _c([DocField(fieldname: 'a', fieldtype: 'Data')]);
        final events = <String>[];
        final sub = c.fieldLifecycle.listen(
          (e) => events.add('${e.field}:${e.kind.name}'),
        );
        c.reportFieldMounted('a');
        c.reportFieldUnmounted('a');
        await Future<void>.delayed(Duration.zero);
        expect(events, ['a:mounted', 'a:unmounted']);
        // One FocusNode per field, reused.
        expect(identical(c.focusNodeOf('a'), c.focusNodeOf('a')), isTrue);
        await sub.cancel();
        c.dispose();
        // Field hosts may report unmount during their own teardown.
        c.reportFieldUnmounted('a');
      },
    );
  });
}
