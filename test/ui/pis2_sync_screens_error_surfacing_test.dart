// SyncErrorsScreen / SyncProgressScreen: every async button surfaces a
// failure to the user instead of dropping it (the screens' documented
// contract), plus the Stop / paused-retry branches.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:frappe_mobile_sdk/src/ui/screens/sync_errors_screen.dart';
import 'package:frappe_mobile_sdk/src/ui/screens/sync_progress_screen.dart';

OutboxRow _row(int id, {OutboxState state = OutboxState.failed}) => OutboxRow(
  id: id,
  doctype: 'Task',
  mobileUuid: 'uuid-$id',
  operation: OutboxOperation.update,
  state: state,
  retryCount: 1,
  errorMessage: 'Subject is mandatory',
  errorCode: ErrorCode.MANDATORY,
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  group('SyncErrorsScreen', () {
    Future<void> pump(
      WidgetTester tester, {
      required List<OutboxRow> rows,
      bool running = false,
      Future<void> Function(int)? onRetry,
      Future<void> Function(int)? onRetryPaused,
      Future<void> Function()? onRetryAll,
      Future<void> Function()? onStop,
      void Function(OutboxRow)? onOpen,
      void Function(OutboxRow)? onView,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SyncErrorsScreen(
            rows: rows,
            retryAllRunning: running,
            onRetry: onRetry ?? (_) async {},
            onRetryPaused: onRetryPaused,
            onRetryAll: onRetryAll ?? () async {},
            onStop: onStop ?? () async {},
            onOpen: onOpen ?? (_) {},
            onViewError: onView ?? (_) {},
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('rows are grouped per doctype with code and message', (
      tester,
    ) async {
      await pump(tester, rows: [_row(1), _row(2)]);
      expect(find.text('Task (2)'), findsOneWidget);
      expect(find.text('uuid-1'), findsOneWidget);
      expect(find.text('MANDATORY · Subject is mandatory'), findsNWidgets(2));
    });

    testWidgets('a failing Retry all is surfaced to the user', (tester) async {
      await pump(
        tester,
        rows: [_row(1)],
        onRetryAll: () async => throw Exception('Server unreachable'),
      );
      await tester.tap(find.text('Retry all'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Retry all failed:'), findsOneWidget);
    });

    testWidgets('while retrying all, Stop is offered and row retry is off', (
      tester,
    ) async {
      var stops = 0;
      await pump(
        tester,
        rows: [_row(1)],
        running: true,
        onStop: () async => stops++,
      );
      expect(find.text('Retry all'), findsNothing);
      final retry = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Retry'),
      );
      expect(retry.onPressed, isNull);
      await tester.tap(find.text('Stop'));
      await tester.pump();
      expect(stops, 1);
    });

    testWidgets('a failing Stop is surfaced too', (tester) async {
      await pump(
        tester,
        rows: [_row(1)],
        running: true,
        onStop: () async => throw Exception('busy'),
      );
      await tester.tap(find.text('Stop'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Stop failed:'), findsOneWidget);
    });

    testWidgets('a paused row retries through the paused handler', (
      tester,
    ) async {
      final plain = <int>[];
      final paused = <int>[];
      await pump(
        tester,
        rows: [_row(7, state: OutboxState.paused)],
        onRetry: (id) async => plain.add(id),
        onRetryPaused: (id) async => paused.add(id),
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
      await tester.pump();
      expect(paused, [7]);
      expect(plain, isEmpty);
    });

    testWidgets('a failing row retry is surfaced', (tester) async {
      await pump(
        tester,
        rows: [_row(3)],
        onRetry: (_) async => throw Exception('still invalid'),
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Retry failed:'), findsOneWidget);
    });

    testWidgets('view and open hand the row to the host', (tester) async {
      OutboxRow? viewed;
      OutboxRow? opened;
      await pump(
        tester,
        rows: [_row(4)],
        onView: (r) => viewed = r,
        onOpen: (r) => opened = r,
      );
      await tester.tap(find.byTooltip('View error'));
      await tester.tap(find.byTooltip('Open'));
      await tester.pump();
      expect(viewed?.id, 4);
      expect(opened?.id, 4);
    });

    testWidgets('no rows: Retry all is disabled', (tester) async {
      await pump(tester, rows: const []);
      final btn = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Retry all'),
      );
      expect(btn.onPressed, isNull);
    });
  });

  group('SyncProgressScreen', () {
    testWidgets('a failing Pause is surfaced to the user', (tester) async {
      final n = SyncStateNotifier();
      n.value = n.value.copyWith(isInitialSync: true);
      await tester.pumpWidget(
        MaterialApp(
          home: SyncProgressScreen(
            notifier: n,
            onPause: () async => throw Exception('not running'),
            onCancel: () async {},
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Pause'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Pause failed:'), findsOneWidget);
    });

    testWidgets('a failing Cancel is surfaced to the user', (tester) async {
      final n = SyncStateNotifier();
      n.value = n.value.copyWith(isInitialSync: true);
      await tester.pumpWidget(
        MaterialApp(
          home: SyncProgressScreen(
            notifier: n,
            onPause: () async {},
            onCancel: () async => throw Exception('already stopped'),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Cancel failed:'), findsOneWidget);
    });
  });
}
