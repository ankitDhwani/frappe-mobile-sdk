import 'package:flutter/widgets.dart';

/// Work a field starts on its own and that has to land before the form is
/// submitted, such as a picked photo that is still uploading.
///
/// A form that submits while such work is running reads the field's value from
/// before the work finished, so the save silently drops what the user just did.
/// The form owns one [PendingFieldWork], shares it with its fields through
/// [PendingFieldWorkScope], and waits on [whenIdle] before it reads the values.
class PendingFieldWork {
  final Set<Future<void>> _running = <Future<void>>{};

  /// True while any tracked work has not finished.
  bool get isBusy => _running.isNotEmpty;

  /// Starts watching [work]. A failure is not rethrown here: the field that
  /// started the work already handles it, and the form only needs to know the
  /// work is over.
  void track(Future<void> work) {
    late final Future<void> done;
    done = () async {
      try {
        await work;
      } catch (_) {
        // The field that started the work reports its own failure.
      } finally {
        _running.remove(done);
      }
    }();
    _running.add(done);
  }

  /// Completes once no tracked work is running, including work that was
  /// started while waiting.
  Future<void> whenIdle() async {
    while (_running.isNotEmpty) {
      await Future.wait<void>(_running.toList());
    }
  }
}

/// Hands the nearest form's [PendingFieldWork] to the fields below it.
class PendingFieldWorkScope extends InheritedWidget {
  const PendingFieldWorkScope({
    super.key,
    required this.tracker,
    required super.child,
  });

  final PendingFieldWork tracker;

  /// The enclosing form's tracker, or null when the field is not inside a form
  /// that waits for its fields.
  static PendingFieldWork? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PendingFieldWorkScope>()?.tracker;

  @override
  bool updateShouldNotify(PendingFieldWorkScope oldWidget) =>
      tracker != oldWidget.tracker;
}
