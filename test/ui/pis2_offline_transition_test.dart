// OfflineTransitionScreen (every state) and OfflineTransitionGuard (idle →
// child, active transition → screen, completion → child again).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeService extends Fake implements OfflineTransitionService {
  int retries = 0;
  int exits = 0;

  @override
  void retry() => retries++;

  @override
  Future<void> forceExit() async => exits++;
}

Future<void> _pumpScreen(
  WidgetTester tester,
  OfflineTransitionState state,
  OfflineTransitionService service,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: OfflineTransitionScreen(state: state, service: service),
    ),
  );
}

void main() {
  group('OfflineTransitionScreen', () {
    testWidgets('draining shows progress as "drained of total"', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        const TransitionDraining(totalRecords: 12, drainedRecords: 5),
        _FakeService(),
      );
      expect(
        find.text('Saving your pending records before going online'),
        findsOneWidget,
      );
      expect(find.text('5 of 12'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('wiping shows the clean-up message', (tester) async {
      await _pumpScreen(tester, const TransitionWipingTables(), _FakeService());
      expect(find.text('Cleaning up local data'), findsOneWidget);
    });

    testWidgets('idle/completed render nothing (not a stuck spinner)', (
      tester,
    ) async {
      await _pumpScreen(tester, const TransitionIdle(), _FakeService());
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('failed shows count, last error, and Retry calls retry', (
      tester,
    ) async {
      final service = _FakeService();
      await _pumpScreen(
        tester,
        const TransitionDrainFailed(
          remainingDirty: 3,
          remainingFailedAttachments: 0,
          lastError: 'HTTP 417: Subject is mandatory',
        ),
        service,
      );
      expect(find.text('Could not save 3 pending record(s)'), findsOneWidget);
      expect(find.text('HTTP 417: Subject is mandatory'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(service.retries, 1);
      expect(service.exits, 0);
    });

    testWidgets('failed without an error message omits the detail line', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        const TransitionDrainFailed(
          remainingDirty: 1,
          remainingFailedAttachments: 0,
        ),
        _FakeService(),
      );
      expect(find.text('Could not save 1 pending record(s)'), findsOneWidget);
      // Icon + count text + two buttons only.
      expect(find.byType(Text), findsNWidgets(3));
    });

    testWidgets('Force exit asks first; Cancel keeps the data', (tester) async {
      final service = _FakeService();
      await _pumpScreen(
        tester,
        const TransitionDrainFailed(
          remainingDirty: 2,
          remainingFailedAttachments: 0,
        ),
        service,
      );
      await tester.tap(find.text('Force exit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Force exit?'), findsOneWidget);
      expect(
        find.text('Discarding 2 pending record(s). This cannot be undone.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(service.exits, 0);
      expect(find.text('Force exit?'), findsNothing);
    });

    testWidgets('Force exit confirmed discards via the service', (
      tester,
    ) async {
      final service = _FakeService();
      await _pumpScreen(
        tester,
        const TransitionDrainFailed(
          remainingDirty: 2,
          remainingFailedAttachments: 0,
        ),
        service,
      );
      await tester.tap(find.text('Force exit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Discard'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(service.exits, 1);
    });

    testWidgets('the OS back button cannot leave the transition screen', (
      tester,
    ) async {
      await _pumpScreen(tester, const TransitionWipingTables(), _FakeService());
      final scope =
          tester.widget(find.byWidgetPredicate((w) => w is PopScope))
              as PopScope;
      expect(scope.canPop, isFalse);
    });

    testWidgets(
      'failed attachments are disclosed before the user discards them',
      (tester) async {
        // BUG SDK2-10 (P3, latent): TransitionDrainFailed carries
        // `remainingFailedAttachments` (offline_transition_service.dart:27)
        // but offline_transition_screen.dart:95 and :110 render only
        // `remainingDirty`. With 0 dirty docs and 3 stuck attachments the
        // confirm reads "Discarding 0 pending record(s)" while Force exit
        // wipes the offline tables. Latent: the service currently always
        // emits remainingFailedAttachments: 0 (service :157).
        await _pumpScreen(
          tester,
          const TransitionDrainFailed(
            remainingDirty: 0,
            remainingFailedAttachments: 3,
          ),
          _FakeService(),
        );
        expect(find.textContaining('3'), findsWidgets);
      },
      skip: true, // BUG SDK2-10: failed attachments not disclosed
    );
  });

  group('OfflineTransitionGuard', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    late AppDatabase db;
    late FrappeSDK sdk;

    setUp(() async {
      db = await AppDatabase.inMemoryDatabase();
      sdk = FrappeSDK.forTesting('https://example.test', db);
    });

    testWidgets('idle shows the wrapped child', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: OfflineTransitionGuard(sdk: sdk, child: const Text('HOME')),
        ),
      );
      expect(find.text('HOME'), findsOneWidget);
      expect(find.byType(OfflineTransitionScreen), findsNothing);
    });

    testWidgets('an active wipe covers the child until it completes', (
      tester,
    ) async {
      // forceExit() records Wiping synchronously, then wipes asynchronously.
      late Future<void> exit;
      await tester.runAsync(() async {
        exit = sdk.offlineTransition.forceExit();
      });
      expect(sdk.offlineTransition.current, isA<TransitionWipingTables>());
      await tester.pumpWidget(
        MaterialApp(
          home: OfflineTransitionGuard(sdk: sdk, child: const Text('HOME')),
        ),
      );
      expect(find.text('Cleaning up local data'), findsOneWidget);
      expect(find.text('HOME'), findsNothing);

      await tester.runAsync(() async {
        await exit;
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(sdk.offlineTransition.current, isA<TransitionCompleted>());
      expect(find.text('HOME'), findsOneWidget);
    });
  });
}
