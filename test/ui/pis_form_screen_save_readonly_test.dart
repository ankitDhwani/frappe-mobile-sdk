// FormScreen (legacy builder mode, offline-first repository): read-only
// gating by docstatus / permissions, host validator, required-field block,
// and the offline save path writing docs__<doctype>.
//
// Frappe docstatus: 0 draft (editable), 1 submitted (read-only), 2 cancelled
// (read-only; the server refuses any edit — frappe/model/document.py
// `check_docstatus_transition`: "Cannot edit cancelled document" — and Desk
// renders it as a `cancelled-form`, offering only Amend/Delete).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _meta() => DocTypeMeta(
  name: 'Task',
  fields: [
    DocField(
      fieldname: 'subject',
      fieldtype: 'Data',
      label: 'Subject',
      reqd: true,
    ),
    DocField(fieldname: 'notes', fieldtype: 'Data', label: 'Notes'),
    DocField(fieldname: 'due_on', fieldtype: 'Date', label: 'Due On'),
  ],
);

Document _doc(Object? docstatus) => Document(
  localId: 'task-local-1',
  doctype: 'Task',
  serverId: 'TASK-0001',
  data: {'name': 'TASK-0001', 'subject': 'Hello', 'docstatus': docstatus},
  modified: 0,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;
  void Function()? submit;
  late int saved;

  setUp(() async {
    submit = null;
    saved = 0;
    appDb = await AppDatabase.inMemoryDatabase();
    repo = OfflineRepository(
      appDb,
      localWriter: LocalWriter(appDb.rawDatabase, (_) async => _meta()),
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      metaFetcher: (_) async => _meta(),
    );
    await repo.ensureSchemaForClosure(
      metas: {'Task': _meta()},
      childDoctypes: const {},
    );
  });

  Widget host({
    Document? document,
    bool readOnly = false,
    bool? canSave,
    FormValidator? validator,
  }) => MaterialApp(
    home: Scaffold(
      body: FormScreen(
        meta: _meta(),
        document: document,
        repository: repo,
        readOnly: readOnly,
        canSave: canSave,
        validator: validator,
        registerSubmit: (t) => submit = t,
        onSaveSuccess: () => saved++,
      ),
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> save(WidgetTester tester) async {
    expect(submit, isNotNull, reason: 'form never registered its submit');
    await tester.runAsync(() async {
      submit!();
      await tester.pump();
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await settle(tester);
  }

  Future<List<Map<String, Object?>>> rows(WidgetTester tester) async =>
      (await tester.runAsync(() => appDb.rawDatabase.query('docs__task')))!;

  bool subjectEnabled(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).enabled ?? true;

  group('read-only by docstatus', () {
    testWidgets('draft (0) is editable and deletable', (tester) async {
      await tester.pumpWidget(host(document: _doc(0)));
      await settle(tester);
      expect(subjectEnabled(tester), isTrue);
      expect(find.byTooltip('Delete'), findsOneWidget);
    });

    testWidgets('submitted (1) is read-only and not deletable', (tester) async {
      await tester.pumpWidget(host(document: _doc(1)));
      await settle(tester);
      expect(subjectEnabled(tester), isFalse);
      expect(find.byTooltip('Delete'), findsNothing);
    });

    testWidgets('submitted as the string "1" is read-only too', (tester) async {
      await tester.pumpWidget(host(document: _doc('1')));
      await settle(tester);
      expect(subjectEnabled(tester), isFalse);
    });

    testWidgets(
      'cancelled (2) is read-only',
      (tester) async {
        await tester.pumpWidget(host(document: _doc(2)));
        await settle(tester);
        expect(
          subjectEnabled(tester),
          isFalse,
          reason: 'a cancelled document cannot be edited in Frappe',
        );
      },
      skip: true, // BUG SDK-23
      // FormScreen._isSubmitted checks docstatus == 1 only, so a
      // cancelled document opens editable and can be saved/queued
    );
  });

  group('permission / host gating', () {
    testWidgets('readOnly hides Save even for a new document', (tester) async {
      await tester.pumpWidget(host(readOnly: true));
      await settle(tester);
      expect(find.byKey(const Key('form_save_button')), findsNothing);
      expect(subjectEnabled(tester), isFalse);
    });

    testWidgets('canSave:false hides Save but leaves fields editable', (
      tester,
    ) async {
      await tester.pumpWidget(host(canSave: false));
      await settle(tester);
      expect(find.byKey(const Key('form_save_button')), findsNothing);
      expect(subjectEnabled(tester), isTrue);
    });

    testWidgets('a new document shows Save before any edit', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);
      expect(find.byKey(const Key('form_save_button')), findsOneWidget);
      expect(find.byTooltip('Delete'), findsNothing);
    });
  });

  group('save', () {
    testWidgets('a host validator error blocks the save and is shown', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          validator: (d) => (d['subject']?.toString().length ?? 0) < 3
              ? 'Subject too short'
              : null,
        ),
      );
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, 'ab');
      await save(tester);

      expect(find.text('Subject too short'), findsWidgets);
      expect(saved, 0);
      expect(await rows(tester), isEmpty);
    });

    testWidgets('an empty required field blocks the save', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('data_notes')),
        'only notes',
      );
      await save(tester);
      expect(saved, 0);
      expect(await rows(tester), isEmpty);
      expect(find.text('Subject is required'), findsOneWidget);
    });

    testWidgets('a valid new document is written to the local table', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, 'Write report');
      await save(tester);

      expect(saved, 1);
      final all = await rows(tester);
      expect(all, hasLength(1));
      expect(all.single['subject'], 'Write report');
      expect(all.single['mobile_uuid'], isNotNull);
      expect(find.text('Document saved successfully'), findsOneWidget);
    });

    testWidgets('two saves from one new-document screen make two records', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, 'First');
      await save(tester);
      await tester.enterText(find.byType(TextField).first, 'Second');
      await save(tester);

      final all = await rows(tester);
      expect(all, hasLength(2));
      expect(all.map((r) => r['mobile_uuid']).toSet(), hasLength(2));
      expect(all.map((r) => r['subject']).toSet(), {'First', 'Second'});
    });

    testWidgets('editing a local record updates it in place', (tester) async {
      final uuid = (await tester.runAsync(
        () => repo.saveDocument(doctype: 'Task', data: {'subject': 'Draft'}),
      ))!;
      final doc = Document(
        localId: uuid,
        doctype: 'Task',
        data: {'subject': 'Draft', 'mobile_uuid': uuid},
        modified: 0,
      );
      await tester.pumpWidget(host(document: doc));
      await settle(tester);
      expect(find.text('Draft'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'Final');
      await save(tester);

      final all = await rows(tester);
      expect(all, hasLength(1), reason: 'no forked lineage');
      expect(all.single['mobile_uuid'], uuid);
      expect(all.single['subject'], 'Final');
      expect(saved, 1);
    });

    testWidgets(
      'a record saved with an empty Date field can be reopened',
      (tester) async {
        await tester.pumpWidget(host());
        await settle(tester);
        await tester.enterText(find.byType(TextField).first, 'No due date');
        await save(tester);
        final row = (await rows(tester)).single;

        // Reopen exactly what the list screen would hand the form.
        final doc = Document(
          localId: row['mobile_uuid']! as String,
          doctype: 'Task',
          data: Map<String, dynamic>.from(row),
          modified: 0,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(host(document: doc));
        await settle(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: 'the saved row must not make its own form unrenderable',
        );
        expect(find.text('No due date'), findsOneWidget);
      },
      skip: true, // BUG SDK-25
      // the legacy submit fills "" for an untouched Date, the offline
      // save stores "", and reopening casts "" `as DateTime?` -> TypeError
    );
  });
}
