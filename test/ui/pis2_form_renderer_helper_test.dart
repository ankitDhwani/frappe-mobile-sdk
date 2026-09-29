// FrappeFormRenderer — the minimal host tier: renderForm builds a
// FrappeFormBuilder from cached meta; navigateToForm opens FormScreen in
// create mode (no name) or edit mode (initialData carries a name).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<FrappeSDK> _sdk() async {
  final db = await AppDatabase.inMemoryDatabase();
  await db.doctypeMetaDao.insertDoctypeMeta(
    DoctypeMetaEntity(
      doctype: 'Task',
      isMobileForm: true,
      metaJson: jsonEncode({
        'name': 'Task',
        'fields': [
          {'fieldname': 'subject', 'fieldtype': 'Data', 'label': 'Subject'},
        ],
      }),
    ),
  );
  return FrappeSDK.forTesting(
    'https://example.test',
    db,
    httpClient: MockClient((_) async => http.Response('{}', 200)),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('renderForm builds a form for the doctype meta', (tester) async {
    final sdk = (await tester.runAsync(_sdk))!;
    final renderer = FrappeFormRenderer(sdk: sdk);
    final form = (await tester.runAsync(
      () => renderer.renderForm('Task', initialData: {'subject': 'Hi'}),
    ))!;
    expect(form, isA<FrappeFormBuilder>());
    final builder = form as FrappeFormBuilder;
    expect(builder.meta.name, 'Task');
    expect(builder.readOnly, isFalse);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: form)));
    await _settle(tester);
    expect(find.text('Hi'), findsOneWidget);
  });

  testWidgets('renderForm honours readOnly and a custom style', (tester) async {
    final sdk = (await tester.runAsync(_sdk))!;
    final style = DefaultFormStyle.compact;
    final renderer = FrappeFormRenderer(sdk: sdk, style: style);
    final form =
        (await tester.runAsync(
              () => renderer.renderForm('Task', readOnly: true),
            ))!
            as FrappeFormBuilder;
    expect(form.readOnly, isTrue);
    expect(identical(form.style, style), isTrue);
  });

  testWidgets('navigateToForm without a name opens a new-record form', (
    tester,
  ) async {
    final sdk = (await tester.runAsync(_sdk))!;
    final renderer = FrappeFormRenderer(sdk: sdk);
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const Scaffold(body: Text('HOME'));
          },
        ),
      ),
    );
    await tester.runAsync(() => renderer.navigateToForm(ctx, 'Task'));
    await _settle(tester);
    final screen = tester.widget<FormScreen>(find.byType(FormScreen));
    expect(screen.document, isNull);
    expect(screen.meta.name, 'Task');
  });

  testWidgets('navigateToForm with a name opens that record for editing', (
    tester,
  ) async {
    final sdk = (await tester.runAsync(_sdk))!;
    final renderer = FrappeFormRenderer(sdk: sdk);
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const Scaffold(body: Text('HOME'));
          },
        ),
      ),
    );
    await tester.runAsync(
      () => renderer.navigateToForm(
        ctx,
        'Task',
        initialData: {'name': 'TASK-0001', 'subject': 'Existing'},
      ),
    );
    await _settle(tester);
    final screen = tester.widget<FormScreen>(find.byType(FormScreen));
    expect(screen.document, isNotNull);
    expect(screen.document!.serverId, 'TASK-0001');
    expect(screen.document!.doctype, 'Task');
  });
}
