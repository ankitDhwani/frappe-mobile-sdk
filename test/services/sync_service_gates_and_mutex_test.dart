// SyncService entry points: the connectivity gate, the push runner, the
// shared sync mutex (busy vs waiting), per-doctype isolation in pullSyncMany,
// the active-push defer, the delta window, and getSyncStats.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _enabled = OfflineMode(enabled: true, isPersisted: true);
const _connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');

/// `isOnline()` has no injection seam other than the platform channel; this
/// subclass pins it for the tests that are about something else.
class _Online extends SyncService {
  _Online(
    super.client,
    super.repository,
    super.database, {
    super.pushRunner,
    super.hasActivePush,
  }) : super(offlineMode: _enabled);

  @override
  Future<bool> isOnline() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late List<http.Request> sent;
  late Map<String, http.Response Function(http.Request)> routes;
  late FrappeClient client;
  late OfflineRepository repo;

  setUp(() async {
    db = await AppDatabase.inMemoryDatabase();
    sent = [];
    routes = {};
    client = FrappeClient(
      'http://localhost',
      httpClient: MockClient((req) async {
        sent.add(req);
        final doctype = req.url.queryParameters['doctype'] ?? '';
        final route = routes[doctype];
        if (route != null) return route(req);
        return http.Response(jsonEncode({'message': []}), 200);
      }),
    );
    repo = OfflineRepository(db, offlineMode: _enabled, client: client);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_connectivity, null);
    await db.close();
  });

  group('isOnline', () {
    Future<bool> onlineWith(List<String> states) async {
      messenger.setMockMethodCallHandler(_connectivity, (_) async => states);
      return SyncService(client, repo, db, offlineMode: _enabled).isOnline();
    }

    test('wifi, mobile and ethernet count as online', () async {
      expect(await onlineWith(['wifi']), isTrue);
      expect(await onlineWith(['mobile']), isTrue);
      expect(await onlineWith(['ethernet']), isTrue);
    });

    test('none and bluetooth-only count as offline', () async {
      expect(await onlineWith(['none']), isFalse);
      expect(await onlineWith(['bluetooth']), isFalse);
    });

    test('offline mode disabled is never online, without asking', () async {
      var asked = false;
      messenger.setMockMethodCallHandler(_connectivity, (_) async {
        asked = true;
        return ['wifi'];
      });
      final svc = SyncService(
        client,
        repo,
        db,
        offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      );
      expect(await svc.isOnline(), isFalse);
      expect(asked, isFalse);
    });
  });

  group('pushSync', () {
    test('no connectivity returns noConnectivity without running', () async {
      messenger.setMockMethodCallHandler(_connectivity, (_) async => ['none']);
      var ran = 0;
      final svc = SyncService(
        client,
        repo,
        db,
        offlineMode: _enabled,
        pushRunner: () async => ran++,
      );

      final r = await svc.pushSync();

      expect(ran, 0);
      expect(r.status, SyncStatus.noConnectivity);
    });

    test('a connectivity channel failure is treated as offline', () async {
      messenger.setMockMethodCallHandler(
        _connectivity,
        (_) async => throw PlatformException(code: 'UNAVAILABLE'),
      );
      var ran = 0;
      final svc = SyncService(
        client,
        repo,
        db,
        offlineMode: _enabled,
        pushRunner: () async => ran++,
      );

      final r = await svc.pushSync();

      expect(ran, 0);
      expect(r.status, SyncStatus.noConnectivity);
    });

    test('online runs the runner once and reports a clean run', () async {
      messenger.setMockMethodCallHandler(_connectivity, (_) async => ['wifi']);
      var ran = 0;
      final svc = SyncService(
        client,
        repo,
        db,
        offlineMode: _enabled,
        pushRunner: () async => ran++,
      );

      final r = await svc.pushSync();

      expect(ran, 1);
      expect(r.status, SyncStatus.ran);
      expect(r.error, isNull);
    });

    test('online with no runner wired is an empty run, not an error', () async {
      final r = await _Online(client, repo, db).pushSync();
      expect(r.status, SyncStatus.ran);
      expect(r.total, 0);
    });

    test('a second push while one is running reports busy', () async {
      final gate = Completer<void>();
      var ran = 0;
      final svc = _Online(
        client,
        repo,
        db,
        pushRunner: () async {
          ran++;
          await gate.future;
        },
      );

      final first = svc.pushSync();
      await Future<void>.delayed(Duration.zero);
      final second = await svc.pushSync();
      gate.complete();
      await first;

      expect(second.status, SyncStatus.busy);
      expect(ran, 1);
    });
  });

  group('pull and the shared mutex', () {
    test('pullSync while a push holds the lock reports busy', () async {
      final gate = Completer<void>();
      final svc = _Online(client, repo, db, pushRunner: () => gate.future);
      final push = svc.pushSync();
      await Future<void>.delayed(Duration.zero);

      final pull = await svc.pullSync(doctype: 'Task');
      gate.complete();
      await push;

      expect(pull.status, SyncStatus.busy);
      expect(pull.error, 'Sync already in progress');
      expect(sent, isEmpty, reason: 'a busy pull must not hit the server');
    });

    test('pullSyncWaiting waits for the lock and then pulls', () async {
      final gate = Completer<void>();
      final svc = _Online(client, repo, db, pushRunner: () => gate.future);
      final push = svc.pushSync();
      await Future<void>.delayed(Duration.zero);

      var done = false;
      final pull = svc
          .pullSyncWaiting(doctype: 'Task')
          .whenComplete(() => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(done, isFalse, reason: 'must wait, not drop the request');
      expect(sent, isEmpty);

      gate.complete();
      await push;
      final r = await pull;

      expect(r.status, isNot(SyncStatus.busy));
      expect(sent, hasLength(1));
    });

    test('pullSyncWaiting with no connectivity returns at once', () async {
      messenger.setMockMethodCallHandler(_connectivity, (_) async => ['none']);
      final svc = SyncService(client, repo, db, offlineMode: _enabled);

      final r = await svc.pullSyncWaiting(doctype: 'Task');

      expect(r.status, SyncStatus.noConnectivity);
      expect(sent, isEmpty);
    });

    test('pullSyncMany with no connectivity answers every doctype', () async {
      messenger.setMockMethodCallHandler(_connectivity, (_) async => ['none']);
      final svc = SyncService(client, repo, db, offlineMode: _enabled);

      final r = await svc.pullSyncMany(doctypes: ['Task', 'Item']);

      expect(r.keys, ['Task', 'Item']);
      expect(r.values.map((e) => e.status).toSet(), {
        SyncStatus.noConnectivity,
      });
    });

    test(
      'one failing doctype does not sink the others in pullSyncMany',
      () async {
        routes['Item'] = (_) => http.Response(
          jsonEncode({
            'exc_type': 'PermissionError',
            'exception': 'PermissionError: not allowed',
          }),
          403,
        );
        final svc = _Online(client, repo, db);

        final r = await svc.pullSyncMany(
          doctypes: ['Task', 'Item'],
          concurrency: 2,
        );

        expect(r['Task']?.error, isNull);
        expect(r['Task']?.errors, isEmpty);
        final item = r['Item']!;
        expect(item.error, isNotNull);
        expect(item.errors.single.doctype, 'Item');
        expect(item.errors.single.operation, 'pull');
      },
    );

    test(
      'pullSyncMany while the lock is held reports busy per doctype',
      () async {
        final gate = Completer<void>();
        final svc = _Online(client, repo, db, pushRunner: () => gate.future);
        final push = svc.pushSync();
        await Future<void>.delayed(Duration.zero);

        final r = await svc.pullSyncMany(doctypes: ['Task', 'Item']);
        gate.complete();
        await push;

        expect(r.values.every((e) => e.status == SyncStatus.busy), isTrue);
        expect(sent, isEmpty);
      },
    );
  });

  group('pull window', () {
    Map<String, dynamic> filtersOf(http.Request req) => {
      'filters': jsonDecode(req.url.queryParameters['filters'] ?? '[]'),
    };

    test('a doctype with an active push is deferred, not pulled', () async {
      final asked = <String>[];
      final svc = _Online(
        client,
        repo,
        db,
        hasActivePush: (dt) async {
          asked.add(dt);
          return true;
        },
      );

      final r = await svc.pullSync(doctype: 'Task');

      expect(asked, ['Task']);
      expect(r.status, SyncStatus.deferredActivePush);
      expect(sent, isEmpty);
    });

    test(
      'with no cursor, `since` becomes a strict modified > window',
      () async {
        final since = DateTime(2026, 1, 2, 3, 4, 5).millisecondsSinceEpoch;

        await _Online(client, repo, db).pullSync(doctype: 'Task', since: since);

        final req = sent.single;
        expect(filtersOf(req)['filters'], [
          ['modified', '>', DateTime(2026, 1, 2, 3, 4, 5).toIso8601String()],
        ]);
        expect(req.url.queryParameters['order_by'], 'modified asc, name asc');
      },
    );

    test('a stored cursor wins over `since` and is inclusive', () async {
      await db.doctypeMetaDao.upsertMetaJson('Task', '{}');
      await db.doctypeMetaDao.setLastOkCursor(
        'Task',
        '{"modified":"2026-01-01 00:00:00","name":"TASK-1","complete":true}',
      );

      await _Online(client, repo, db).pullSync(doctype: 'Task', since: 1);

      expect(filtersOf(sent.single)['filters'], [
        ['modified', '>=', '2026-01-01 00:00:00'],
      ]);
    });

    test('a corrupted cursor falls back to a full pull', () async {
      await db.doctypeMetaDao.upsertMetaJson('Task', '{}');
      await db.doctypeMetaDao.setLastOkCursor('Task', '{not json');

      await _Online(client, repo, db).pullSync(doctype: 'Task');

      expect(sent.single.url.queryParameters.containsKey('filters'), isFalse);
    });
  });

  test('getSyncStats is all zeros when offline mode is disabled', () async {
    final svc = SyncService(
      client,
      repo,
      db,
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
    );
    expect(await svc.getSyncStats(), {'dirty': 0, 'deleted': 0, 'total': 0});
  });

  test('getSyncStats on an empty outbox is all zeros', () async {
    expect(await _Online(client, repo, db).getSyncStats(), {
      'dirty': 0,
      'deleted': 0,
      'total': 0,
    });
  });

  test('SyncError reads as operation, doctype/document and message', () {
    final e = SyncError(
      documentId: 'TASK-1',
      doctype: 'Task',
      operation: 'push',
      errorMessage: 'boom',
    );
    expect(e.toString(), 'push failed for Task/TASK-1: boom');
    expect(e.timestamp.difference(DateTime.now()).inSeconds.abs(), lessThan(5));
  });
}
