// MobileHomeScreen — counts per doctype, badges, group collapse, custom
// builders, host sync callback, profile sheet. Real in-memory SDK
// (FrappeSDK.forTesting) with a MockClient transport, so nothing leaves the
// process; sqflite ffi runs on real isolates, hence `_settle`.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/table_name.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _taskMeta = {
  'name': 'Task',
  'fields': [
    {'fieldname': 'subject', 'fieldtype': 'Data', 'label': 'Subject'},
  ],
};

Future<FrappeSDK> _sdk({
  Map<String, List<String>> groups = const {
    'Work': ['Task', 'ToDo'],
  },
  int dirty = 0,
  int synced = 0,
}) async {
  final db = await AppDatabase.inMemoryDatabase();
  var sort = 0;
  for (final entry in groups.entries) {
    for (final dt in entry.value) {
      await db.doctypeMetaDao.insertDoctypeMeta(
        DoctypeMetaEntity(
          doctype: dt,
          isMobileForm: true,
          metaJson: jsonEncode({..._taskMeta, 'name': dt}),
          groupName: entry.key,
          sortOrder: sort++,
        ),
      );
    }
  }
  if (dirty + synced > 0) {
    final table = normalizeDoctypeTableName('Task');
    final meta = DocTypeMeta(
      name: 'Task',
      fields: [DocField(fieldname: 'subject', fieldtype: 'Data', label: 'S')],
    );
    for (final s in buildParentSchemaDDL(meta, tableName: table)) {
      await db.rawDatabase.execute(s);
    }
    for (var i = 0; i < dirty + synced; i++) {
      await db.rawDatabase.insert(table, {
        'mobile_uuid': 'u$i',
        'sync_status': i < dirty ? 'dirty' : 'synced',
        'local_modified': i,
        'subject': 'row $i',
      });
    }
  }
  return FrappeSDK.forTesting(
    'https://example.test',
    db,
    httpClient: MockClient((_) async => http.Response('{"message": {}}', 200)),
  );
}

/// Bounded wait: real-time hops + pumps until [until] holds (default: the
/// first-load spinner is gone — groups and counts land in the same setState).
Future<void> _settle(
  WidgetTester tester, {
  int rounds = 150,
  bool Function()? until,
}) async {
  final done =
      until ?? () => find.byType(CircularProgressIndicator).evaluate().isEmpty;
  for (var i = 0; i < rounds; i++) {
    await tester.pump();
    if (i >= 3 && done()) break;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pump();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('each group lists its doctypes with a record count', (
    tester,
  ) async {
    final sdk = (await tester.runAsync(
      () => _sdk(
        groups: {
          'Work': ['Task'],
          'Personal': ['ToDo'],
        },
        dirty: 2,
        synced: 3,
      ),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: MobileHomeScreen(sdk: sdk, appTitle: 'Demo'),
      ),
    );
    await _settle(tester);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('Task'), findsOneWidget);
    expect(find.text('ToDo'), findsOneWidget);
    // 5 rows exist for Task; ToDo has no table yet.
    expect(find.text('5'), findsOneWidget);
    expect(
      find.textContaining('2 unsynced', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('No records yet', findRichText: true), findsOneWidget);
  });

  testWidgets('the app bar carries a total-unsynced badge', (tester) async {
    final sdk = (await tester.runAsync(
      () => _sdk(
        groups: {
          'Work': ['Task'],
        },
        dirty: 4,
      ),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: MobileHomeScreen(sdk: sdk, appTitle: 'Demo'),
      ),
    );
    await _settle(tester);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('4')),
      findsOneWidget,
    );
  });

  testWidgets('all rows synced reads as "all synced" with no badge', (
    tester,
  ) async {
    final sdk = (await tester.runAsync(
      () => _sdk(
        groups: {
          'Work': ['Task'],
        },
        synced: 2,
      ),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: MobileHomeScreen(sdk: sdk, appTitle: 'Demo'),
      ),
    );
    await _settle(tester);
    expect(
      find.textContaining('all synced', findRichText: true),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.arrow_upward), findsNothing);
  });

  testWidgets('tapping a group header collapses and re-expands it', (
    tester,
  ) async {
    final sdk = (await tester.runAsync(_sdk))!;
    await tester.pumpWidget(
      MaterialApp(
        home: MobileHomeScreen(sdk: sdk, appTitle: 'Demo'),
      ),
    );
    await _settle(tester);
    expect(find.text('ToDo'), findsOneWidget);
    await tester.tap(find.text('Work'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ToDo'), findsNothing);
    await tester.tap(find.text('Work'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ToDo'), findsOneWidget);
  });

  testWidgets('custom group header and tile builders receive the counts', (
    tester,
  ) async {
    final sdk = (await tester.runAsync(
      () => _sdk(
        groups: {
          'Work': ['Task', 'ToDo'],
        },
        dirty: 1,
        synced: 1,
      ),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: MobileHomeScreen(
          sdk: sdk,
          appTitle: 'Demo',
          groupHeaderBuilder: (_, name, forms) => Text('H:$name:$forms'),
          tileBuilder: (_, dt, count, dirty, errors) =>
              Text('T:$dt:$count:$dirty:$errors'),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('H:Work:2'), findsOneWidget);
    expect(find.text('T:Task:2:1:0'), findsOneWidget);
    expect(find.text('T:ToDo:0:0:0'), findsOneWidget);
  });

  testWidgets('the host sync callback runs once and the counts reload', (
    tester,
  ) async {
    final sdk = (await tester.runAsync(
      () => _sdk(
        groups: {
          'Work': ['Task'],
        },
        synced: 1,
      ),
    ))!;
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MobileHomeScreen(
          sdk: sdk,
          appTitle: 'Demo',
          onSyncPressed: () async {
            calls++;
            await sdk.database.rawDatabase
                .insert(normalizeDoctypeTableName('Task'), {
                  'mobile_uuid': 'new',
                  'sync_status': 'synced',
                  'local_modified': 99,
                  'subject': 'x',
                });
          },
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('2'), findsNothing);
    await tester.tap(find.byIcon(Icons.sync));
    await _settle(
      tester,
      until: () => calls == 1 && find.text('2').evaluate().isNotEmpty,
    );
    expect(calls, 1);
    // The Task tile's record count went 1 -> 2 after the reload.
    expect(find.text('2'), findsOneWidget);
    // The button is usable again after the sync finished.
    final btn = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.sync),
        matching: find.byType(IconButton),
      ),
    );
    expect(btn.onPressed, isNotNull);
  });

  testWidgets(
    'a failing host sync callback is handled, not thrown out of the tap',
    (tester) async {
      // BUG SDK2-15 (P3): mobile_home_screen.dart `_handleSync` (:201-207)
      // wraps `widget.onSyncPressed!()` in try/finally with NO catch, so a host
      // callback that throws (offline, 5xx) escapes the onPressed handler as
      // an uncaught async error, `_load()` is skipped, and the user gets no
      // message. The built-in path (no callback) swallows and logs the same
      // failures (`manual pushSync failed`).
      final sdk = (await tester.runAsync(
        () => _sdk(
          groups: {
            'Work': ['Task'],
          },
        ),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: MobileHomeScreen(
            sdk: sdk,
            appTitle: 'Demo',
            onSyncPressed: () async => throw StateError('offline'),
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byIcon(Icons.sync));
      await _settle(tester, rounds: 5);
      expect(tester.takeException(), isNull);
    },
    skip: true, // BUG SDK2-15: host sync failure uncaught
  );

  testWidgets('the profile sheet offers re-sync and logout', (tester) async {
    final sdk = (await tester.runAsync(_sdk))!;
    await tester.pumpWidget(
      MaterialApp(
        home: MobileHomeScreen(sdk: sdk, appTitle: 'Demo'),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byType(CircleAvatar));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Force Re-Sync All'), findsOneWidget);
    expect(find.text('Re-download reference & master data'), findsOneWidget);
    expect(find.text('Logout'), findsOneWidget);

    // Re-sync asks for confirmation; cancelling does nothing.
    await tester.tap(find.text('Force Re-Sync All'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Force Re-Sync All?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Force Re-Sync All?'), findsNothing);
  });

  testWidgets('logout asks first; cancelling keeps the session', (
    tester,
  ) async {
    final sdk = (await tester.runAsync(_sdk))!;
    var loggedOut = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MobileHomeScreen(
          sdk: sdk,
          appTitle: 'Demo',
          onLogout: () async => loggedOut++,
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byType(CircleAvatar));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Logout'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Are you sure you want to logout?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(loggedOut, 0);
  });

  testWidgets('no configured forms shows the empty state', (tester) async {
    final sdk = (await tester.runAsync(() => _sdk(groups: const {})))!;
    await tester.pumpWidget(
      MaterialApp(
        home: MobileHomeScreen(sdk: sdk, appTitle: 'Demo'),
      ),
    );
    await _settle(tester);
    expect(find.textContaining('No forms configured'), findsOneWidget);
  });
}
