import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/normalize_for_search.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/link_search_policy.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/query/unified_resolver.dart';
import 'package:frappe_mobile_sdk/src/services/link_option_service.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Answers every get_list with [rows] (or per request, with [_answer]) and
/// records what reached the server.
class _Server extends http.BaseClient {
  _Server(List<Map<String, Object?>> rows) : _answer = ((_) => rows);
  _Server.answering(this._answer);
  final List<Map<String, Object?>> Function(Uri url) _answer;
  final List<Uri> seen = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen.add(request.url);
    final rows = _answer(request.url);
    return http.StreamedResponse(
      Stream.fromIterable([
        utf8.encode(jsonEncode({'message': rows})),
      ]),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

/// Fails every request: a dropped connection, or an HTTP error status.
class _Failing extends http.BaseClient {
  _Failing.dropped() : status = null;
  _Failing.status(int this.status);
  final int? status;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final code = status;
    if (code == null) throw http.ClientException('Connection reset by peer');
    return http.StreamedResponse(
      Stream.fromIterable([
        utf8.encode(jsonEncode({'exc_type': 'Error', 'exception': 'refused'})),
      ]),
      code,
      headers: const {'content-type': 'application/json'},
    );
  }
}

/// The or_filters a request carried, decoded (empty when it sent none).
List<dynamic> _orFilters(Uri url) {
  final raw = url.queryParameters['or_filters'];
  return raw == null ? const [] : jsonDecode(raw) as List<dynamic>;
}

/// A target with no title field and no search fields.
DocTypeMeta _plainMeta(String name) => DocTypeMeta(
  name: name,
  fields: [DocField(fieldname: 'notes', fieldtype: 'Data')],
);

/// A target whose title field is a Phone field, a type Desk does not search.
DocTypeMeta _phoneMeta(String name) => DocTypeMeta(
  name: name,
  titleField: 'phone_no',
  fields: [DocField(fieldname: 'phone_no', fieldtype: 'Phone')],
);

DocTypeMeta _meta(String name) => switch (name) {
  'Plain Code' => _plainMeta(name),
  'Phone Code' => _phoneMeta(name),
  _ => _codeMeta(name),
};

/// Creates the local mirror of [meta] the way a pull does, with [rows].
Future<void> _seedLocal(
  Database db,
  DocTypeMeta meta,
  String table,
  List<Map<String, Object?>> rows,
) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS doctype_meta (
      doctype TEXT PRIMARY KEY,
      modified TEXT,
      serverModifiedAt TEXT,
      isMobileForm INTEGER NOT NULL DEFAULT 0,
      metaJson TEXT NOT NULL,
      groupName TEXT,
      sortOrder INTEGER
    )
  ''');
  for (final s in doctypeMetaExtensionsDDL()) {
    try {
      await db.execute(s);
    } on DatabaseException {
      // Column already added by an earlier seed in this test.
    }
  }
  for (final s in systemTablesDDL()) {
    await db.execute(s);
  }
  for (final s in buildParentSchemaDDL(meta, tableName: table)) {
    await db.execute(s);
  }
  await db.insert('doctype_meta', {
    'doctype': meta.name,
    'metaJson': jsonEncode(meta.toJson()),
    'isMobileForm': 0,
    'table_name': table,
  });
  var i = 0;
  for (final row in rows) {
    i++;
    await db.insert(table, {
      'mobile_uuid': 'uuid-$i',
      'sync_status': 'synced',
      'local_modified': i,
      ...row,
      for (final f in meta.normFieldNames)
        if (row[f] is String)
          '${f}__norm': normalizeForSearch(row[f] as String),
    });
  }
}

DocTypeMeta _codeMeta(String name) => DocTypeMeta(
  name: name,
  titleField: 'product_code',
  searchFields: const [
    'product_code',
    'brand_name',
    'category_name',
    'ghost_field',
  ],
  fields: [
    DocField(fieldname: 'product_code', fieldtype: 'Data'),
    DocField(fieldname: 'brand_name', fieldtype: 'Link'),
    DocField(fieldname: 'category_name', fieldtype: 'Data'),
    DocField(fieldname: 'is_active', fieldtype: 'Check'),
  ],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late _Server server;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    server = _Server([
      {'name': '9009', 'product_code': 'XACM0WIDGIT'},
      {'name': '4205', 'product_code': 'ACME0WIDGET'},
    ]);
  });

  tearDown(() async => db.close());

  LinkOptionService service({
    bool offline = false,
    bool withClient = true,
    LinkSearchPolicy policy = const LinkSearchPolicy(),
    Stream<void>? syncComplete,
  }) {
    final resolver = UnifiedResolver(
      db: db,
      metaDao: DoctypeMetaDao(db),
      isOnline: () => true,
      backgroundFetch: (_, _) async {},
      metaResolver: (n) async => _meta(n),
      offlineMode: OfflineMode(enabled: offline, isPersisted: true),
      client: withClient
          ? FrappeClient('http://localhost', httpClient: server)
          : null,
    );
    return LinkOptionService(
      resolver,
      (n) async => _meta(n),
      searchPolicy: policy,
      syncComplete$: syncComplete,
    );
  }

  group('usesServerSearch', () {
    test('online-first with a client and the default policy: true', () {
      expect(service().usesServerSearch('Product Code'), isTrue);
    });

    test('offline-first: false, the local list is kept', () {
      expect(service(offline: true).usesServerSearch('Product Code'), isFalse);
    });

    test('policy disabled: false', () {
      expect(
        service(
          policy: LinkSearchPolicy.disabled,
        ).usesServerSearch('Product Code'),
        isFalse,
      );
    });

    test('doctype opted out: false for it, true for others', () {
      final svc = service(
        policy: const LinkSearchPolicy(prefetchOnlyDoctypes: {'Product Code'}),
      );
      expect(svc.usesServerSearch('Product Code'), isFalse);
      expect(svc.usesServerSearch('Regions'), isTrue);
    });

    test('withoutResolver (subclass that overrides getLinkOptions): false', () {
      expect(
        LinkOptionService.withoutResolver().usesServerSearch('Product Code'),
        isFalse,
      );
    });
  });

  group('searchLinkOptions', () {
    test('matches the text across name, title and real search fields, ANDed '
        'with the link filters, one page', () async {
      await service().searchLinkOptions(
        'Product Code',
        txt: 'ACME0WID',
        pageLength: 20,
        filters: [
          ['Product Code', 'is_active', '=', 1],
        ],
      );
      expect(server.seen, hasLength(1));
      final q = server.seen.single.queryParameters;
      expect(q['doctype'], 'Product Code');
      expect(q['limit_page_length'], '20');
      expect(jsonDecode(q['filters']!), [
        ['is_active', '=', 1],
      ]);
      // ghost_field is not a field of the doctype: sending it would make
      // Frappe refuse the whole query (417).
      expect(jsonDecode(q['or_filters']!), [
        ['name', 'like', '%ACME0WID%'],
        ['product_code', 'like', '%ACME0WID%'],
        ['brand_name', 'like', '%ACME0WID%'],
        ['category_name', 'like', '%ACME0WID%'],
      ]);
    });

    test('empty text is the first page: no or_filters', () async {
      await service().searchLinkOptions(
        'Product Code',
        txt: '',
        pageLength: 10,
      );
      final q = server.seen.single.queryParameters;
      expect(q['limit_page_length'], '10');
      expect(q.containsKey('or_filters'), isFalse);
    });

    test('labels come from the title field, as getLinkOptions builds them; '
        'docnames starting with the text come first', () async {
      server = _Server([
        {'name': '9009', 'product_code': 'X420'},
        {'name': '4205', 'product_code': 'ACME0WIDGET'},
      ]);
      final out = await service().searchLinkOptions(
        'Product Code',
        txt: '420',
        pageLength: 20,
      );
      expect(out.map((o) => o.name), ['4205', '9009']);
      expect(out.first.label, 'ACME0WIDGET');
    });

    test('a full page also asks for exact matches, so an exact match older '
        'than the page is returned, first', () async {
      // The LIKE request answers with the 20 most recently modified matches,
      // none of them the exact one; only the `=` request finds it.
      server = _Server.answering((url) {
        final or = _orFilters(url);
        if (or.isNotEmpty && or.every((c) => (c as List)[1] == '=')) {
          return [
            {'name': 'ACME', 'product_code': 'OLDEST'},
          ];
        }
        return [
          for (var i = 0; i < 19; i++)
            {'name': 'X-ACME-$i', 'product_code': 'P$i'},
          {'name': 'ACME-PREFIX', 'product_code': 'P19'},
        ];
      });
      final out = await service().searchLinkOptions(
        'Product Code',
        txt: 'ACME',
        pageLength: 20,
        filters: [
          ['Product Code', 'is_active', '=', 1],
        ],
      );
      expect(server.seen, hasLength(2));
      final exact = server.seen.last.queryParameters;
      expect(jsonDecode(exact['or_filters']!), [
        ['name', '=', 'ACME'],
        ['product_code', '=', 'ACME'],
        ['brand_name', '=', 'ACME'],
        ['category_name', '=', 'ACME'],
      ]);
      // Both requests keep the link filters.
      for (final url in server.seen) {
        expect(jsonDecode(url.queryParameters['filters']!), [
          ['is_active', '=', 1],
        ]);
      }
      // Exact match first, then the docname prefix, then the rest; one page.
      expect(out.first.name, 'ACME');
      expect(out[1].name, 'ACME-PREFIX');
      expect(out, hasLength(20));
    });

    test(
      'a page that is not full holds every match: no exact request',
      () async {
        await service().searchLinkOptions(
          'Product Code',
          txt: 'ACME',
          pageLength: 20,
        );
        expect(server.seen, hasLength(1));
      },
    );

    test(
      'an exact docname or title match ranks before docname prefixes',
      () async {
        server = _Server([
          {'name': '4205-B', 'product_code': 'Z1'},
          {'name': '9009', 'product_code': '4205'},
          {'name': '4205', 'product_code': 'Z2'},
        ]);
        final out = await service().searchLinkOptions(
          'Product Code',
          txt: '4205',
          pageLength: 20,
        );
        expect(out.map((o) => o.name), ['9009', '4205', '4205-B']);
      },
    );
  });

  group('first page', () {
    test('concurrent pickers on the same target share one request, and a '
        'remount within the TTL reuses it', () async {
      final svc = service();
      await Future.wait([
        svc.searchLinkOptions('Product Code', txt: '', pageLength: 10),
        svc.searchLinkOptions('Product Code', txt: '', pageLength: 10),
      ]);
      await svc.searchLinkOptions('Product Code', txt: '', pageLength: 10);
      expect(server.seen, hasLength(1));
    });

    test('different filters are different first pages', () async {
      final svc = service();
      await svc.searchLinkOptions('Product Code', txt: '', pageLength: 10);
      await svc.searchLinkOptions(
        'Product Code',
        txt: '',
        pageLength: 10,
        filters: [
          ['Product Code', 'is_active', '=', 1],
        ],
      );
      expect(server.seen, hasLength(2));
    });

    test('typed searches are never cached', () async {
      final svc = service();
      await svc.searchLinkOptions('Product Code', txt: 'ACME', pageLength: 20);
      await svc.searchLinkOptions('Product Code', txt: 'ACME', pageLength: 20);
      expect(server.seen, hasLength(2));
    });

    test('a finished sync drops the cached first pages', () async {
      final sync = StreamController<void>.broadcast();
      addTearDown(sync.close);
      final svc = service(syncComplete: sync.stream);
      await svc.searchLinkOptions('Product Code', txt: '', pageLength: 10);
      sync.add(null);
      await Future<void>.delayed(Duration.zero);
      await svc.searchLinkOptions('Product Code', txt: '', pageLength: 10);
      expect(server.seen, hasLength(2));
    });

    test('a finished sync drops the cached first pages when the sync stream '
        'is single-subscription', () async {
      final sync = StreamController<void>();
      // Not awaited: a single-subscription stream nobody listens to never
      // completes its close.
      addTearDown(() => unawaited(sync.close()));
      final svc = service(syncComplete: sync.stream);
      await svc.searchLinkOptions('Product Code', txt: '', pageLength: 10);
      sync.add(null);
      await Future<void>.delayed(Duration.zero);
      await svc.searchLinkOptions('Product Code', txt: '', pageLength: 10);
      expect(server.seen, hasLength(2));
    });

    test('a single-subscription sync stream still reaches every picker that '
        'listens to syncComplete\$', () async {
      final sync = StreamController<void>();
      addTearDown(() => unawaited(sync.close()));
      final svc = service(syncComplete: sync.stream);
      var first = 0;
      var second = 0;
      final a = svc.syncComplete$!.listen((_) => first++);
      final b = svc.syncComplete$!.listen((_) => second++);
      addTearDown(a.cancel);
      addTearDown(b.cancel);
      sync.add(null);
      await Future<void>.delayed(Duration.zero);
      expect([first, second], [1, 1]);
    });
  });

  group('offline mode switched on: searches the device', () {
    final rows = <Map<String, Object?>>[
      {
        'server_name': '4205',
        'product_code': 'ACME0WIDGET',
        'brand_name': 'Brand Alpha',
        'category_name': 'Tools',
      },
      {
        'server_name': '9009',
        'product_code': 'ZX-1',
        'brand_name': 'Brand Beta',
        'category_name': 'Gadgets',
      },
      {
        'server_name': '7001',
        'product_code': 'QR-2',
        'brand_name': 'Brand Gamma',
        'category_name': 'Parts',
      },
    ];

    Future<List<String>> search(
      String txt, {
      String doctype = 'Product Code',
    }) async {
      final out = await service(
        offline: true,
      ).searchLinkOptions(doctype, txt: txt, pageLength: 20);
      return out.map((o) => o.name).toList();
    }

    setUp(() async {
      await _seedLocal(
        db,
        _codeMeta('Product Code'),
        'docs__product_code',
        rows,
      );
    });

    test('never sends a server-shaped query, and returns only the rows '
        'whose title matches', () async {
      expect(await search('ACME0'), ['4205']);
      expect(server.seen, isEmpty);
    });

    test('matches the docname', () async {
      expect(await search('9009'), ['9009']);
    });

    test('matches a search_fields column', () async {
      expect(await search('gadget'), ['9009']);
      expect(await search('gamma'), ['7001']);
    });

    test('a target with no title field is still filtered by docname', () async {
      await _seedLocal(db, _plainMeta('Plain Code'), 'docs__plain_code', [
        {'server_name': 'PLAIN-1', 'notes': 'first'},
        {'server_name': 'OTHER-2', 'notes': 'second'},
      ]);
      expect(await search('plain', doctype: 'Plain Code'), ['PLAIN-1']);
    });

    test('a title field of a type Desk does not search is still matched, as '
        'before', () async {
      await _seedLocal(db, _phoneMeta('Phone Code'), 'docs__phone_code', [
        {'server_name': 'PH-1', 'phone_no': 'TEL-0001'},
        {'server_name': 'PH-2', 'phone_no': 'TEL-0002'},
      ]);
      expect(await search('0002', doctype: 'Phone Code'), ['PH-2']);
    });
  });

  group('a failed request reaches the caller as an error, never as an empty '
      'list (the picker falls back to the full list only on an error)', () {
    Future<Object?> errorOf(http.BaseClient client) async {
      final resolver = UnifiedResolver(
        db: db,
        metaDao: DoctypeMetaDao(db),
        isOnline: () => true,
        backgroundFetch: (_, _) async {},
        metaResolver: (n) async => _meta(n),
        offlineMode: const OfflineMode(enabled: false, isPersisted: true),
        client: FrappeClient('http://localhost', httpClient: client),
      );
      final svc = LinkOptionService(resolver, (n) async => _meta(n));
      try {
        await svc.searchLinkOptions(
          'Product Code',
          txt: 'ACME',
          pageLength: 20,
        );
        return null;
      } catch (e) {
        return e;
      }
    }

    test('connection dropped', () async {
      expect(await errorOf(_Failing.dropped()), isNotNull);
    });

    test('HTTP 417 (a refused search column)', () async {
      expect(await errorOf(_Failing.status(417)), isNotNull);
    });

    test('HTTP 500', () async {
      expect(await errorOf(_Failing.status(500)), isNotNull);
    });
  });

  test('searchColumnsFor keeps name, then real searchable fields once', () {
    expect(LinkOptionService.searchColumnsFor(_codeMeta('Product Code')), [
      'name',
      'product_code',
      'brand_name',
      'category_name',
    ]);
  });
}
