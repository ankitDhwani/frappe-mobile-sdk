import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';

class SdkPerfSnapshot {
  const SdkPerfSnapshot({required this.timestamp, required this.rssBytes});

  final DateTime timestamp;
  final int rssBytes;

  static SdkPerfSnapshot capture() {
    return SdkPerfSnapshot(
      timestamp: DateTime.now().toUtc(),
      rssBytes: ProcessInfo.currentRss,
    );
  }
}

class SdkPerfEvent {
  const SdkPerfEvent({
    required this.feature,
    required this.operation,
    required this.startedAt,
    required this.endedAt,
    required this.duration,
    required this.rssBeforeBytes,
    required this.rssAfterBytes,
    required this.success,
    this.metadata = const <String, Object?>{},
    this.errorType,
  });

  final String feature;
  final String operation;
  final DateTime startedAt;
  final DateTime endedAt;
  final Duration duration;
  final int rssBeforeBytes;
  final int rssAfterBytes;
  final bool success;
  final Map<String, Object?> metadata;
  final String? errorType;

  int get durationMs => duration.inMilliseconds;
  int get rssDeltaBytes => rssAfterBytes - rssBeforeBytes;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'feature': feature,
      'operation': operation,
      'startedAt': startedAt.toIso8601String(),
      'endedAt': endedAt.toIso8601String(),
      'durationMs': durationMs,
      'rssBeforeBytes': rssBeforeBytes,
      'rssAfterBytes': rssAfterBytes,
      'rssDeltaBytes': rssDeltaBytes,
      'success': success,
      if (errorType != null) 'errorType': errorType,
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}

class SdkWatchdog {
  SdkWatchdog._();

  static final StreamController<SdkPerfEvent> _controller =
      StreamController<SdkPerfEvent>.broadcast();

  static bool _enabled = kDebugMode || kProfileMode;

  static bool get enabled => _enabled;
  static Stream<SdkPerfEvent> get events => _controller.stream;

  @visibleForTesting
  static set enabledForTesting(bool value) {
    _enabled = value;
  }

  @visibleForTesting
  static Future<void> resetForTesting() async {
    _enabled = kDebugMode || kProfileMode;
  }

  static Future<T> measure<T>({
    required String feature,
    required String operation,
    Map<String, Object?> metadata = const <String, Object?>{},
    required Future<T> Function() body,
  }) async {
    if (!_enabled) return body();

    final before = SdkPerfSnapshot.capture();
    final stopwatch = Stopwatch()..start();
    developer.Timeline.startSync('$feature.$operation');
    try {
      final result = await body();
      stopwatch.stop();
      _emit(
        feature: feature,
        operation: operation,
        startedAt: before.timestamp,
        duration: stopwatch.elapsed,
        rssBeforeBytes: before.rssBytes,
        success: true,
        metadata: metadata,
      );
      return result;
    } catch (error) {
      stopwatch.stop();
      _emit(
        feature: feature,
        operation: operation,
        startedAt: before.timestamp,
        duration: stopwatch.elapsed,
        rssBeforeBytes: before.rssBytes,
        success: false,
        metadata: metadata,
        errorType: error.runtimeType.toString(),
      );
      rethrow;
    } finally {
      developer.Timeline.finishSync();
    }
  }

  static T measureSync<T>({
    required String feature,
    required String operation,
    Map<String, Object?> metadata = const <String, Object?>{},
    required T Function() body,
  }) {
    if (!_enabled) return body();

    final before = SdkPerfSnapshot.capture();
    final stopwatch = Stopwatch()..start();
    developer.Timeline.startSync('$feature.$operation');
    try {
      final result = body();
      stopwatch.stop();
      _emit(
        feature: feature,
        operation: operation,
        startedAt: before.timestamp,
        duration: stopwatch.elapsed,
        rssBeforeBytes: before.rssBytes,
        success: true,
        metadata: metadata,
      );
      return result;
    } catch (error) {
      stopwatch.stop();
      _emit(
        feature: feature,
        operation: operation,
        startedAt: before.timestamp,
        duration: stopwatch.elapsed,
        rssBeforeBytes: before.rssBytes,
        success: false,
        metadata: metadata,
        errorType: error.runtimeType.toString(),
      );
      rethrow;
    } finally {
      developer.Timeline.finishSync();
    }
  }

  static void _emit({
    required String feature,
    required String operation,
    required DateTime startedAt,
    required Duration duration,
    required int rssBeforeBytes,
    required bool success,
    required Map<String, Object?> metadata,
    String? errorType,
  }) {
    if (_controller.isClosed) return;
    final after = SdkPerfSnapshot.capture();
    _controller.add(
      SdkPerfEvent(
        feature: feature,
        operation: operation,
        startedAt: startedAt,
        endedAt: after.timestamp,
        duration: duration,
        rssBeforeBytes: rssBeforeBytes,
        rssAfterBytes: after.rssBytes,
        success: success,
        metadata: metadata,
        errorType: errorType,
      ),
    );
  }
}
