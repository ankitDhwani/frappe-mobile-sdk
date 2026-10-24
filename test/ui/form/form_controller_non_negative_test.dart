import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

/// Reactive mode (`FormBuilderMode.reactive`) counterpart of
/// `test/ui/widgets/form_builder_non_negative_test.dart`.
///
/// Frappe rejects a negative value in a `non_negative` Int / Float / Currency /
/// Percent field on save (`Document._validate_non_negative`). Reactive submit
/// only consults [FormController.validateAsync], never the field widgets'
/// validators, so the controller has to apply the rule itself or a negative
/// value saves locally and is rejected at sync time.
void main() {
  const negativeMsg = 'Value cannot be negative for Height';

  DocTypeMeta singleFieldMeta({
    String fieldtype = 'Float',
    bool nonNegative = true,
    bool reqd = false,
    String? dependsOn,
  }) => DocTypeMeta(
    name: 'Test',
    label: 'Test',
    isTable: false,
    fields: [
      DocField(fieldname: 'show', fieldtype: 'Check', idx: 1, label: 'Show'),
      DocField(
        fieldname: 'height',
        fieldtype: fieldtype,
        idx: 2,
        label: 'Height',
        nonNegative: nonNegative,
        reqd: reqd,
        dependsOn: dependsOn,
      ),
    ],
  );

  group('FormController non_negative', () {
    for (final fieldtype in const ['Int', 'Float', 'Currency', 'Percent']) {
      test('$fieldtype: a negative value fails validate() on that field', () {
        final c = FormController(
          meta: singleFieldMeta(fieldtype: fieldtype),
          initialData: const {'height': -3},
        );
        addTearDown(c.dispose);

        expect(c.validate(), isFalse);
        expect(c.errorOf('height'), negativeMsg);
        expect(c.firstInvalidField, 'height');
        expect(c.invalidFields, {'height': negativeMsg});
      });
    }

    for (final raw in const ['-0.5', '-1,000']) {
      test('a negative number stored as text ("$raw") fails too', () {
        final c = FormController(
          meta: singleFieldMeta(),
          initialData: {'height': raw},
        );
        addTearDown(c.dispose);

        expect(c.validate(), isFalse);
        expect(c.errorOf('height'), negativeMsg);
      });
    }

    for (final ok in <Object?>[0, 0.0, 2.5, '7', '', null]) {
      test('passes with height = ${ok is String ? '"$ok"' : ok}', () {
        final c = FormController(
          meta: singleFieldMeta(),
          initialData: {'height': ok},
        );
        addTearDown(c.dispose);

        expect(c.validate(), isTrue);
        expect(c.errorOf('height'), isNull);
      });
    }

    test('a field without the flag accepts a negative value', () {
      final c = FormController(
        meta: singleFieldMeta(nonNegative: false),
        initialData: const {'height': -3},
      );
      addTearDown(c.dispose);

      expect(c.validate(), isTrue);
      expect(c.errorOf('height'), isNull);
    });

    test('the flag is ignored on non-numeric fieldtypes, as in Frappe', () {
      final c = FormController(
        meta: singleFieldMeta(fieldtype: 'Data'),
        initialData: const {'height': '-3'},
      );
      addTearDown(c.dispose);

      expect(c.validate(), isTrue);
    });

    test('a field hidden by its depends_on is not validated', () {
      final c = FormController(
        meta: singleFieldMeta(dependsOn: 'eval:doc.show == 1'),
        initialData: const {'show': 0, 'height': -3},
      );
      addTearDown(c.dispose);

      expect(c.validate(), isTrue);
      expect(c.errorOf('height'), isNull);

      // Shown again: the rule applies.
      c.setValue('show', 1);
      expect(c.validate(), isFalse);
      expect(c.errorOf('height'), negativeMsg);
    });

    test('validateField reports it and clears it once corrected', () {
      final c = FormController(meta: singleFieldMeta());
      addTearDown(c.dispose);

      c.setValue('height', -1);
      expect(c.validateField('height'), isFalse);
      expect(c.errorListenableOf('height').value, negativeMsg);
      expect(c.isValid.value, isFalse);

      c.setValue('height', 1);
      expect(c.validateField('height'), isTrue);
      expect(c.errorListenableOf('height').value, isNull);
      expect(c.isValid.value, isTrue);
    });

    test('validateAsync fails on a negative value', () async {
      final c = FormController(
        meta: singleFieldMeta(),
        initialData: const {'height': -3},
      );
      addTearDown(c.dispose);

      expect(await c.validateAsync(), isFalse);
      expect(c.errorOf('height'), negativeMsg);
    });

    test('reqd + non_negative: empty is "required", negative is negative', () {
      final c = FormController(meta: singleFieldMeta(reqd: true));
      addTearDown(c.dispose);

      expect(c.validate(), isFalse);
      expect(c.errorOf('height'), 'Height is required');

      c.setValue('height', -2);
      expect(c.validate(), isFalse);
      expect(c.errorOf('height'), negativeMsg);

      c.setValue('height', 0);
      expect(c.validate(), isTrue);
    });
  });

  group('reactive FrappeFormBuilder submit', () {
    DocTypeMeta twoTabMeta({bool nonNegative = true}) => DocTypeMeta(
      name: 'Test',
      label: 'Test',
      isTable: false,
      fields: [
        DocField(
          fieldname: 'tab_basic',
          fieldtype: 'Tab Break',
          idx: 1,
          label: 'Basic',
        ),
        DocField(fieldname: 'note', fieldtype: 'Data', idx: 2, label: 'Note'),
        DocField(
          fieldname: 'tab_size',
          fieldtype: 'Tab Break',
          idx: 3,
          label: 'Size',
        ),
        DocField(
          fieldname: 'height',
          fieldtype: 'Float',
          idx: 4,
          label: 'Height',
          nonNegative: nonNegative,
        ),
      ],
    );

    Future<
      ({
        void Function() submit,
        List<Map<String, dynamic>> submitted,
        List<int> failed,
        FormController controller,
      })
    >
    pumpReactiveForm(
      WidgetTester tester,
      DocTypeMeta meta, {
      Map<String, dynamic> initialData = const {},
    }) async {
      void Function()? captured;
      final submitted = <Map<String, dynamic>>[];
      final failed = <int>[];
      final controller = FormController(meta: meta, initialData: initialData);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: meta,
              mode: FormBuilderMode.reactive,
              controller: controller,
              initialData: initialData,
              useLinkFieldCoordinator: false,
              onSubmit: submitted.add,
              onValidationFailed: () => failed.add(1),
              registerSubmit: (cb) => captured = cb,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (
        submit: captured!,
        submitted: submitted,
        failed: failed,
        controller: controller,
      );
    }

    testWidgets('a negative value on an unopened tab blocks submit', (
      tester,
    ) async {
      final form = await pumpReactiveForm(
        tester,
        twoTabMeta(),
        initialData: const {'height': -3},
      );

      form.submit();
      await tester.pumpAndSettle();

      expect(form.submitted, isEmpty);
      expect(form.failed, hasLength(1));
      expect(form.controller.errorOf('height'), negativeMsg);
      expect(form.controller.firstInvalidField, 'height');
    });

    for (final ok in <Object?>[0, 2.5]) {
      testWidgets('submits with height = $ok', (tester) async {
        final form = await pumpReactiveForm(
          tester,
          twoTabMeta(),
          initialData: {'height': ok},
        );

        form.submit();
        await tester.pumpAndSettle();

        expect(form.failed, isEmpty);
        expect(form.submitted, hasLength(1));
      });
    }

    testWidgets('a field without the flag still submits a negative value', (
      tester,
    ) async {
      final form = await pumpReactiveForm(
        tester,
        twoTabMeta(nonNegative: false),
        initialData: const {'height': -3},
      );

      form.submit();
      await tester.pumpAndSettle();

      expect(form.failed, isEmpty);
      expect(form.submitted.single['height'], -3);
    });
  });
}
