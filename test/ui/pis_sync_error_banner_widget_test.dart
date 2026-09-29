// SyncErrorBanner widget: one card per stuck row, per-state icon, expand /
// collapse, detail grid, and the per-row Retry lifecycle.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/sync_error_banner.dart';

OutboxRow _row(
  int id,
  OutboxState state, {
  ErrorCode? code,
  String? message,
  int retries = 0,
  DateTime? lastAttempt,
  OutboxOperation op = OutboxOperation.insert,
}) => OutboxRow(
  id: id,
  doctype: 'Task',
  mobileUuid: 'uuid-$id',
  operation: op,
  state: state,
  retryCount: retries,
  lastAttemptAt: lastAttempt,
  errorCode: code,
  errorMessage: message,
  createdAt: DateTime.utc(2026, 1, 1),
);

Future<void> _pump(
  WidgetTester tester,
  List<OutboxRow> rows, {
  Future<void> Function(int)? onRetry,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: SyncErrorBanner(rows: rows, onRetry: onRetry),
      ),
    ),
  ),
);

void main() {
  testWidgets('no rows renders nothing', (tester) async {
    await _pump(tester, const []);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('each state gets its own icon and headline', (tester) async {
    await _pump(tester, [
      _row(1, OutboxState.blocked),
      _row(2, OutboxState.conflict),
      _row(3, OutboxState.failed, code: ErrorCode.NETWORK),
      _row(4, OutboxState.paused, code: ErrorCode.VALIDATION),
      _row(5, OutboxState.pending),
    ]);
    expect(find.byIcon(Icons.hourglass_top_outlined), findsOneWidget);
    expect(find.byIcon(Icons.merge_type), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsOneWidget);
    expect(find.text('Waiting for a related record to sync'), findsOneWidget);
    expect(find.text('Could not reach the server'), findsOneWidget);
    expect(find.text('The server rejected this change'), findsOneWidget);
    expect(find.text('Sync in progress'), findsOneWidget);
  });

  testWidgets('tap expands the detail grid; a second tap collapses it', (
    tester,
  ) async {
    await _pump(tester, [
      _row(
        7,
        OutboxState.failed,
        code: ErrorCode.MANDATORY,
        message: 'MandatoryError: Subject is required. Errors: {exc: ...}',
        retries: 3,
        lastAttempt: DateTime(2026, 9, 1, 8, 5),
        op: OutboxOperation.update,
      ),
    ]);
    expect(find.text('Subject is required'), findsOneWidget);
    expect(find.text('Status'), findsNothing);

    await tester.tap(find.text('Subject is required'));
    await tester.pump();
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('failed'), findsOneWidget);
    expect(find.text('Operation'), findsOneWidget);
    expect(find.text('UPDATE'), findsOneWidget);
    expect(find.text('Error code'), findsOneWidget);
    expect(find.text('MANDATORY'), findsOneWidget);
    expect(find.text('Retry attempts'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Last attempt'), findsOneWidget);
    expect(find.text('2026-09-01 08:05'), findsOneWidget);
    expect(
      find.byType(SelectableText),
      findsOneWidget,
      reason: 'the raw detail is selectable so it can be copied',
    );
    expect(find.text('Retry'), findsNothing, reason: 'no onRetry supplied');

    await tester.tap(find.text('Subject is required'));
    await tester.pump();
    expect(find.text('Status'), findsNothing);
  });

  testWidgets('rows without a code or last attempt omit those grid rows', (
    tester,
  ) async {
    await _pump(tester, [_row(1, OutboxState.blocked)]);
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    expect(find.text('Error code'), findsNothing);
    expect(find.text('Last attempt'), findsNothing);
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('Retry disables itself until the retry future resolves', (
    tester,
  ) async {
    final pending = Completer<void>();
    final retried = <int>[];
    await _pump(
      tester,
      [
        _row(1, OutboxState.failed, code: ErrorCode.TIMEOUT),
        _row(2, OutboxState.failed, code: ErrorCode.NETWORK),
      ],
      onRetry: (id) {
        retried.add(id);
        return pending.future;
      },
    );
    // Expand both rows.
    await tester.tap(find.text('Could not reach the server').first);
    await tester.pump();
    await tester.tap(find.text('Could not reach the server').last);
    await tester.pump();
    expect(find.text('Retry'), findsNWidgets(2));

    await tester.tap(find.text('Retry').first);
    await tester.pump();
    expect(retried, [1]);
    expect(find.text('Retrying…'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget, reason: 'row 2 unaffected');

    // A second tap while in flight is ignored.
    await tester.tap(find.text('Retrying…'));
    await tester.pump();
    expect(retried, [1]);

    pending.complete();
    await tester.pump();
    expect(find.text('Retrying…'), findsNothing);
    expect(find.text('Retry'), findsNWidgets(2));
  });

  testWidgets('a long detail scrolls inside a capped region', (tester) async {
    final long = List.generate(200, (i) => 'line $i').join('\n');
    await _pump(tester, [
      _row(1, OutboxState.failed, code: ErrorCode.UNKNOWN, message: long),
    ]);
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    final cap = find.byWidgetPredicate(
      (w) => w is ConstrainedBox && w.constraints.maxHeight == 160,
    );
    expect(cap, findsOneWidget);
    final box = tester.getSize(cap);
    expect(box.height, lessThanOrEqualTo(160));
  });
}
