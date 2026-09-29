// FrappeFormBuilder layout branches not reached before: the stepper tab
// header, translated labels with the mandatory asterisk (label-less styles),
// multi-column sections on narrow vs wide screens, and the Link-field
// coordinator wiring with a real (in-memory) LinkOptionService.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _tabs(int n) => DocTypeMeta(
  name: 'Task',
  fields: [
    for (var i = 0; i < n; i++) ...[
      DocField(fieldname: 'tab_$i', fieldtype: 'Tab Break', label: 'Step $i'),
      DocField(fieldname: 'f_$i', fieldtype: 'Data', label: 'Field $i'),
    ],
  ],
);

DocTypeMeta _columns() => DocTypeMeta(
  name: 'Task',
  fields: [
    DocField(fieldname: 'sec', fieldtype: 'Section Break', label: 'Details'),
    DocField(fieldname: 'left', fieldtype: 'Data', label: 'Left'),
    DocField(fieldname: 'col', fieldtype: 'Column Break'),
    DocField(fieldname: 'right', fieldtype: 'Data', label: 'Right'),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  DocTypeMeta meta, {
  FrappeFormStyle? style,
  String Function(String)? translate,
  LinkOptionService? linkOptions,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FrappeFormBuilder(
          meta: meta,
          style: style,
          translate: translate,
          linkOptionService: linkOptions,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('stepper tab header', () {
    testWidgets('numbers the steps and moves on tap', (tester) async {
      await _pump(
        tester,
        _tabs(3),
        style: const FrappeFormStyle(
          tabHeaderLayout: FormTabHeaderLayout.stepper,
        ),
      );
      expect(find.byType(TabBar), findsNothing);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('Step 0'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);

      await tester.tap(find.text('3'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // Steps before the active one are drawn as completed.
      expect(find.byIcon(Icons.check), findsNWidgets(2));
      expect(find.text('3'), findsOneWidget);

      await tester.tap(find.text('Step 0'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('a single tab renders no header at all', (tester) async {
      await _pump(
        tester,
        _tabs(1),
        style: const FrappeFormStyle(
          tabHeaderLayout: FormTabHeaderLayout.stepper,
        ),
      );
      expect(find.text('1'), findsNothing);
      expect(find.byType(TabBar), findsNothing);
    });

    testWidgets('the default layout is a TabBar', (tester) async {
      await _pump(tester, _tabs(2));
      expect(find.byType(TabBar), findsOneWidget);
    });
  });

  group('translated labels without an external label', () {
    testWidgets('label is translated and a mandatory one carries " *"', (
      tester,
    ) async {
      await _pump(
        tester,
        DocTypeMeta(
          name: 'Task',
          fields: [
            DocField(
              fieldname: 'subject',
              fieldtype: 'Data',
              label: 'Subject',
              reqd: true,
              description: 'What is it about',
            ),
            DocField(
              fieldname: 'notes',
              fieldtype: 'Data',
              label: 'Notes',
              placeholder: 'Anything else',
            ),
          ],
        ),
        style: DefaultFormStyle.compact,
        translate: (s) => '[$s]',
      );
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields[0].decoration!.labelText, '[Subject] *');
      // The description renders below the box, not as a duplicate helper.
      expect(fields[0].decoration!.helperText, isNull);
      expect(fields[1].decoration!.labelText, '[Notes]');
      expect(fields[1].decoration!.hintText, '[Anything else]');
    });

    testWidgets('untranslated compact style marks the hint as mandatory', (
      tester,
    ) async {
      await _pump(
        tester,
        DocTypeMeta(
          name: 'Task',
          fields: [
            DocField(
              fieldname: 'subject',
              fieldtype: 'Data',
              label: 'Subject',
              reqd: true,
            ),
          ],
        ),
        style: DefaultFormStyle.material,
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.hintText, 'Subject *');
    });
  });

  group('multi-column sections', () {
    testWidgets('narrow screens stack the columns', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(tester, _columns());
      expect(find.text('Details'), findsOneWidget);
      final left = tester.getTopLeft(find.text('Left'));
      final right = tester.getTopLeft(find.text('Right'));
      expect(right.dy, greaterThan(left.dy));
    });

    testWidgets('wide screens lay the columns side by side', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(tester, _columns());
      final left = tester.getTopLeft(find.text('Left'));
      final right = tester.getTopLeft(find.text('Right'));
      expect(right.dx, greaterThan(left.dx));
      expect((right.dy - left.dy).abs(), lessThan(1));
    });
  });

  group('Link-field coordinator wiring', () {
    testWidgets('a Link form builds with the coordinator and loads options', (
      tester,
    ) async {
      final sdk = (await tester.runAsync(() async {
        final db = await AppDatabase.inMemoryDatabase();
        return FrappeSDK.forTesting(
          'https://example.test',
          db,
          httpClient: MockClient(
            (_) async => http.Response(jsonEncode({'data': []}), 200),
          ),
        );
      }))!;
      await _pump(
        tester,
        DocTypeMeta(
          name: 'Task',
          fields: [
            DocField(
              fieldname: 'customer',
              fieldtype: 'Link',
              label: 'Customer',
              options: 'Customer',
            ),
          ],
        ),
        linkOptions: sdk.linkOptions,
      );
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('Customer'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
