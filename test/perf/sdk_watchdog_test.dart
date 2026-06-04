import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  tearDown(() async {
    await SdkWatchdog.resetForTesting();
  });

  test('measure emits a success event', () async {
    final nextEvent = SdkWatchdog.events.first;

    final result = await SdkWatchdog.measure<int>(
      feature: 'test.feature',
      operation: 'success',
      metadata: const <String, Object?>{'doctype': 'Test DocType'},
      body: () async => 42,
    );

    final event = await nextEvent.timeout(const Duration(seconds: 1));
    expect(result, 42);
    expect(event.feature, 'test.feature');
    expect(event.operation, 'success');
    expect(event.success, isTrue);
    expect(event.durationMs, greaterThanOrEqualTo(0));
    expect(event.metadata['doctype'], 'Test DocType');
  });

  test('measure emits a failure event and rethrows', () async {
    final nextEvent = SdkWatchdog.events.first;

    await expectLater(
      SdkWatchdog.measure<void>(
        feature: 'test.feature',
        operation: 'failure',
        body: () async => throw StateError('boom'),
      ),
      throwsStateError,
    );

    final event = await nextEvent.timeout(const Duration(seconds: 1));
    expect(event.success, isFalse);
    expect(event.errorType, 'StateError');
  });

  test('disabled watchdog does not emit events', () async {
    SdkWatchdog.enabledForTesting = false;
    var emitted = false;
    final subscription = SdkWatchdog.events.listen((_) {
      emitted = true;
    });

    final result = await SdkWatchdog.measure<int>(
      feature: 'test.feature',
      operation: 'disabled',
      body: () async => 7,
    );
    await Future<void>.delayed(Duration.zero);

    expect(result, 7);
    expect(emitted, isFalse);
    await subscription.cancel();
  });
}
