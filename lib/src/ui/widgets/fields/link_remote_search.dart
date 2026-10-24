import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../database/entities/link_option_entity.dart';
import '../../../utils/sdk_log.dart';

/// Debounced, ordered and cached server search behind a Link picker.
///
/// [update] is called on every keystroke. It schedules one search [debounce]
/// after the last call, once the text has [minChars] characters and does not
/// already resolve locally. Only the reply to the newest request is applied:
/// every call bumps a sequence number and a reply carrying an older one is
/// dropped, so a slow reply can never overwrite a newer one.
///
/// A term searched before paints its cached rows at once and is still searched
/// again, as Desk's Link control does.
class LinkRemoteSearch {
  LinkRemoteSearch({
    required this.search,
    required this.debounce,
    required this.minChars,
    required this.onUpdate,
  });

  final Future<List<LinkOptionEntity>> Function(String text) search;
  final Duration debounce;
  final int minChars;
  final VoidCallback onUpdate;

  static const int _cacheMax = 20;
  final LinkedHashMap<String, List<LinkOptionEntity>> _cache =
      LinkedHashMap<String, List<LinkOptionEntity>>();

  Timer? _timer;
  int _seq = 0;
  bool _disposed = false;
  String? _term;
  List<LinkOptionEntity>? _results;

  /// A search is scheduled or in flight.
  bool searching = false;

  /// The last search failed; cleared by the next [update] or [retry].
  Object? error;

  /// Whether [text] needs no server search: the first page held every match
  /// ([complete]), or [text] equals an option's docname. A LABEL match does
  /// not count: labels repeat (two records can share a title), and the other one
  /// may be past the first page.
  static bool resolvesLocally(
    List<LinkOptionEntity> options,
    String text, {
    required bool complete,
  }) {
    if (complete) return true;
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return true;
    return options.any((o) => o.name.toLowerCase() == t);
  }

  /// The rows to show: the server's rows first (in its relevance order, and
  /// they reach past the first page), then the local matches it did not
  /// return. Those can carry labels the server does not match on (a fallback
  /// label column, a host relabel), so a server reply never hides them.
  static List<LinkOptionEntity> merge(
    List<LinkOptionEntity> local,
    List<LinkOptionEntity>? remote,
  ) {
    if (remote == null) return local;
    final seen = <String>{for (final o in remote) o.name};
    return [...remote, ...local.where((o) => seen.add(o.name))];
  }

  /// The server's rows for [text], or null when there are none for it (yet).
  List<LinkOptionEntity>? resultsFor(String text) =>
      _term != null && _term == text.trim() ? _results : null;

  void update(String text, {required bool resolvedLocally}) {
    _timer?.cancel();
    final seq = ++_seq;
    final t = text.trim();
    error = null;
    if (t.length < minChars || resolvedLocally) {
      _term = null;
      _results = null;
      searching = false;
      onUpdate();
      return;
    }
    final hit = _cache[t];
    _term = hit == null ? null : t;
    _results = hit;
    searching = true;
    onUpdate();
    _timer = Timer(debounce, () => _run(t, seq));
  }

  void retry(String text) {
    _timer?.cancel();
    final seq = ++_seq;
    error = null;
    searching = true;
    onUpdate();
    _run(text.trim(), seq);
  }

  Future<void> _run(String t, int seq) async {
    try {
      final rows = await search(t);
      if (_disposed || seq != _seq) return;
      _cache.remove(t);
      _cache[t] = rows;
      if (_cache.length > _cacheMax) _cache.remove(_cache.keys.first);
      _term = t;
      _results = rows;
      searching = false;
      onUpdate();
    } catch (e, st) {
      if (_disposed || seq != _seq) return;
      sdkLog('LinkRemoteSearch: search for "$t" failed — $e\n$st');
      searching = false;
      error = e;
      onUpdate();
    }
  }

  /// Forgets every cached term and any reply in flight, e.g. when the
  /// picker's filters change: rows found under the old filters are wrong now.
  void reset() {
    _timer?.cancel();
    _seq++;
    _cache.clear();
    _term = null;
    _results = null;
    searching = false;
    error = null;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
