import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// M1 — B1's guard, against the REAL screen.
///
/// `form_screen_document_uuid_test.dart` states the identity rule and checks it
/// against a `_DocumentIdentity` declared in the test file. That pins the rule,
/// not the screen: delete the realignment from `form_screen.dart` and those
/// tests still pass, because nothing in them touches `form_screen.dart`.
///
/// This one mounts `FormScreen` and reads the identity the screen itself is
/// carrying, so removing the `didUpdateWidget` realignment fails it.
DocTypeMeta _meta() => DocTypeMeta(
  name: 'Visit',
  fields: [DocField(fieldname: 'title', fieldtype: 'Data', label: 'Title')],
);

Document _existing() => Document(
  localId: 'local-visit-1',
  doctype: 'Visit',
  serverId: 'VISIT-0001',
  data: const {'title': 'a'},
  modified: 0,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    repo = OfflineRepository(
      appDb,
      localWriter: LocalWriter(appDb.rawDatabase, (_) async => _meta()),
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      metaFetcher: (_) async => _meta(),
    );
  });

  tearDown(() async => appDb.close());

  String uuidOf(WidgetTester tester) {
    final dynamic state = tester.state(find.byType(FormScreen));
    return state.documentMobileUuidForTesting as String;
  }

  Future<void> pumpWith(WidgetTester tester, Document? document) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormScreen(
            meta: _meta(),
            repository: repo,
            document: document,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a new record keeps one identity across rebuilds', (
    tester,
  ) async {
    await pumpWith(tester, null);
    final first = uuidOf(tester);
    await pumpWith(tester, null);

    expect(
      uuidOf(tester),
      first,
      reason: 'stable across retries OF ONE DOCUMENT is the whole contract',
    );
  });

  testWidgets('an existing record is locked to its localId', (tester) async {
    final doc = _existing();
    await pumpWith(tester, doc);

    expect(uuidOf(tester), doc.localId);
  });

  testWidgets('document -> null re-mints: "save and add another" is a NEW '
      'record', (tester) async {
    // The uuid the screen minted for its ORIGINAL new-record life. This is
    // what the assertion has to be against: comparing the re-mint to the
    // document's own localId would pass with the realignment deleted, since
    // `_documentMobileUuid` falls back to the screen-held value the moment
    // `document` goes null. That trivially-true shape is the M1 defect itself.
    await pumpWith(tester, null);
    final beforeEditing = uuidOf(tester);

    await pumpWith(tester, _existing());
    expect(uuidOf(tester), _existing().localId, reason: 'locked while editing');

    // The transition the realignment exists for. Without it the screen falls
    // back to `beforeEditing`, and the next create carries a key the server has
    // already seen — resolving to the previous document instead of inserting.
    await pumpWith(tester, null);

    expect(uuidOf(tester), isNot(beforeEditing));
  });
}
