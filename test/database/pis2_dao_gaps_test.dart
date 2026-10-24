// DAO paths the existing suites never exercised: batch meta insert, IN-list
// lookup, delete helpers, cursor clearing, child/parent delete-by-parent,
// security_state first write, and AppDatabase's database-file naming.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/child_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_dao.dart';
import 'package:frappe_mobile_sdk/src/database/entities/doctype_meta_entity.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DoctypeMetaEntity _meta(
  String doctype, {
  bool mobile = false,
  int? sort,
  String? group,
}) => DoctypeMetaEntity(
  doctype: doctype,
  modified: '2026-01-01 00:00:00',
  isMobileForm: mobile,
  metaJson: jsonEncode({'name': doctype}),
  groupName: group,
  sortOrder: sort,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('DoctypeMetaDao', () {
    late AppDatabase db;

    setUp(() async => db = await AppDatabase.inMemoryDatabase());
    tearDown(() async => db.close());

    test(
      'insertDoctypeMetas writes every row; empty list is a no-op',
      () async {
        final dao = db.doctypeMetaDao;
        await dao.insertDoctypeMetas(const []);
        expect(await dao.findAll(), isEmpty);

        await dao.insertDoctypeMetas([
          _meta('Task', mobile: true, sort: 2, group: 'Work'),
          _meta('ToDo', mobile: true, sort: 1, group: 'Work'),
          _meta('Item'),
        ]);
        final all = await dao.findAll();
        expect(all.map((e) => e.doctype).toSet(), {'Task', 'ToDo', 'Item'});

        // Mobile forms come back in sortOrder, non-mobile rows excluded.
        final mobile = await dao.findMobileFormDoctypes();
        expect(mobile.map((e) => e.doctype).toList(), ['ToDo', 'Task']);
        expect(mobile.first.groupName, 'Work');
      },
    );

    test(
      'insertDoctypeMetas replaces an existing row with the new copy',
      () async {
        final dao = db.doctypeMetaDao;
        await dao.insertDoctypeMeta(_meta('Task', sort: 1));
        await dao.insertDoctypeMetas([_meta('Task', sort: 9)]);
        final all = await dao.findAll();
        expect(all, hasLength(1));
        expect(all.single.sortOrder, 9);
      },
    );

    test('findByDoctypes returns exactly the named rows', () async {
      final dao = db.doctypeMetaDao;
      await dao.insertDoctypeMetas([
        _meta('Task'),
        _meta('ToDo'),
        _meta('Item'),
      ]);
      expect(await dao.findByDoctypes(const []), isEmpty);
      final got = await dao.findByDoctypes(['Item', 'Task', 'Missing']);
      expect(got.map((e) => e.doctype).toSet(), {'Item', 'Task'});
    });

    test(
      'deleteDoctypeMeta removes only that doctype; deleteAll the rest',
      () async {
        final dao = db.doctypeMetaDao;
        await dao.insertDoctypeMetas([_meta('Task'), _meta('ToDo')]);
        await dao.deleteDoctypeMeta(_meta('Task'));
        expect((await dao.findAll()).map((e) => e.doctype), ['ToDo']);
        await dao.deleteAll();
        expect(await dao.findAll(), isEmpty);
      },
    );

    test('clearLastOkCursor nulls the cursor but keeps the row', () async {
      final dao = db.doctypeMetaDao;
      await dao.insertDoctypeMeta(_meta('Task'));
      await dao.setLastOkCursor('Task', '{"modified":"2026-01-01"}');
      expect(await dao.getLastOkCursor('Task'), '{"modified":"2026-01-01"}');
      await dao.clearLastOkCursor('Task');
      expect(await dao.getLastOkCursor('Task'), isNull);
      expect(await dao.findByDoctype('Task'), isNotNull);
    });

    test(
      're-inserting an enrolled doctype keeps its offline bookkeeping',
      () async {
        final dao = db.doctypeMetaDao;
        await dao.insertDoctypeMeta(_meta('Task'));
        await dao.setTableName('Task', 'docs__task');
        await dao.setLastOkCursor('Task', '{"modified":"2026-01-01"}');

        // Upsert a fresher meta copy for the same doctype.
        await dao.insertDoctypeMeta(_meta('Task', sort: 3));

        expect((await dao.findByDoctype('Task'))!.sortOrder, 3);
        final row = (await db.rawDatabase.query(
          'doctype_meta',
          where: 'doctype = ?',
          whereArgs: ['Task'],
        )).single;
        expect(row['table_name'], 'docs__task');
        expect(await dao.getLastOkCursor('Task'), '{"modified":"2026-01-01"}');
      },
      skip:
          'BUG SDK2-9 (P3, latent): doctype_meta_dao.dart:58-62 inserts with '
          'ConflictAlgorithm.replace — SQLite REPLACE deletes the old row, so '
          'table_name / last_ok_cursor / is_entry_point written by the offline '
          'layer are reset to NULL/defaults. Live callers currently guard with '
          'findByDoctype first (meta_service.dart:77-91), so this bites only a '
          'caller that upserts blindly (insertDoctypeMetas has the same shape).',
    );
  });

  group('ChildDao.deleteAllByParent', () {
    late Database raw;
    late ChildDao dao;

    setUp(() async {
      raw = await databaseFactory.openDatabase(inMemoryDatabasePath);
      final meta = DocTypeMeta(
        name: 'Task Item',
        fields: [
          DocField(fieldname: 'item_code', fieldtype: 'Data', label: 'I'),
        ],
      );
      for (final s in buildChildSchemaDDL(meta, tableName: 'docs__task_item')) {
        await raw.execute(s);
      }
      dao = ChildDao(raw, tableName: 'docs__task_item');
    });
    tearDown(() async => raw.close());

    Map<String, Object?> row(String parent, String field, int idx) => {
      'parent_uuid': parent,
      'parent_doctype': 'Task',
      'parentfield': field,
      'idx': idx,
      'item_code': '$parent-$field-$idx',
    };

    test(
      'removes every table field of that parent, and no other parent',
      () async {
        await dao.insert(row('P1', 'items', 1));
        await dao.insert(row('P1', 'items', 2));
        await dao.insert(row('P1', 'extras', 1));
        await dao.insert(row('P2', 'items', 1));

        expect(await dao.deleteAllByParent('P1'), 3);
        expect(await dao.listByParent('P1', 'items'), isEmpty);
        expect(await dao.listByParent('P1', 'extras'), isEmpty);
        expect(await dao.listByParent('P2', 'items'), hasLength(1));
        expect(await dao.deleteAllByParent('nobody'), 0);
      },
    );
  });

  group('DoctypeDao', () {
    late Database raw;
    late DoctypeDao dao;

    setUp(() async {
      raw = await databaseFactory.openDatabase(inMemoryDatabasePath);
      final meta = DocTypeMeta(
        name: 'Customer',
        fields: [
          DocField(fieldname: 'customer_name', fieldtype: 'Data', label: 'N'),
        ],
      );
      for (final s in buildParentSchemaDDL(meta, tableName: 'docs__customer')) {
        await raw.execute(s);
      }
      dao = DoctypeDao(raw, tableName: 'docs__customer');
    });
    tearDown(() async => raw.close());

    test('insert stamps mobile_uuid and local_modified when absent', () async {
      final before = DateTime.now().toUtc().millisecondsSinceEpoch;
      await dao.insert({'sync_status': 'dirty', 'customer_name': 'A'});
      final rows = await dao.findByStatus('dirty');
      expect(rows, hasLength(1));
      expect(rows.single['mobile_uuid'], isA<String>());
      expect((rows.single['mobile_uuid'] as String), isNotEmpty);
      expect(
        rows.single['local_modified'] as int,
        greaterThanOrEqualTo(before),
      );
    });

    test('insert keeps caller-provided identity and timestamp', () async {
      await dao.insert({
        'mobile_uuid': 'u-1',
        'local_modified': 42,
        'sync_status': 'dirty',
      });
      final got = await dao.findByMobileUuid('u-1');
      expect(got!['local_modified'], 42);
    });

    test('deleteByMobileUuid deletes one row and reports the count', () async {
      await dao.insert({'mobile_uuid': 'u-1', 'sync_status': 'dirty'});
      await dao.insert({'mobile_uuid': 'u-2', 'sync_status': 'dirty'});
      expect(await dao.deleteByMobileUuid('u-1'), 1);
      expect(await dao.findByMobileUuid('u-1'), isNull);
      expect(await dao.findByMobileUuid('u-2'), isNotNull);
      expect(await dao.deleteByMobileUuid('u-1'), 0);
    });
  });

  group('SecurityStateDao without the seeded row', () {
    test('first write inserts the singleton row; reads round-trip', () async {
      final db = await AppDatabase.inMemoryDatabase();
      addTearDown(db.close);
      // Simulate a database whose seed row was never created / was wiped.
      await db.rawDatabase.delete('security_state');
      final empty = await db.securityStateDao.readState();
      expect(empty.values, everyElement(isNull));

      await db.securityStateDao.writeState(
        wallTimeMs: 10,
        monotonicMs: null,
        runAtMs: 11,
      );
      final got = await db.securityStateDao.readState();
      expect(got['last_wall_time_ms'], 10);
      expect(got['last_monotonic_ms'], isNull);
      expect(got['last_run_at_ms'], 11);
      final rows = await db.rawDatabase.query('security_state');
      expect(rows, hasLength(1));
    });
  });

  group('AppDatabase file naming', () {
    final opened = <String>[];

    tearDown(() async {
      AppDatabaseTestSeam.resetSingleton();
      for (final path in opened) {
        await databaseFactoryFfi.deleteDatabase(path);
      }
      opened.clear();
    });

    Future<String> openAndName({String? appName}) async {
      final db = await AppDatabase.getInstance(
        appName: appName,
        factoryResolver: (_) async => databaseFactoryFfi,
      );
      final path = db.rawDatabase.path;
      opened.add(path);
      await db.close();
      return p.basename(path);
    }

    test('an explicit app name is sanitised for the filesystem', () async {
      expect(
        await openAndName(appName: 'Field App 2!'),
        'field_app_2_frappe.db',
      );
    });

    test(
      'an app name with no usable characters falls back to default',
      () async {
        expect(await openAndName(appName: '!!!'), 'frappe_mobile_sdk.db');
      },
    );

    test('without an override the platform app name is used', () async {
      PackageInfo.setMockInitialValues(
        appName: 'Demo Tracker',
        packageName: 'com.example.demo',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      expect(await openAndName(), 'demo_tracker_frappe.db');
    });

    test('an empty platform app name falls back to the package name', () async {
      PackageInfo.setMockInitialValues(
        appName: '',
        packageName: 'com.example.demo',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      expect(await openAndName(), 'com_example_demo_frappe.db');
    });

    test('the default resolver opens through FFI', () async {
      final db = await AppDatabase.getInstance(appName: 'Resolver Probe');
      opened.add(db.rawDatabase.path);
      expect(p.basename(db.rawDatabase.path), 'resolver_probe_frappe.db');
      expect(await db.securityStateDao.readState(), isA<Map<String, int?>>());
      await db.close();
    });
  });
}
