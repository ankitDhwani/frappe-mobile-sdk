// DocumentListScreen → FormScreen hand-off: opening an existing record,
// creating a new one, and what a READ-only user can do. Real offline-first
// OfflineRepository (in-memory) so attachChildRows / FormScreen run for real;
// the list rows come from a fake resolver.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeResolver extends Fake implements UnifiedResolver {
  _FakeResolver(this.rows);
  final List<Map<String, Object?>> rows;

  @override
  Future<QueryResult<Map<String, Object?>>> resolve({
    required String doctype,
    List<List> filters = const [],
    List<List> orFilters = const [],
    String? orderBy,
    int page = 0,
    int pageSize = 50,
    bool includeFailed = false,
  }) async => QueryResult.ofRows(rows, pageSize, const {});
}

class _OfflineSync extends Fake implements SyncService {
  @override
  Future<bool> isOnline() async => false;
}

class _FakeMetaService extends Fake implements MetaService {}

DocTypeMeta _meta({Map<String, dynamic>? perms}) => DocTypeMeta(
  name: 'Task',
  label: 'Task',
  titleField: 'subject',
  metaData: perms,
  fields: [DocField(fieldname: 'subject', fieldtype: 'Data', label: 'Subject')],
);

final _readOnlyPerms = <String, dynamic>{
  'permissions': [
    {'role': 'Viewer', 'permlevel': 0, 'read': 1, 'write': 0, 'create': 0},
  ],
};

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late OfflineRepository repo;

  setUp(() async {
    db = await AppDatabase.inMemoryDatabase();
    repo = OfflineRepository(
      db,
      localWriter: LocalWriter(db.rawDatabase, (_) async => _meta()),
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      metaFetcher: (_) async => _meta(),
    );
    await repo.ensureSchemaForClosure(
      metas: {'Task': _meta()},
      childDoctypes: const {},
    );
  });

  Future<void> pump(
    WidgetTester tester, {
    DocTypeMeta? meta,
    List<String>? roles,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentListScreen(
          doctype: 'Task',
          meta: meta ?? _meta(),
          repository: repo,
          resolver: _FakeResolver([
            {
              'name': 'TASK-0001',
              'server_name': 'TASK-0001',
              'mobile_uuid': 'u-1',
              'subject': 'Water the plants',
              'sync_status': 'synced',
            },
          ]),
          syncService: _OfflineSync(),
          metaService: _FakeMetaService(),
          userRoles: roles,
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  /// Bounded wait until the FormScreen route is built (or ~3 s elapse).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 60));
      if (i >= 5 && find.byType(FormScreen).evaluate().isNotEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('tapping a row opens that record in an editable form', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Water the plants'));
    await settle(tester);
    final screen = tester.widget<FormScreen>(find.byType(FormScreen));
    expect(screen.document?.serverId, 'TASK-0001');
    expect(screen.readOnly, isFalse);
  });

  testWidgets('the create button opens an empty new-record form', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await settle(tester);
    final screen = tester.widget<FormScreen>(find.byType(FormScreen));
    expect(screen.document, isNull);
    expect(screen.canSave, isTrue);
  });

  testWidgets(
    'a READ-only user can still open a record to view it',
    (tester) async {
      // BUG SDK2-21 (P2): document_list_screen.dart `_openForm` returns early
      // when `!_canWrite` (:631), so a role with read but not write
      // permission can list records but never open one. Frappe opens the
      // form read-only in that case (read perm is all `frappe.client.get`
      // needs; desk sets the form read-only when perm.write is 0). The same
      // method even computes `readOnly: !isNew && !_canWrite` for FormScreen
      // (:722) — dead code behind the early return.
      // NOTE: round-1 test/ui/pis_document_list_screen_test.dart
      // "no write permission: tapping a row opens nothing" pins the current
      // (wrong) behaviour and must be dropped with the fix.
      await pump(
        tester,
        meta: _meta(perms: _readOnlyPerms),
        roles: ['Viewer'],
      );
      await tester.tap(find.text('Water the plants'));
      await settle(tester);
      final screen = tester.widget<FormScreen>(find.byType(FormScreen));
      expect(screen.readOnly, isTrue);
      expect(screen.canDelete, isFalse);
    },
    skip: true, // BUG SDK2-21: read-only user cannot open a record
  );
}
