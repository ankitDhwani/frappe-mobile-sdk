import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/pending_field_work.dart';

void main() {
  test('is idle when nothing is tracked', () async {
    final work = PendingFieldWork();
    expect(work.isBusy, isFalse);
    await work.whenIdle();
  });

  test('stays busy until the tracked work finishes', () async {
    final work = PendingFieldWork();
    final gate = Completer<void>();
    work.track(gate.future);
    expect(work.isBusy, isTrue);

    var idle = false;
    unawaited(work.whenIdle().then((_) => idle = true));
    await Future<void>.delayed(Duration.zero);
    expect(idle, isFalse, reason: 'still waiting on the tracked work');

    gate.complete();
    await work.whenIdle();
    expect(work.isBusy, isFalse);
    expect(idle, isTrue);
  });

  test('work that fails still ends the wait and is not rethrown', () async {
    final work = PendingFieldWork();
    final gate = Completer<void>();
    work.track(gate.future);
    gate.completeError(StateError('upload failed'));
    await work.whenIdle();
    expect(work.isBusy, isFalse);
  });

  test('waits for work that starts while it is already waiting', () async {
    final work = PendingFieldWork();
    final first = Completer<void>();
    final second = Completer<void>();
    work.track(first.future);

    var idle = false;
    unawaited(work.whenIdle().then((_) => idle = true));
    work.track(second.future);

    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(idle, isFalse, reason: 'the second piece of work is still running');

    second.complete();
    await work.whenIdle();
    await Future<void>.delayed(Duration.zero);
    expect(idle, isTrue);
  });

  test(
    'work that is already finished does not leave the tracker busy',
    () async {
      final work = PendingFieldWork();
      work.track(Future<void>.value());
      await work.whenIdle();
      expect(work.isBusy, isFalse);
    },
  );
}
