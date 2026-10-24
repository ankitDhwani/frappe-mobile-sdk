// Shared screen helpers: status snackbar, confirm dialog, refresh/spinner
// action, empty state, loading dialog, error banner.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/screen_helpers.dart';

/// Pumps a scaffold whose button runs [onTap] with a context below the
/// ScaffoldMessenger / Navigator.
Future<void> _pumpWithButton(
  WidgetTester tester,
  void Function(BuildContext context) onTap,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => onTap(context),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
}

SnackBar _snack(WidgetTester tester) =>
    tester.widget<SnackBar>(find.byType(SnackBar));

void main() {
  group('showStatusSnackBar', () {
    final cases = <SnackBarSeverity, Color?>{
      SnackBarSeverity.success: Colors.green,
      SnackBarSeverity.error: Colors.red,
      SnackBarSeverity.warning: Colors.orange,
      SnackBarSeverity.info: null,
    };
    for (final entry in cases.entries) {
      testWidgets('${entry.key.name} picks its palette colour', (tester) async {
        await _pumpWithButton(
          tester,
          (c) => showStatusSnackBar(c, 'msg', severity: entry.key),
        );
        await tester.tap(find.text('go'));
        await tester.pump();
        expect(find.text('msg'), findsOneWidget);
        expect(_snack(tester).backgroundColor, entry.value);
        expect(_snack(tester).duration, const Duration(seconds: 4));
      });
    }

    testWidgets('explicit colour and duration override the defaults', (
      tester,
    ) async {
      const custom = Color(0xFFE65100);
      await _pumpWithButton(
        tester,
        (c) => showStatusSnackBar(
          c,
          'custom',
          severity: SnackBarSeverity.error,
          backgroundColor: custom,
          duration: const Duration(seconds: 9),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(_snack(tester).backgroundColor, custom);
      expect(_snack(tester).duration, const Duration(seconds: 9));
    });

    testWidgets('DISMISS action is present by default and closes the bar', (
      tester,
    ) async {
      await _pumpWithButton(
        tester,
        (c) => showStatusSnackBar(c, 'bye', severity: SnackBarSeverity.success),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(_snack(tester).action?.label, 'DISMISS');
      expect(_snack(tester).action?.textColor, Colors.white);
      await tester.tap(find.text('DISMISS'));
      await tester.pumpAndSettle();
      expect(find.text('bye'), findsNothing);
    });

    testWidgets('neutral bar leaves the action colour to the theme', (
      tester,
    ) async {
      await _pumpWithButton(tester, (c) => showStatusSnackBar(c, 'info'));
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(_snack(tester).action?.textColor, isNull);
    });

    testWidgets('showDismissAction:false omits the action', (tester) async {
      await _pumpWithButton(
        tester,
        (c) => showStatusSnackBar(c, 'quiet', showDismissAction: false),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(_snack(tester).action, isNull);
    });
  });

  group('showConfirmDialog', () {
    Future<bool?> run(WidgetTester tester, Future<void> Function() act) async {
      bool? result = false;
      var done = false;
      await _pumpWithButton(tester, (c) async {
        result = await showConfirmDialog(
          c,
          title: 'Delete Document',
          content: 'Are you sure?',
          confirmLabel: 'Delete',
          cancelLabel: 'Keep',
          confirmColor: Colors.red,
        );
        done = true;
      });
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Document'), findsOneWidget);
      expect(find.text('Are you sure?'), findsOneWidget);
      await act();
      await tester.pumpAndSettle();
      expect(done, isTrue);
      return result;
    }

    testWidgets('confirm returns true', (tester) async {
      expect(await run(tester, () => tester.tap(find.text('Delete'))), isTrue);
    });

    testWidgets('cancel returns false', (tester) async {
      expect(await run(tester, () => tester.tap(find.text('Keep'))), isFalse);
    });

    testWidgets('confirm label carries the destructive colour', (tester) async {
      await _pumpWithButton(
        tester,
        (c) => showConfirmDialog(
          c,
          title: 't',
          content: 'c',
          confirmColor: Colors.red,
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      final label = tester.widget<Text>(find.text('Confirm'));
      expect(label.style?.color, Colors.red);
      expect(find.text('Cancel'), findsOneWidget);
    });
  });

  group('refreshOrSpinnerAction', () {
    testWidgets('idle: refresh button fires the callback', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                refreshOrSpinnerAction(
                  isBusy: false,
                  onRefresh: () => taps++,
                  tooltip: 'Reload',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Reload'));
      expect(taps, 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('busy: spinner and no refresh button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [refreshOrSpinnerAction(isBusy: true, onRefresh: () {})],
            ),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);
    });
  });

  group('EmptyStateWidget', () {
    testWidgets('title only', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyStateWidget(icon: Icons.inbox, title: 'Nothing here'),
          ),
        ),
      );
      expect(find.text('Nothing here'), findsOneWidget);
      expect(find.byIcon(Icons.inbox), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.inbox)).color, Colors.grey);
    });

    testWidgets('subtitle, action and colour overrides', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmptyStateWidget(
              icon: Icons.cloud_off,
              title: 'Offline',
              subtitle: 'Connect to sync',
              iconColor: Colors.blue,
              subtitleStyle: const TextStyle(fontSize: 11),
              action: TextButton(onPressed: () {}, child: const Text('Retry')),
            ),
          ),
        ),
      );
      expect(find.text('Connect to sync'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.cloud_off)).color,
        Colors.blue,
      );
      expect(
        tester.widget<Text>(find.text('Connect to sync')).style?.fontSize,
        11,
      );
    });
  });

  group('showLoadingDialog', () {
    testWidgets('shows a spinner; dismiss pops it exactly once', (
      tester,
    ) async {
      VoidCallback? dismiss;
      await _pumpWithButton(tester, (c) => dismiss = showLoadingDialog(c));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      dismiss!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // A second call must not pop the page underneath.
      dismiss!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('go'), findsOneWidget);
    });

    testWidgets('the barrier does not dismiss it', (tester) async {
      await _pumpWithButton(tester, (c) => showLoadingDialog(c));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('ErrorMessageBanner', () {
    testWidgets('plain banner fills the width', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ErrorMessageBanner(message: 'Save failed')),
        ),
      );
      expect(find.text('Save failed'), findsOneWidget);
      final box = tester.widget<Container>(
        find
            .ancestor(
              of: find.byIcon(Icons.error),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(box.decoration, isNull, reason: 'plain style: colour, no border');
      expect(box.color, Colors.red[50]);
    });

    testWidgets('bordered banner draws a red border', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ErrorMessageBanner(message: 'Login failed', bordered: true),
          ),
        ),
      );
      final box = tester.widget<Container>(
        find
            .ancestor(
              of: find.byIcon(Icons.error),
              matching: find.byType(Container),
            )
            .first,
      );
      final deco = box.decoration! as BoxDecoration;
      expect(deco.border, isNotNull);
      expect(deco.borderRadius, BorderRadius.circular(8));
    });
  });
}
