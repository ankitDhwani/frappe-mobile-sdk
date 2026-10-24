import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

/// Frappe rejects a negative value in a `non_negative` Int / Float / Currency /
/// Percent field when the document is saved (`Document._validate_non_negative`).
/// An offline save would only hit that at sync time, so submit has to apply the
/// same rule over the COMPLETE payload — including fields on tabs that were
/// never opened, which `saveAndValidate()` cannot see.
void main() {
  DocTypeMeta twoTabMeta({
    bool nonNegative = true,
    String fieldtype = 'Float',
  }) => DocTypeMeta(
    name: 'Test',
    label: 'Test',
    isTable: false,
    titleField: null,
    searchFields: null,
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
        fieldtype: fieldtype,
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
    })
  >
  pumpForm(
    WidgetTester tester,
    DocTypeMeta meta, {
    Map<String, dynamic> initialData = const {},
  }) async {
    void Function()? captured;
    final submitted = <Map<String, dynamic>>[];
    final failed = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
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
    return (submit: captured!, submitted: submitted, failed: failed);
  }

  Future<void> submitAndSettle(void Function() submit, WidgetTester t) async {
    submit();
    // Step frames like a device does: the tab switch mounts the target page
    // before the delayed inline-error invalidation runs. A single
    // pumpAndSettle() can fire that timer before the page is built.
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    await t.pumpAndSettle();
  }

  const negativeMsg = 'Value cannot be negative for Height';

  testWidgets('blocks submit when a negative value sits on an unopened tab', (
    tester,
  ) async {
    final form = await pumpForm(
      tester,
      twoTabMeta(),
      initialData: const {'height': -3},
    );

    await submitAndSettle(form.submit, tester);

    expect(form.submitted, isEmpty);
    expect(form.failed, hasLength(1));
    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.controller!.index, 1, reason: 'jumps to the offending tab');
    expect(find.text(negativeMsg), findsOneWidget);
  });

  testWidgets('a negative number stored as text is caught too', (tester) async {
    final form = await pumpForm(
      tester,
      twoTabMeta(),
      initialData: const {'height': '-0.5'},
    );

    await submitAndSettle(form.submit, tester);

    expect(form.submitted, isEmpty);
    expect(form.failed, hasLength(1));
  });

  for (final ok in <Object?>[0, 2.5, '7', '', null]) {
    testWidgets('submits with height = ${ok is String ? '"$ok"' : ok}', (
      tester,
    ) async {
      final form = await pumpForm(
        tester,
        twoTabMeta(),
        initialData: {'height': ok},
      );

      await submitAndSettle(form.submit, tester);

      expect(form.failed, isEmpty);
      expect(form.submitted, hasLength(1));
    });
  }

  testWidgets('a field without the flag still saves a negative value', (
    tester,
  ) async {
    final form = await pumpForm(
      tester,
      twoTabMeta(nonNegative: false),
      initialData: const {'height': -3},
    );

    await submitAndSettle(form.submit, tester);

    expect(form.failed, isEmpty);
    expect(form.submitted.single['height'], -3);
  });

  testWidgets('the flag is ignored on non-numeric fieldtypes, as in Frappe', (
    tester,
  ) async {
    final form = await pumpForm(
      tester,
      twoTabMeta(fieldtype: 'Data'),
      initialData: const {'height': '-3'},
    );

    await submitAndSettle(form.submit, tester);

    expect(form.failed, isEmpty);
    expect(form.submitted, hasLength(1));
  });

  testWidgets('typing a negative into a visible flagged field shows the error '
      'and blocks submit', (tester) async {
    final meta = DocTypeMeta(
      name: 'Test',
      label: 'Test',
      isTable: false,
      titleField: null,
      searchFields: null,
      fields: [
        DocField(
          fieldname: 'height',
          fieldtype: 'Float',
          idx: 1,
          label: 'Height',
          nonNegative: true,
        ),
      ],
    );
    final form = await pumpForm(tester, meta);

    await tester.enterText(find.byKey(const ValueKey('numeric_height')), '-1');
    await tester.pump();
    expect(find.text(negativeMsg), findsOneWidget);

    await submitAndSettle(form.submit, tester);
    expect(form.submitted, isEmpty);
    expect(form.failed, hasLength(1));
  });
}
