import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../database/entities/link_option_entity.dart';
import '../models/doc_field.dart';
import '../models/doc_type_meta.dart';
import '../models/link_filter_result.dart';
import '../models/link_search_policy.dart';
import '../models/meta_resolver.dart';
import '../query/unified_resolver.dart';
import '../utils/depends_on_evaluator.dart';
import '../utils/sdk_log.dart';

/// Fetches link field options via [UnifiedResolver] (DB-first + background API refresh).
///
/// The resolver handles both offline reads and online background refresh in a
/// single path. Per-form dedupe lives in [LinkFieldCoordinator._resultsCache],
/// which bounds the cost to one resolve call per (doctype, filters) per form open.
class LinkOptionService {
  final UnifiedResolver? _resolver;
  final MetaResolverFn? _metaResolver;
  final Stream<void>? _syncCompleteStream;

  /// Optional translation hook (wired from `TranslationService.translate`).
  /// Applied to option *display labels* — never to the stored `name` — and
  /// only when the target doctype is a `translated_doctype`. Mirrors Frappe's
  /// `__()` on link/select titles. Null in tests / when no host is bound.
  final String Function(String)? _translate;

  /// How pickers load and search options in online-first mode. See
  /// [usesServerSearch].
  final LinkSearchPolicy _searchPolicy;
  LinkSearchPolicy get searchPolicy => _searchPolicy;

  /// Broadcasts after each closure-pull batch finishes. Wired from
  /// [FrappeSDK.syncComplete$]. Pickers and the [LinkFieldCoordinator]
  /// listen to this to invalidate stale empty caches and re-fetch
  /// options for fields whose target doctype just got fresh data.
  ///
  /// A broadcast stream, or null: a single-subscription stream passed to the
  /// constructor is shared through [Stream.asBroadcastStream], which takes
  /// its one subscription when the service is built.
  Stream<void>? get syncComplete$ => _syncCompleteStream;

  /// Primary constructor — inject a wired [UnifiedResolver].
  LinkOptionService(
    UnifiedResolver resolver,
    MetaResolverFn metaResolver, {
    Stream<void>? syncComplete$,
    String Function(String)? translate,
    LinkSearchPolicy searchPolicy = const LinkSearchPolicy(),
  }) : _resolver = resolver,
       _metaResolver = metaResolver,
       // This service and every picker listen; a single-subscription stream
       // takes one listener, so it is shared as a broadcast stream.
       _syncCompleteStream = syncComplete$ == null || syncComplete$.isBroadcast
           ? syncComplete$
           : syncComplete$.asBroadcastStream(),
       _translate = translate,
       _searchPolicy = searchPolicy {
    // A finished sync can change any target, so cached first pages go. This
    // listener is added before any picker exists, so it runs before a picker's
    // own sync-complete reload asks for a first page again.
    _syncCompleteStream?.listen((_) => _forgetFirstPages());
  }

  /// Converts Frappe-shaped filter rows to the 3-tuple `[field, op, value]`
  /// shape that [UnifiedResolver.resolve] consumes. Frappe APIs hand back
  /// either 4-tuples (`[doctype, field, op, value]`) or already-3-tuples;
  /// rows of any other length are silently dropped (consistent with the
  /// pre-refactor inline behavior). The output type is always
  /// `List<List<dynamic>>` so both callers (`getLinkOptions` and
  /// `getLinkOptionsOffline`) get the same typed collection.
  static List<List<dynamic>> _toThreeTuples(List<List>? filters) {
    final out = <List<dynamic>>[];
    if (filters == null) return out;
    for (final f in filters) {
      if (f.length == 4) {
        out.add([f[1], f[2], f[3]]);
      } else if (f.length == 3) {
        out.add(List<dynamic>.from(f));
      }
    }
    return out;
  }

  /// Test / subclass constructor. Use when all methods are overridden and no
  /// resolver is needed (e.g. recording mocks in widget tests).
  LinkOptionService.withoutResolver()
    : _resolver = null,
      _metaResolver = null,
      _syncCompleteStream = null,
      _translate = null,
      _searchPolicy = LinkSearchPolicy.disabled;

  /// Max entries in [_titleCache]. A Link title is a short string, so 500 caps
  /// the cache in the low tens of KB while still covering a long scroll through
  /// a child-table grid. Chosen because the previous unbounded map was the
  /// reason this method was removed once already.
  static const int _titleCacheMaxEntries = 500;

  /// Bounded LRU for [getLinkTitle], keyed `doctype::name`.
  ///
  /// The value is NULLABLE and membership is tested with `containsKey`, so this
  /// distinguishes three states rather than two:
  ///   * absent          — never resolved, or resolved to "retry later"
  ///   * present, non-null — a real distinct title
  ///   * present, null   — resolved, and this doctype has no distinct title to
  ///                       give (no `title_field`), so the answer is final
  ///
  /// That third state is the point. Previously any `label == name` outcome was
  /// left uncached to stay retryable while the target doctype was mid-pull — but
  /// for a doctype whose `title_field` is unset (the majority in Frappe) the
  /// label IS the name permanently, so those keys never populated and every grid
  /// cell re-queried on every build. That is the exact N+1 this method's LRU was
  /// restored to eliminate, still present for the doctypes most likely to appear
  /// in a child-table grid.
  ///
  /// Insertion-ordered: a hit re-inserts the key to move it to the newest
  /// position, and inserting past [_titleCacheMaxEntries] evicts the oldest.
  final Map<String, String?> _titleCache = <String, String?>{};

  /// In-flight lookups, so N grid cells referencing the SAME target await ONE
  /// resolve instead of each firing its own (the N+1 that motivated the
  /// original removal). Cleared when the lookup settles.
  final Map<String, Future<String?>> _titleInFlight =
      <String, Future<String?>>{};

  /// Resolves a single Link VALUE (`name`) of [doctype] to its display title,
  /// offline-first. Returns null when the value is empty or the target row is
  /// not available locally.
  ///
  /// Needed because a Link cell stores the linked document's id, so a grid or
  /// list rendering that value raw shows an opaque id where a human-readable
  /// title belongs. Parent list rows get this for free — the resolver runs
  /// `LinkDecorator.decorateBatch`, which adds a `<field>__display` companion
  /// to each row map. Child-table rows do NOT: they are read straight out of
  /// `docs__<child>` by `mergeChildRowsIntoData`, which never decorates. This
  /// method is the only title path for those cells.
  ///
  /// Bounded by construction: an LRU cap ([_titleCacheMaxEntries]) and
  /// single-flight dedupe ([_titleInFlight]). Prefer `<field>__display` when
  /// reading rows through the resolver — it costs nothing extra there.
  Future<String?> getLinkTitle(String doctype, String name) async {
    if (name.isEmpty) return null;
    final key = '$doctype::$name';

    if (_titleCache.containsKey(key)) {
      // Re-insert to mark as most-recently-used. A null value is a real cached
      // answer ("no distinct title"), not a miss — hence containsKey.
      final cached = _titleCache.remove(key);
      _titleCache[key] = cached;
      return cached;
    }

    final inFlight = _titleInFlight[key];
    if (inFlight != null) return inFlight;

    final future = _resolveLinkTitle(doctype, name, key);
    _titleInFlight[key] = future;
    try {
      return await future;
    } finally {
      _titleInFlight.remove(key);
    }
  }

  Future<String?> _resolveLinkTitle(
    String doctype,
    String name,
    String key,
  ) async {
    final resolver = _resolver;
    final metaResolver = _metaResolver;
    if (resolver == null || metaResolver == null) return null;

    final meta = await metaResolver(doctype);
    // A Link VALUE is the target's Frappe `name`; locally that is
    // `server_name` for synced rows or `mobile_uuid` for rows created on this
    // device that have not pushed yet. `name` is not a local column, so filter
    // on both identity columns.
    final result = await resolver.resolve(
      doctype: doctype,
      orFilters: [
        ['server_name', '=', name],
        ['mobile_uuid', '=', name],
      ],
      page: 0,
      pageSize: 1,
    );
    final entities = _rowsToEntities(
      result.rows,
      doctype,
      meta.titleField,
      translateLabels: meta.translatedDoctype,
    );
    // Row not found locally: genuinely retryable — the target doctype may not
    // have pulled yet. Never cached.
    if (entities.isEmpty) return null;

    final label = entities.first.label;
    final hasTitleField =
        meta.titleField != null && meta.titleField!.isNotEmpty;
    if (label == null || label.isEmpty || label == name) {
      // A doctype with no `title_field` can never produce a title distinct from
      // the name, so this answer is FINAL and worth caching. With a title_field
      // configured the same outcome is transient — the field may be empty on
      // this row now and populated by a later pull — so stay retryable.
      if (!hasTitleField) _cacheTitle(key, null);
      return label;
    }
    _cacheTitle(key, label);
    return label;
  }

  /// Writes [value] for [key] and evicts the oldest entry past the cap.
  void _cacheTitle(String key, String? value) {
    _titleCache[key] = value;
    if (_titleCache.length > _titleCacheMaxEntries) {
      _titleCache.remove(_titleCache.keys.first);
    }
  }

  /// Fetches link options via the resolver (DB-first + background refresh when online).
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async {
    final resolver = _resolver;
    final metaResolver = _metaResolver;
    if (resolver == null || metaResolver == null) return const [];

    final normalizedFilters = _normalizeFiltersForDoctype(doctype, filters);
    final meta = await metaResolver(doctype);
    final titleField = meta.titleField;

    // Convert Frappe 4-tuple filters [doctype, field, op, value] → 3-tuples.
    final threeTuples = _toThreeTuples(normalizedFilters);

    final result = await resolver.resolve(
      doctype: doctype,
      filters: threeTuples,
      page: 0,
      pageSize: _prefetchCap,
    );
    // A full page means the list is truncated and a picker filtering it in
    // memory cannot reach the rest. Say so once per doctype.
    if (result.rows.length >= _prefetchCap && _capLogged.add(doctype)) {
      sdkLog(
        'LinkOptionService: $doctype returned $_prefetchCap options, the '
        'prefetch cap; records past it cannot be picked from a list filtered '
        'in memory. Online-first pickers search the server instead '
        '(LinkSearchPolicy).',
      );
    }

    return _rowsToEntities(
      result.rows,
      doctype,
      titleField,
      translateLabels: meta.translatedDoctype,
    );
  }

  static const int _prefetchCap = 5000;
  final Set<String> _capLogged = <String>{};

  /// Whether a picker for [doctype] loads a short first page and searches the
  /// server as the user types ([searchLinkOptions]) instead of filtering a
  /// [getLinkOptions] prefetch in memory.
  ///
  /// True only in online-first mode (offline mode disabled) with a client,
  /// when [searchPolicy] is enabled and does not list [doctype] in
  /// [LinkSearchPolicy.prefetchOnlyDoctypes]. Always false for a service built
  /// with [LinkOptionService.withoutResolver], so a subclass that overrides
  /// only [getLinkOptions] keeps the prefetch.
  bool usesServerSearch(String doctype) {
    final resolver = _resolver;
    if (resolver == null || _metaResolver == null) return false;
    final policy = _searchPolicy;
    if (!policy.enabled || policy.prefetchOnlyDoctypes.contains(doctype)) {
      return false;
    }
    return !resolver.offlineMode.enabled && resolver.client != null;
  }

  /// Options of [doctype] matching [txt], read from the server; at most
  /// [pageLength] rows. An empty [txt] is the prefetch: the first page.
  ///
  /// Matches `LIKE %txt%` against `name`, the title field and the doctype's
  /// `search_fields`, ORed, and ANDed with [filters]. That is what Desk's Link
  /// control matches (`frappe.desk.search.search_widget`). The request is the
  /// same `frappe.client.get_list` the prefetch makes, so labels are built
  /// exactly as [getLinkOptions] builds them.
  ///
  /// `get_list` returns one page in the doctype's sort order (by default the
  /// most recently modified first), so when that page comes back full a
  /// second request asks for exact matches (`=` on the same columns, same
  /// [filters]). An exact match past the page is then still returned. Rows whose docname or label equals [txt] come first, then
  /// docnames starting with [txt], then the rest in the server's order. Desk
  /// ranks in SQL instead; `order_by` is not used here because the typed text
  /// would have to go inside the SQL expression. `=` follows the database
  /// collation: case-insensitive on MariaDB's default, case-sensitive on
  /// Postgres.
  ///
  /// A translated doctype is matched on its translated labels, which only
  /// exist on the device, so it is fetched whole (as [getLinkOptions]) and
  /// filtered here. Its result can therefore hold MORE than [pageLength] rows.
  Future<List<LinkOptionEntity>> searchLinkOptions(
    String doctype, {
    required String txt,
    required int pageLength,
    List<List<dynamic>>? filters,
  }) async {
    assert(pageLength >= 1, 'pageLength must be at least 1');
    final resolver = _resolver;
    final metaResolver = _metaResolver;
    if (resolver == null || metaResolver == null) return const [];
    final q = txt.trim();

    // Offline mode switched on while a picker was open: a server-shaped query
    // would fail against the local mirror, so search what is on the device.
    if (resolver.offlineMode.enabled) {
      final options = await getLinkOptionsOffline(
        doctype: doctype,
        filters: filters,
        query: q.isEmpty ? null : q,
        pageSize: pageLength,
      );
      return q.isEmpty ? options : _rankForText(options, q);
    }

    if (q.isNotEmpty) {
      return _searchServer(doctype, q, pageLength, filters);
    }
    // The first page: every picker on the same target with the same filters
    // shares one request, and a remount within [_firstPageTtl] reuses it.
    final key = '$doctype|$pageLength|${filters ?? const []}';
    final cached = _firstPages[key];
    if (cached != null &&
        DateTime.now().difference(cached.at) < _firstPageTtl) {
      return cached.options;
    }
    final inFlight = _firstPageInFlight[key];
    if (inFlight != null) return inFlight;
    // A sync that finishes while this request is out makes its answer stale:
    // it is still returned to the pickers that asked, but not cached.
    final generation = _firstPageGeneration;
    late final Future<List<LinkOptionEntity>> request;
    request = _searchServer(doctype, q, pageLength, filters)
        .then((options) {
          if (generation == _firstPageGeneration) {
            _cacheFirstPage(key, options);
          }
          return options;
        })
        .whenComplete(() {
          // A block body on purpose: `=> remove(key)` returns the very
          // future being completed, and whenComplete would wait on itself.
          if (identical(_firstPageInFlight[key], request)) {
            _firstPageInFlight.remove(key);
          }
        });
    return _firstPageInFlight[key] = request;
  }

  static const Duration _firstPageTtl = Duration(seconds: 30);

  /// Most first pages kept at once. Entries also expire after [_firstPageTtl]
  /// and are dropped on the next write.
  static const int _firstPagesMax = 50;
  final Map<String, _FirstPage> _firstPages = <String, _FirstPage>{};
  final Map<String, Future<List<LinkOptionEntity>>> _firstPageInFlight =
      <String, Future<List<LinkOptionEntity>>>{};

  /// Bumped by every finished sync; see [searchLinkOptions].
  int _firstPageGeneration = 0;

  void _cacheFirstPage(String key, List<LinkOptionEntity> options) {
    final now = DateTime.now();
    _firstPages.removeWhere((_, p) => now.difference(p.at) >= _firstPageTtl);
    _firstPages.remove(key);
    _firstPages[key] = _FirstPage(options, now);
    if (_firstPages.length > _firstPagesMax) {
      _firstPages.remove(_firstPages.keys.first);
    }
  }

  void _forgetFirstPages() {
    _firstPageGeneration++;
    _firstPages.clear();
    _firstPageInFlight.clear();
  }

  /// [options] ordered for the typed text [q]: an exact docname or label
  /// match first, then docnames starting with [q], then the rest. Each group
  /// keeps the order it was given in.
  static List<LinkOptionEntity> _rankForText(
    List<LinkOptionEntity> options,
    String q,
  ) {
    final t = q.toLowerCase();
    final exact = <LinkOptionEntity>[];
    final prefix = <LinkOptionEntity>[];
    final rest = <LinkOptionEntity>[];
    for (final o in options) {
      final name = o.name.toLowerCase();
      if (name == t || o.label?.toLowerCase() == t) {
        exact.add(o);
      } else if (name.startsWith(t)) {
        prefix.add(o);
      } else {
        rest.add(o);
      }
    }
    return [...exact, ...prefix, ...rest];
  }

  Future<List<LinkOptionEntity>> _searchServer(
    String doctype,
    String q,
    int pageLength,
    List<List<dynamic>>? filters,
  ) async {
    final resolver = _resolver!;
    final meta = await _metaResolver!(doctype);
    final lower = q.toLowerCase();

    if (meta.translatedDoctype) {
      final all = await getLinkOptions(doctype, filters: filters);
      if (q.isEmpty) return all;
      return all
          .where(
            (o) =>
                (o.label ?? o.name).toLowerCase().contains(lower) ||
                o.name.toLowerCase().contains(lower),
          )
          .toList();
    }

    final threeTuples = _toThreeTuples(
      _normalizeFiltersForDoctype(doctype, filters),
    );
    final columns = searchColumnsFor(meta);
    // [op] and [value] apply to every search column, ORed; none for the
    // first page.
    Future<List<Map<String, Object?>>> fetch(String op, String value) async {
      final result = await resolver.resolve(
        doctype: doctype,
        filters: threeTuples,
        orFilters: [
          if (q.isNotEmpty)
            for (final column in columns) [column, op, value],
        ],
        page: 0,
        pageSize: pageLength,
      );
      return result.rows;
    }

    List<LinkOptionEntity> toOptions(List<Map<String, Object?>> rows) =>
        _rowsToEntities(
          rows,
          doctype,
          meta.titleField,
          translateLabels: meta.translatedDoctype,
        );

    final rows = await fetch('like', '%$q%');
    final options = toOptions(rows);
    if (q.isEmpty) return options;

    // A full page may have cut off an exact match: `get_list` returns the
    // first page in the doctype's sort order (by default, most recently
    // modified). A page that is not full holds every match.
    var exact = const <LinkOptionEntity>[];
    if (rows.length >= pageLength) {
      try {
        exact = toOptions(await fetch('=', q));
      } catch (e, st) {
        // The LIKE page already answered; keep it rather than fail.
        sdkLog(
          'LinkOptionService: exact-match search on $doctype failed, '
          'showing the LIKE page only — $e\n$st',
        );
      }
    }
    final seen = <String>{};
    final merged = [
      ...exact,
      ...options,
    ].where((o) => seen.add(o.name)).toList();
    return _rankForText(merged, q).take(pageLength).toList();
  }

  /// Field types Desk searches in (`search_widget`).
  static const Set<String> _searchableTypes = {
    'Data',
    'Text',
    'Small Text',
    'Long Text',
    'Link',
    'Select',
    'Read Only',
    'Text Editor',
  };

  /// The columns a server search matches: `name`, the title field, then each
  /// `search_fields` entry. Only real fields of a searchable type are kept:
  /// `search_fields` is free text on the server, and a column that does not
  /// exist makes Frappe refuse the whole query (HTTP 417).
  @visibleForTesting
  static List<String> searchColumnsFor(DocTypeMeta meta) {
    final types = <String, String>{
      for (final f in meta.fields)
        if (f.fieldname != null && f.fieldname!.isNotEmpty)
          f.fieldname!: f.fieldtype,
    };
    final out = <String>['name'];
    void add(String? raw) {
      final f = raw?.trim();
      if (f == null || f.isEmpty || out.contains(f)) return;
      if (!_searchableTypes.contains(types[f])) return;
      out.add(f);
    }

    add(meta.titleField);
    for (final f in meta.searchFields ?? const <String>[]) {
      add(f);
    }
    return out;
  }

  /// Converts resolver rows to [LinkOptionEntity] list.
  ///
  /// When [translateLabels] is true and a translate hook is bound, each
  /// option's *display label* is translated while its `name` (the stored
  /// value sent to the server) is left untouched — same contract as the
  /// static Select field.
  List<LinkOptionEntity> _rowsToEntities(
    List<Map<String, Object?>> rows,
    String doctype,
    String? titleField, {
    bool translateLabels = false,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = <LinkOptionEntity>[];
    for (final row in rows) {
      // Offline rows from `docs__<doctype>` carry `server_name`; online rows
      // from `frappe.client.get_list` carry `name`. Mobile-created rows
      // pre-server-confirm carry only `mobile_uuid`. Try all three so the
      // mapping works in both modes.
      final name =
          (row['server_name'] as String?) ??
          (row['name'] as String?) ??
          (row['mobile_uuid'] as String?) ??
          '';
      if (name.isEmpty) continue;
      String? label;
      if (titleField != null && row[titleField] != null) {
        final s = row[titleField].toString().trim();
        if (s.isNotEmpty) label = s;
      }
      for (final k in const [
        'title',
        'full_name',
        'customer_name',
        'supplier_name',
        'label',
      ]) {
        if (label != null && label.isNotEmpty) break;
        final v = row[k];
        if (v != null) {
          final s = v.toString().trim();
          if (s.isNotEmpty) label = s;
        }
      }
      label ??= name;
      // Translate the display label for translated_doctype targets (Frappe
      // `__()` parity). `name` is intentionally left English — it is the
      // value persisted and pushed to the server.
      final translate = _translate;
      if (translateLabels && translate != null) {
        // The translate hook runs host code (TranslationService.translateDelegate
        // is a public, host-settable field) and can throw. A thrown hook must
        // never propagate out of the picker — that would degrade the dropdown to
        // empty instead of just showing the untranslated English label. Same
        // "host hook failures never propagate" contract as [resolveFilters] /
        // [safeHook]; on failure we keep the untranslated label.
        try {
          label = translate(label);
        } catch (e, st) {
          debugPrint(
            'LinkOptionService._rowsToEntities: translate hook threw for '
            '"$label" ($doctype) — using untranslated label. $e\n$st',
          );
        }
      }
      // Offline-only rows (no server_name yet) carry their mobile_uuid as
      // the picker value; the form must mark `<field>__is_local: 1` so the
      // push pipeline rewrites the UUID after the target's INSERT lands.
      final isLocal = (row['server_name'] as String?) == null;
      out.add(
        LinkOptionEntity(
          doctype: doctype,
          name: name,
          label: label,
          dataJson: jsonEncode(row),
          lastUpdated: now,
          isLocal: isLocal,
        ),
      );
    }
    return out;
  }

  /// Normalize filter doctype to match the queried doctype.
  /// Fixes 417 "Field not permitted" when meta uses singular form (e.g. Village)
  /// but API queries plural (Villages).
  ///
  /// Accepts both Frappe filter forms:
  ///   3-tuple [field, op, value]  — doctype is prepended from [doctype].
  ///   4-tuple [dt, field, op, value] — dt is replaced with [doctype] if it
  ///   differs (singular/plural mismatch) or is null/empty.
  static List<List<dynamic>>? _normalizeFiltersForDoctype(
    String doctype,
    List<List<dynamic>>? filters,
  ) {
    if (filters == null || filters.isEmpty) return filters;
    final result = <List<dynamic>>[];
    for (final filter in filters) {
      if (filter.length == 3) {
        result.add([doctype, filter[0], filter[1], filter[2]]);
        continue;
      }
      if (filter.length < 4) {
        debugPrint(
          'LinkOptionService: malformed filter (length ${filter.length}), skipping',
        );
        continue;
      }
      final filterDoctype = filter[0]?.toString();
      if (filterDoctype == null ||
          filterDoctype.isEmpty ||
          filterDoctype != doctype) {
        result.add([doctype, filter[1], filter[2], filter[3]]);
      } else {
        result.add(List<dynamic>.from(filter));
      }
    }
    return result.isEmpty ? null : result;
  }

  @visibleForTesting
  static List<List<dynamic>>? normalizeFiltersForDoctypeForTesting(
    String doctype,
    List<List<dynamic>>? filters,
  ) => _normalizeFiltersForDoctype(doctype, filters);

  /// Returns field names that are dependencies in link_filters (eval:doc.xxx).
  /// Handles both `eval:doc.state` and `eval: doc.state` (Frappe standard format).
  /// e.g. [["District","state","=","eval: doc.state"]] -> ["state"]
  static List<String> getDependentFieldNames(String? linkFiltersJson) {
    if (linkFiltersJson == null || linkFiltersJson.isEmpty) return [];
    try {
      final decoded = jsonDecode(linkFiltersJson) as dynamic;
      final filters = decoded is List
          ? List<dynamic>.from(decoded)
          : <dynamic>[];
      final names = <String>[];
      for (final filter in filters) {
        if (filter is! List) continue;
        for (final elem in filter) {
          if (elem is! String) continue;
          final extracted = DependsOnEvaluator.extractEvalDocField(elem);
          final fieldName =
              extracted ??
              (elem.startsWith('eval:doc.') ? elem.substring(9).trim() : null);
          if (fieldName != null && fieldName.isNotEmpty) {
            if (!names.contains(fieldName)) names.add(fieldName);
          }
        }
      }
      return names;
    } catch (e, st) {
      debugPrint(
        'LinkOptionService.dependentFieldNames parse failed — $e\n$st',
      );
      return [];
    }
  }

  /// Parse Frappe link_filters and build API filters.
  /// Frappe format: [["District","state","=","eval: doc.state"]]
  /// Handles both `eval:doc.x` and `eval: doc.x` (Frappe standard format).
  /// API get_list accepts: [["DocType", "field", "operator", value]] (4 elements).
  static List<List<dynamic>>? parseLinkFilters(
    String? linkFiltersJson,
    Map<String, dynamic> formData,
  ) {
    if (linkFiltersJson == null || linkFiltersJson.isEmpty) return null;
    try {
      final decoded = jsonDecode(linkFiltersJson) as dynamic;
      final filters = decoded is List
          ? List<dynamic>.from(decoded)
          : <dynamic>[];
      final result = <List<dynamic>>[];
      for (final filter in filters) {
        if (filter is! List || filter.length < 4) continue;
        dynamic value = filter[3];
        if (value is String) {
          final fieldName = DependsOnEvaluator.extractEvalDocField(value);
          if (fieldName != null) {
            value = formData[fieldName];
            if (value == null || value == '') continue;
          }
        }
        result.add([filter[0], filter[1], filter[2], value]);
      }
      return result.isEmpty ? null : result;
    } catch (e, st) {
      debugPrint('LinkOptionService.parseLinkFilters parse failed — $e\n$st');
      return null;
    }
  }

  /// Resolves filters for a link-option fetch.
  ///
  /// Precedence:
  /// 1. If [hook] is provided and `field.fieldname` is non-null, invoke it.
  ///    - Non-null result → use `result.filters` (empty list normalizes to null).
  ///    - Null result → fall through to meta.
  ///    - **Throws are caught and treated as null** — host hook failures must
  ///      never propagate into the SDK's UI layer (would freeze the dropdown
  ///      in its loading state). Logged via [debugPrint] for diagnostics.
  /// 2. Parse meta `linkFilters` via [parseLinkFilters] against a merged
  ///    `parentFormData ∪ rowData` view (rowData wins on key collision).
  ///    Mirrors Frappe Desk: child-row Link filters can reference parent
  ///    fields via `eval: doc.X`, just like client scripts that read
  ///    `frm.doc` from a child-row context. For top-level forms
  ///    `parentFormData` equals `rowData`, so the merge is a no-op.
  static List<List<dynamic>>? resolveFilters({
    required DocField field,
    required Map<String, dynamic> rowData,
    required Map<String, dynamic> parentFormData,
    LinkFilterBuilder? hook,
  }) {
    final fieldName = field.fieldname;
    if (hook != null && fieldName != null) {
      LinkFilterResult? result;
      try {
        result = hook(field, fieldName, rowData, parentFormData);
      } catch (e, st) {
        debugPrint(
          'LinkOptionService.resolveFilters: LinkFilterBuilder threw for '
          '${field.options}/$fieldName — falling back to meta. $e\n$st',
        );
        result = null;
      }
      if (result != null) {
        final filters = result.filters;
        if (filters == null || filters.isEmpty) return null;
        return filters;
      }
    }
    return parseLinkFilters(field.linkFilters, {...parentFormData, ...rowData});
  }

  /// Safely invokes a host-provided [getLinkFilterBuilder] factory.
  ///
  /// Host apps register builders via a factory keyed on
  /// `(targetDoctype, fieldname)`. That factory itself runs host code (map
  /// lookups, switch dispatch, etc.) and can throw — a thrown factory must
  /// not propagate into the SDK's UI layer the same way a thrown builder
  /// must not (see [resolveFilters]). All five SDK call sites should route
  /// through this helper instead of calling `getLinkFilterBuilder?.call(...)`
  /// directly so the safety guarantee lives in one place.
  ///
  /// Returns `null` when the factory is null, returns null, or throws.
  static LinkFilterBuilder? safeHook(
    LinkFilterBuilder? Function(String doctype, String fieldname)?
    getLinkFilterBuilder,
    String doctype,
    String fieldname,
  ) {
    if (getLinkFilterBuilder == null) return null;
    try {
      return getLinkFilterBuilder(doctype, fieldname);
    } catch (e, st) {
      debugPrint(
        'LinkOptionService.safeHook: getLinkFilterBuilder threw for '
        '$doctype/$fieldname — falling back to meta. $e\n$st',
      );
      return null;
    }
  }

  /// Offline-first link options with optional text search.
  ///
  /// Delegates to the stored [UnifiedResolver]. The [filters] accept Frappe
  /// 4-tuple `[doctype, field, op, value]` or 3-tuple `[field, op, value]`
  /// form. [query] becomes a `LIKE %...%` search on the docname, the title
  /// field and the doctype's `search_fields`, ORed, as [searchLinkOptions]
  /// searches the server. Locally the docname is `server_name`, or
  /// `mobile_uuid` for a row not pushed yet.
  Future<List<LinkOptionEntity>> getLinkOptionsOffline({
    required String doctype,
    List<List<dynamic>>? filters,
    String? query,
    int page = 0,
    int pageSize = 5000,
  }) async {
    final resolver = _resolver;
    final metaResolver = _metaResolver;
    if (resolver == null || metaResolver == null) return const [];

    final meta = await metaResolver(doctype);
    final titleField = meta.titleField;

    final threeTuples = _toThreeTuples(filters);
    // The title field is always matched, whatever its type, as this method
    // matched it before; [searchColumnsFor] would drop a type Desk does not
    // search (Phone, Autocomplete, ...).
    final columns = searchColumnsFor(meta);
    if (titleField != null &&
        titleField.isNotEmpty &&
        !columns.contains(titleField)) {
      columns.insert(1, titleField);
    }
    final orFilters = <List<dynamic>>[
      if (query != null && query.isNotEmpty)
        for (final column in columns)
          if (column == 'name') ...[
            ['server_name', 'like', '%$query%'],
            ['mobile_uuid', 'like', '%$query%'],
          ] else
            [column, 'like', '%$query%'],
    ];

    final result = await resolver.resolve(
      doctype: doctype,
      filters: threeTuples,
      orFilters: orFilters,
      page: page,
      pageSize: pageSize,
    );

    return _rowsToEntities(
      result.rows,
      doctype,
      titleField,
      translateLabels: meta.translatedDoctype,
    );
  }
}

/// A first page fetched by [LinkOptionService.searchLinkOptions], and when.
class _FirstPage {
  _FirstPage(this.options, this.at);
  final List<LinkOptionEntity> options;
  final DateTime at;
}
