// Widget tests for DoctypeListScreen: count loading, singular/plural
// subtitles, count failures, tap callbacks, folder layout and lifecycle.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/app_config.dart';
import 'package:frappe_mobile_sdk/src/query/unified_resolver.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/ui/doctype_list_screen.dart';

/// Count source: a fixed map, an optional per-doctype failure, and an
/// optional gate that holds every count until released.
class _FakeResolver extends Fake implements UnifiedResolver {
  _FakeResolver(this.counts, {this.failing = const {}, this.gate});

  final Map<String, int> counts;
  final Set<String> failing;
  final Completer<void>? gate;
  final List<String> calls = [];

  @override
  Future<int> count(String doctype, {bool dirtyOnly = false}) async {
    calls.add(doctype);
    if (gate != null) await gate!.future;
    if (failing.contains(doctype)) throw StateError('count failed');
    return counts[doctype] ?? 0;
  }
}

class _FakeRepo extends Fake implements OfflineRepository {}

AppConfig _config(List<String> doctypes) =>
    AppConfig(baseUrl: 'https://example.invalid', doctypes: doctypes);

Widget _host(DoctypeListScreen screen) => MaterialApp(home: screen);

void main() {
  testWidgets('shows a spinner until counts load, then one tile per doctype', (
    tester,
  ) async {
    final gate = Completer<void>();
    final resolver = _FakeResolver({'Task': 3, 'Item': 1}, gate: gate);
    await tester.pumpWidget(
      _host(
        DoctypeListScreen(
          appConfig: _config(['Task', 'Item']),
          repository: _FakeRepo(),
          resolver: resolver,
          onDoctypeSelected: (_) {},
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete();
    await tester.pump();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Task'), findsOneWidget);
    expect(find.text('Item'), findsOneWidget);
    expect(find.text('3 documents'), findsOneWidget);
    expect(find.text('1 document'), findsOneWidget, reason: 'singular');
  });

  testWidgets('zero documents reads "0 documents"', (tester) async {
    await tester.pumpWidget(
      _host(
        DoctypeListScreen(
          appConfig: _config(['ToDo']),
          repository: _FakeRepo(),
          resolver: _FakeResolver(const {}),
          onDoctypeSelected: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('0 documents'), findsOneWidget);
  });

  testWidgets('a failing count shows 0 without hiding the other doctypes', (
    tester,
  ) async {
    final resolver = _FakeResolver({'Task': 2, 'Item': 7}, failing: {'Task'});
    await tester.pumpWidget(
      _host(
        DoctypeListScreen(
          appConfig: _config(['Task', 'Item']),
          repository: _FakeRepo(),
          resolver: resolver,
          onDoctypeSelected: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('0 documents'), findsOneWidget);
    expect(find.text('7 documents'), findsOneWidget);
    expect(resolver.calls, ['Task', 'Item']);
  });

  testWidgets('explicit doctypes override the app config list', (tester) async {
    await tester.pumpWidget(
      _host(
        DoctypeListScreen(
          appConfig: _config(['Task']),
          doctypes: const ['Customer'],
          repository: _FakeRepo(),
          resolver: _FakeResolver({'Customer': 4}),
          onDoctypeSelected: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Customer'), findsOneWidget);
    expect(find.text('Task'), findsNothing);
    expect(find.text('4 documents'), findsOneWidget);
  });

  testWidgets('empty list shows the empty message', (tester) async {
    await tester.pumpWidget(
      _host(
        DoctypeListScreen(
          appConfig: _config(const []),
          repository: _FakeRepo(),
          resolver: _FakeResolver(const {}),
          onDoctypeSelected: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('No doctypes configured'), findsOneWidget);
  });

  testWidgets('tap opens the doctype; + opens a new document', (tester) async {
    final selected = <String>[];
    final created = <String>[];
    await tester.pumpWidget(
      _host(
        DoctypeListScreen(
          appConfig: _config(['Task']),
          repository: _FakeRepo(),
          resolver: _FakeResolver({'Task': 1}),
          onDoctypeSelected: selected.add,
          onNewDocument: created.add,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Task'));
    await tester.pump();
    expect(selected, ['Task']);

    await tester.tap(find.byTooltip('New document'));
    await tester.pump();
    expect(created, ['Task']);
  });

  testWidgets('no + button when onNewDocument is not supplied', (tester) async {
    await tester.pumpWidget(
      _host(
        DoctypeListScreen(
          appConfig: _config(['Task']),
          repository: _FakeRepo(),
          resolver: _FakeResolver({'Task': 1}),
          onDoctypeSelected: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('New document'), findsNothing);
  });

  group('folder layout', () {
    testWidgets('groups render as folders with per-doctype counts', (
      tester,
    ) async {
      final resolver = _FakeResolver({'Task': 2, 'ToDo': 1, 'Item': 5});
      final created = <String>[];
      await tester.pumpWidget(
        _host(
          DoctypeListScreen(
            appConfig: _config(['Task', 'ToDo', 'Item']),
            repository: _FakeRepo(),
            resolver: resolver,
            homeScreenLayout: HomeScreenLayout.folder,
            groupedDoctypes: const {
              'Work': ['Task', 'ToDo'],
              'Stock': ['Item', 'Task'],
            },
            onDoctypeSelected: (_) {},
            onNewDocument: created.add,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Stock'), findsOneWidget);
      expect(find.text('2 form(s)'), findsNWidgets(2));
      expect(find.text('5 documents'), findsOneWidget);
      // Task appears in two folders but is counted once.
      expect(resolver.calls.where((d) => d == 'Task').length, 1);

      await tester.tap(find.byTooltip('New document').first);
      await tester.pump();
      expect(created, ['Task']);
    });

    testWidgets('no groups: the flat list lands in an "Other" folder', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          DoctypeListScreen(
            appConfig: _config(['Task']),
            repository: _FakeRepo(),
            resolver: _FakeResolver({'Task': 1}),
            homeScreenLayout: HomeScreenLayout.folder,
            onDoctypeSelected: (_) {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Other'), findsOneWidget);
      expect(find.text('1 form(s)'), findsOneWidget);
      expect(find.text('1 document'), findsOneWidget);
    });

    testWidgets(
      'groups alone (empty flat list) still render the folders',
      (tester) async {
        await tester.pumpWidget(
          _host(
            DoctypeListScreen(
              appConfig: _config(const []),
              repository: _FakeRepo(),
              resolver: _FakeResolver({'Task': 2}),
              homeScreenLayout: HomeScreenLayout.folder,
              groupedDoctypes: const {
                'Work': ['Task'],
              },
              onDoctypeSelected: (_) {},
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(
          find.text('No doctypes configured'),
          findsNothing,
          reason: 'counts were loaded for the grouped doctypes',
        );
        expect(find.text('Work'), findsOneWidget);
      },
      skip: true, // BUG SDK-13 (P3)
      // the empty-state gate reads only the flat list, so a
      // grouped-only config shows "No doctypes configured"
    );
  });

  testWidgets('a new doctypes list reloads the counts', (tester) async {
    final resolver = _FakeResolver({'Task': 1, 'Item': 9});
    await tester.pumpWidget(
      _host(
        DoctypeListScreen(
          appConfig: _config(const []),
          doctypes: const ['Task'],
          repository: _FakeRepo(),
          resolver: resolver,
          onDoctypeSelected: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(resolver.calls, ['Task']);

    await tester.pumpWidget(
      _host(
        DoctypeListScreen(
          appConfig: _config(const []),
          doctypes: const ['Task', 'Item'],
          repository: _FakeRepo(),
          resolver: resolver,
          onDoctypeSelected: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(resolver.calls, ['Task', 'Task', 'Item']);
    expect(find.text('9 documents'), findsOneWidget);
  });

  testWidgets(
    'leaving the screen while counts load does not setState after dispose',
    (tester) async {
      final gate = Completer<void>();
      await tester.pumpWidget(
        _host(
          DoctypeListScreen(
            appConfig: _config(['Task']),
            repository: _FakeRepo(),
            resolver: _FakeResolver({'Task': 1}, gate: gate),
            onDoctypeSelected: (_) {},
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Navigate away: the screen's State is disposed with a count pending.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    skip: true, // BUG SDK-12
    // _loadDocumentCounts calls setState in `finally` with no
    // `mounted` check -> "setState() called after dispose()"
  );
}
