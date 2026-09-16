import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/child_table_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/field_factory.dart';

/// M7 — pins the hooks THROUGH the factory, not around it.
///
/// Every other child-table test constructs [ChildTableField] directly. That is
/// the path which already worked before round 1 — it is precisely how the hooks
/// were reachable-only-by-forking in the first place, which was the H3 finding.
/// So none of them notice if the wiring is deleted.
///
/// These drive `FieldFactory.createField` and assert on what comes out the far
/// end, so removing the assignment in `field_factory.dart` fails a test rather
/// than silently reverting the fix.
void main() {
  DocField tableField() => DocField(
    fieldname: 'items',
    fieldtype: 'Table',
    label: 'Items',
    options: 'Order Item',
  );

  DocTypeMeta childMeta() => DocTypeMeta(name: 'Order Item', fields: const []);

  Widget childForm(
    DocTypeMeta meta,
    Map<String, dynamic>? initial,
    void Function(Map<String, dynamic>) onSubmit, {
    void Function(void Function() submit)? registerSubmit,
    bool readOnly = false,
  }) => const SizedBox.shrink();

  /// Reaches the [ChildTableField] the factory produced, however deeply it is
  /// wrapped. Deliberately not `as ChildTableField` on the factory's return:
  /// the point of these tests is the path from `createField` down to the leaf.
  ChildTableField findLeaf(WidgetTester tester) =>
      tester.widget<ChildTableField>(find.byType(ChildTableField));

  Future<void> pumpFactoryField(
    WidgetTester tester,
    FieldFactory factory,
  ) async {
    final built = factory.createField(
      field: tableField(),
      value: const <dynamic>[],
      onChanged: (_) {},
      getMeta: (_) async => childMeta(),
      childTableFormBuilder: childForm,
    );
    expect(built, isNotNull, reason: 'the factory must build a Table field');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: built!)));
    await tester.pump();
  }

  testWidgets(
    'H3 — resolveLinkTitle set on the factory reaches ChildTableField',
    (tester) async {
      // The round-1 gate. Delete the assignment in `field_factory.dart` and this
      // fails; before this test, the suite stayed green.
      Future<String?> resolver(String doctype, String name) async => 'resolved';
      final factory = FieldFactory()..resolveLinkTitle = resolver;

      await pumpFactoryField(tester, factory);

      expect(
        findLeaf(tester).resolveLinkTitle,
        same(resolver),
        reason:
            'the hook must arrive by the SAME instance, not be reconstructed',
      );
    },
  );

  testWidgets(
    'H3 — rowNoticeBuilder set on the factory reaches ChildTableField',
    (tester) async {
      String? notice(
        String childDoctype,
        String parentFieldname,
        Map<String, dynamic>? row,
      ) => 'notice';
      final factory = FieldFactory()..rowNoticeBuilder = notice;

      await pumpFactoryField(tester, factory);

      expect(findLeaf(tester).rowNoticeBuilder, same(notice));
    },
  );

  group('H4 memoisation and M2b read-only inertness', _h4AndM2bTests);

  testWidgets('a factory with no hooks leaves them null, not a stub', (
    tester,
  ) async {
    // Guards the opposite direction: a default factory must not manufacture a
    // resolver, or a host could never tell "not configured" from "configured
    // and returning nothing".
    await pumpFactoryField(tester, FieldFactory());

    final leaf = findLeaf(tester);
    expect(leaf.resolveLinkTitle, isNull);
    expect(leaf.rowNoticeBuilder, isNull);
  });
}

/// H4 — resolution is memoised per row, and M2b — a read-only sheet is inert.
void _h4AndM2bTests() {
  DocField tableField() => DocField(
    fieldname: 'items',
    fieldtype: 'Table',
    label: 'Items',
    options: 'Order Item',
  );

  Widget childForm(
    DocTypeMeta meta,
    Map<String, dynamic>? initial,
    void Function(Map<String, dynamic>) onSubmit, {
    void Function(void Function() submit)? registerSubmit,
    bool readOnly = false,
  }) => const SizedBox.shrink();

  testWidgets(
    'H4 — a parent rebuild that does not touch the rows re-resolves nothing',
    (tester) async {
      // Same shape as `attach_field_resolve_test.dart`'s "once per tap, not once
      // per rebuild". Before the memoisation, resolution was started inside
      // `ListView.builder`'s itemBuilder, so a keystroke anywhere on the parent
      // form cost one getMeta plus one title lookup PER LINK COLUMN PER ROW — and
      // blanked the grid to an ellipsis while they reran.
      var resolveCalls = 0;
      Future<String?> counting(String doctype, String name) async {
        resolveCalls++;
        return 'Title for $name';
      }

      final rows = <dynamic>[
        <String, dynamic>{'item': 'ITEM-1'},
        <String, dynamic>{'item': 'ITEM-2'},
      ];

      late StateSetter rebuildParent;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuildParent = setState;
                return ChildTableField(
                  field: tableField(),
                  value: rows,
                  onChanged: (_) {},
                  getMeta: (_) async => DocTypeMeta(
                    name: 'Order Item',
                    fields: [
                      DocField(
                        fieldname: 'item',
                        fieldtype: 'Link',
                        label: 'Item',
                        options: 'Item',
                        inListView: true,
                      ),
                    ],
                  ),
                  formBuilder: childForm,
                  resolveLinkTitle: counting,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final afterFirstPaint = resolveCalls;
      expect(
        afterFirstPaint,
        greaterThan(0),
        reason:
            'the rows must resolve at least once, or the test proves nothing',
      );

      // A rebuild of the parent that leaves every row map identical.
      rebuildParent(() {});
      await tester.pumpAndSettle();
      rebuildParent(() {});
      await tester.pumpAndSettle();

      expect(
        resolveCalls,
        afterFirstPaint,
        reason: 'an unrelated parent rebuild must reuse the completed result',
      );
    },
  );

  testWidgets(
    'M2b — a read-only child grid wraps its sheet body in AbsorbPointer',
    (tester) async {
      // `readOnly: true` is passed to the host's builder, but a typedef cannot
      // force a host to honour it — the minimal migration is to declare and
      // ignore it, which renders a fully editable form with a Close button. The
      // AbsorbPointer makes the subtree inert regardless.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChildTableField(
              field: tableField(),
              value: const [
                <String, dynamic>{'item': 'ITEM-1'},
              ],
              onChanged: (_) {},
              enabled: false, // -> isReadOnly
              getMeta: (_) async =>
                  DocTypeMeta(name: 'Order Item', fields: const []),
              formBuilder: childForm,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();

      final absorbing = tester
          .widgetList<AbsorbPointer>(find.byType(AbsorbPointer))
          .where((a) => a.absorbing);
      expect(
        absorbing,
        isNotEmpty,
        reason: 'the read-only sheet body must be inert whatever the host does',
      );
    },
  );
}
