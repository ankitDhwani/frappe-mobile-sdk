// FormScreen app-bar and in-form actions: push-to-server, the per-document
// sync-error banner, Button fields (server call / unconfigured / offline),
// and the dirty-driven Save button. Real offline-first OfflineRepository on
// an in-memory database; SyncService is a fake; the API client talks to a
// MockClient.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/sync_error_banner.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _meta({String? buttonOptions}) => DocTypeMeta(
  name: 'Task',
  fields: [
    DocField(fieldname: 'subject', fieldtype: 'Data', label: 'Subject'),
    DocField(fieldname: 'done', fieldtype: 'Check', label: 'Done'),
    DocField(
      fieldname: 'run_check',
      fieldtype: 'Button',
      label: 'Run Check',
      options: buttonOptions,
    ),
  ],
);

Document _doc() => Document(
  localId: 'task-local-1',
  doctype: 'Task',
  serverId: 'TASK-0001',
  data: const {'name': 'TASK-0001', 'subject': 'Hello', 'docstatus': 0},
  modified: 0,
);

class _FakeSync extends Fake implements SyncService {
  final List<String?> pushes = [];
  Object? error;

  @override
  Future<SyncResult> pushSync({String? doctype}) async {
    pushes.add(doctype);
    if (error != null) throw error!;
    return SyncResult(1, 0, 1, null);
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;
  late List<http.Request> requests;
  late http.Response Function(http.Request) respond;

  setUp(() async {
    requests = [];
    respond = (_) => http.Response(jsonEncode({'message': 'ok'}), 200);
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

  FrappeClient api() => FrappeClient(
    'https://example.test',
    httpClient: MockClient((req) async {
      requests.add(req);
      return respond(req);
    }),
  );

  Widget host({
    DocTypeMeta? meta,
    Document? document,
    SyncService? sync,
    FrappeClient? client,
  }) => MaterialApp(
    home: FormScreen(
      meta: meta ?? _meta(),
      document: document ?? _doc(),
      repository: repo,
      syncService: sync,
      api: client,
    ),
  );

  Future<void> settle(WidgetTester tester, {int rounds = 14}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
  }

  group('push to server', () {
    testWidgets('pushes this doctype and confirms', (tester) async {
      final sync = _FakeSync();
      await tester.pumpWidget(host(sync: sync));
      await settle(tester);
      await tester.tap(find.byTooltip('Push to server'));
      await settle(tester);
      expect(sync.pushes, ['Task']);
      expect(find.text('Pushed'), findsOneWidget);
    });

    testWidgets('a failing push is reported and the button comes back', (
      tester,
    ) async {
      final sync = _FakeSync()..error = Exception('Server unreachable');
      await tester.pumpWidget(host(sync: sync));
      await settle(tester);
      await tester.tap(find.byTooltip('Push to server'));
      await settle(tester);
      expect(find.textContaining('Push failed:'), findsOneWidget);
      final btn = tester.widget<IconButton>(
        find.byKey(const Key('form_push_button')),
      );
      expect(btn.onPressed, isNotNull);
    });

    testWidgets('no sync service: no push button', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester);
      expect(find.byTooltip('Push to server'), findsNothing);
    });
  });

  group('sync error banner', () {
    testWidgets('a failed outbox row for this document shows the banner', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final dao = OutboxDao(appDb.rawDatabase);
        final id = await dao.insertPending(
          doctype: 'Task',
          mobileUuid: 'task-local-1',
          operation: OutboxOperation.update,
        );
        await dao.markFailed(
          id,
          errorCode: ErrorCode.VALIDATION,
          errorMessage: 'Subject is mandatory',
        );
      });
      await tester.pumpWidget(host());
      await settle(tester);
      expect(find.byType(SyncErrorBanner), findsOneWidget);
    });

    testWidgets('another document\'s failure does not show here', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final dao = OutboxDao(appDb.rawDatabase);
        final id = await dao.insertPending(
          doctype: 'Task',
          mobileUuid: 'someone-else',
          operation: OutboxOperation.update,
        );
        await dao.markFailed(
          id,
          errorCode: ErrorCode.VALIDATION,
          errorMessage: 'x',
        );
      });
      await tester.pumpWidget(host());
      await settle(tester);
      expect(find.byType(SyncErrorBanner), findsNothing);
    });

    testWidgets('a push that leaves errors says so', (tester) async {
      final sync = _FakeSync();
      await tester.runAsync(() async {
        final dao = OutboxDao(appDb.rawDatabase);
        final id = await dao.insertPending(
          doctype: 'Task',
          mobileUuid: 'task-local-1',
          operation: OutboxOperation.update,
        );
        await dao.markFailed(
          id,
          errorCode: ErrorCode.VALIDATION,
          errorMessage: 'Subject is mandatory',
        );
      });
      await tester.pumpWidget(host(sync: sync));
      await settle(tester);
      await tester.tap(find.byTooltip('Push to server'));
      await settle(tester);
      expect(find.text('Push completed with errors'), findsOneWidget);
    });
  });

  group('Button fields', () {
    testWidgets('a button with no method explains it is web-only', (
      tester,
    ) async {
      await tester.pumpWidget(host(client: api()));
      await settle(tester);
      await tester.tap(find.text('Run Check'));
      await settle(tester);
      expect(
        find.textContaining('Run Check: Action not configured for mobile.'),
        findsOneWidget,
      );
      expect(requests, isEmpty);
    });

    testWidgets('a configured button without an API client is refused', (
      tester,
    ) async {
      await tester.pumpWidget(host(meta: _meta(buttonOptions: 'check_now')));
      await settle(tester);
      await tester.tap(find.text('Run Check'));
      await settle(tester);
      expect(find.text('Action unavailable offline'), findsOneWidget);
    });

    testWidgets('a configured button calls the server and confirms', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          meta: _meta(buttonOptions: 'check_now'),
          client: api(),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('Run Check'));
      await settle(tester);
      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(find.text('Action completed'), findsOneWidget);
    });

    testWidgets('a server error from the button is surfaced', (tester) async {
      respond = (_) => http.Response(
        jsonEncode({
          'exc_type': 'ValidationError',
          '_server_messages': jsonEncode([
            jsonEncode({'message': 'Subject must be set first'}),
          ]),
        }),
        417,
      );
      await tester.pumpWidget(
        host(
          meta: _meta(buttonOptions: 'check_now'),
          client: api(),
        ),
      );
      await settle(tester, rounds: 12);
      await tester.tap(find.text('Run Check'));
      await settle(tester, rounds: 12);
      expect(find.textContaining('Subject must be set first'), findsOneWidget);
      expect(find.text('Action completed'), findsNothing);
    });

    testWidgets(
      'a Button runs its options as a DOCUMENT method, like desk',
      (tester) async {
        // BUG SDK2-16 (P2, parity): form_screen.dart `_handleButtonPressed`
        // (:902-945) posts to /api/method/<options> with {'doc': formData}.
        // Frappe desk's Button control runs `options` as a controller method
        // of the open document: frappe.call("run_doc_method",
        // {docs: frm.doc, method: df.options})
        // (frappe/public/js/frappe/form/controls/button.js:52-58 →
        // frappe/handler.py:262 run_doc_method → getattr(doc, method)).
        // So every Button that works on desk (options = "check_now") hits a
        // non-existent global method on mobile. (button_field.dart:14-15
        // documents the divergent contract.)
        await tester.pumpWidget(
          host(
            meta: _meta(buttonOptions: 'check_now'),
            client: api(),
          ),
        );
        await settle(tester);
        await tester.tap(find.text('Run Check'));
        await settle(tester);
        expect(requests, hasLength(1));
        expect(requests.single.url.path, '/api/method/run_doc_method');
        final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
        expect(body['method'], 'check_now');
        expect(body['docs'], isNotNull);
      },
      skip: true, // BUG SDK2-16: Button calls /api/method/<options>
    );
  });

  group('dirty-driven Save button', () {
    testWidgets('appears on an edit and disappears when reverted', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await settle(tester);
      expect(find.byKey(const Key('form_save_button')), findsNothing);

      await tester.enterText(find.byType(TextField).first, 'Hello world');
      await settle(tester, rounds: 3);
      expect(find.byKey(const Key('form_save_button')), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'Hello');
      await settle(tester, rounds: 3);
      expect(find.byKey(const Key('form_save_button')), findsNothing);
    });

    testWidgets('an unset Check equals an explicit 0 (not dirty)', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await settle(tester);
      // Toggle on and back off: value is now 0 where the baseline had none.
      await tester.tap(find.byType(Switch));
      await settle(tester, rounds: 3);
      expect(find.byKey(const Key('form_save_button')), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await settle(tester, rounds: 3);
      expect(find.byKey(const Key('form_save_button')), findsNothing);
    });
  });
}
