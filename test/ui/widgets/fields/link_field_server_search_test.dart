import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

LinkOptionEntity _opt(String name, String label) => LinkOptionEntity(
  doctype: 'Product Code',
  name: name,
  label: label,
  lastUpdated: 0,
);

/// A policy holding page sizes below the minimums [LinkSearchPolicy] asserts.
/// A release build has no asserts, so `LinkSearchPolicy(pageLength: 0)`
/// holds exactly this there; implementing the class skips the assert here.
class _UncheckedPolicy implements LinkSearchPolicy {
  const _UncheckedPolicy({
    required this.prefetchSize,
    required this.pageLength,
  });

  @override
  final int prefetchSize;
  @override
  final int pageLength;
  @override
  bool get enabled => true;
  @override
  int get minChars => 2;
  @override
  Duration get debounce => const Duration(milliseconds: 100);
  @override
  Set<String> get prefetchOnlyDoctypes => const {};
}

/// A service in server-search mode that records every call.
class _ServerSearchService extends LinkOptionService {
  _ServerSearchService({
    required this.firstPage,
    this.results = const [],
    this.policy = const LinkSearchPolicy(debounce: Duration(milliseconds: 100)),
  }) : super.withoutResolver();

  final List<LinkOptionEntity> firstPage;
  final List<LinkOptionEntity> results;
  final LinkSearchPolicy policy;
  final List<String> searches = [];
  final List<int> pageLengths = [];
  int prefetches = 0;
  final Map<String, String> titles = {};

  @override
  LinkSearchPolicy get searchPolicy => policy;

  @override
  bool usesServerSearch(String doctype) => true;

  @override
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async {
    prefetches++;
    return const [];
  }

  @override
  Future<List<LinkOptionEntity>> searchLinkOptions(
    String doctype, {
    required String txt,
    required int pageLength,
    List<List<dynamic>>? filters,
  }) async {
    searches.add(txt);
    pageLengths.add(pageLength);
    return txt.isEmpty ? firstPage : results;
  }

  @override
  Future<String?> getLinkTitle(String doctype, String name) async =>
      titles[name];
}

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: FormBuilder(child: child)),
);

DocField _field() => DocField(
  fieldname: 'product_code',
  fieldtype: 'Link',
  label: 'Code',
  options: 'Product Code',
);

final List<LinkOptionEntity> _tenRows = [
  for (var i = 0; i < 10; i++) _opt('$i', 'ITEM000000$i'),
];

void main() {
  testWidgets('loads a 10-row first page via searchLinkOptions, never the '
      'full prefetch', (tester) async {
    final svc = _ServerSearchService(firstPage: _tenRows);
    await tester.pumpWidget(
      _wrap(LinkField(field: _field(), linkOptionService: svc)),
    );
    await tester.pumpAndSettle();
    expect(svc.searches, ['']);
    expect(svc.pageLengths, [10]);
    expect(svc.prefetches, 0);
  });

  testWidgets('typing past the first page finds the row and picks it', (
    tester,
  ) async {
    final svc = _ServerSearchService(
      firstPage: _tenRows,
      results: [_opt('4205', 'ACME0WIDGET')],
    );
    final picked = <dynamic>[];
    await tester.pumpWidget(
      _wrap(
        LinkField(
          field: _field(),
          linkOptionService: svc,
          onChanged: picked.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    // A prefix, so the only "ACME0WIDGET" on screen is the result row.
    await tester.enterText(find.byType(TextField), 'ACME0WID');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(svc.searches, ['', 'ACME0WID']);
    expect(svc.pageLengths.last, 20);
    await tester.tap(find.text('ACME0WIDGET'));
    await tester.pumpAndSettle();
    expect(picked, ['4205']);
    // The picked row is not on the first page; its label must still show.
    expect(find.text('ACME0WIDGET'), findsOneWidget);
    expect(find.text('4205'), findsNothing);
  });

  testWidgets('an empty first page (nothing matches the filters) shows the '
      'same empty state as before, Refresh included', (tester) async {
    final svc = _ServerSearchService(firstPage: const []);
    await tester.pumpWidget(
      _wrap(LinkField(field: _field(), linkOptionService: svc)),
    );
    await tester.pumpAndSettle();
    expect(find.text('No options available'), findsWidgets);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('a whole list returned for the first page (translated doctype) '
      'is filtered in memory, never searched', (tester) async {
    final svc = _ServerSearchService(
      firstPage: [for (var i = 0; i < 15; i++) _opt('T$i', 'Month $i')],
    );
    await tester.pumpWidget(
      _wrap(LinkField(field: _field(), linkOptionService: svc)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Month 14');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(svc.searches, ['']);
    expect(find.text('Month 14'), findsWidgets);
  });

  testWidgets('a value set AFTER the first page loaded, past that page, '
      'shows its title', (tester) async {
    final svc = _ServerSearchService(firstPage: _tenRows)
      ..titles['4205'] = 'ACME0WIDGET';
    await tester.pumpWidget(
      _wrap(LinkField(field: _field(), linkOptionService: svc)),
    );
    await tester.pumpAndSettle();
    // How a client script / fetch_from sets it: through the form's field state.
    tester
        .state<FormBuilderState>(find.byType(FormBuilder))
        .fields['product_code']!
        .didChange('4205');
    await tester.pumpAndSettle();
    expect(find.text('ACME0WIDGET'), findsOneWidget);
    expect(find.text('4205'), findsNothing);
  });

  testWidgets('a single-row first page (complete) still auto-selects', (
    tester,
  ) async {
    final svc = _ServerSearchService(firstPage: [_opt('S-1', 'Only Site')]);
    final picked = <dynamic>[];
    await tester.pumpWidget(
      _wrap(
        LinkField(
          field: _field(),
          linkOptionService: svc,
          onChanged: picked.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(picked, ['S-1']);
  });

  testWidgets('a single search result is not auto-selected', (tester) async {
    final svc = _ServerSearchService(
      firstPage: _tenRows,
      results: [_opt('4205', 'ACME0WIDGET')],
    );
    final picked = <dynamic>[];
    await tester.pumpWidget(
      _wrap(
        LinkField(
          field: _field(),
          linkOptionService: svc,
          onChanged: picked.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'ACME0WID');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(picked, isEmpty);
  });

  group('page sizes below the minimum (release build, asserts off)', () {
    // A full page for the 2 rows the picker asks for.
    final twoRows = [_opt('0', 'ITEM0000000'), _opt('1', 'ITEM0000001')];

    testWidgets('page length 0 is never sent: the first page asks for 2 '
        'rows and a search for 1', (tester) async {
      final svc = _ServerSearchService(
        firstPage: twoRows,
        results: [_opt('4205', 'ACME0WIDGET')],
        policy: const _UncheckedPolicy(prefetchSize: 0, pageLength: 0),
      );
      await tester.pumpWidget(
        _wrap(LinkField(field: _field(), linkOptionService: svc)),
      );
      await tester.pumpAndSettle();
      expect(svc.pageLengths, [2]);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'ACME0WID');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(svc.searches, ['', 'ACME0WID']);
      expect(svc.pageLengths, [2, 1]);
    });

    testWidgets('prefetchSize 0: a full 2-row first page is not taken for '
        'the whole list, so typing still searches the server', (tester) async {
      final svc = _ServerSearchService(
        firstPage: twoRows,
        results: [_opt('4205', 'ACME0WIDGET')],
        policy: const _UncheckedPolicy(prefetchSize: 0, pageLength: 20),
      );
      await tester.pumpWidget(
        _wrap(LinkField(field: _field(), linkOptionService: svc)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'ACME0WID');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(svc.searches, ['', 'ACME0WID']);
    });
  });

  testWidgets('a held value past the first page shows its title, not the '
      'docname', (tester) async {
    final svc = _ServerSearchService(firstPage: _tenRows)
      ..titles['4205'] = 'ACME0WIDGET';
    await tester.pumpWidget(
      _wrap(LinkField(field: _field(), value: '4205', linkOptionService: svc)),
    );
    await tester.pumpAndSettle();
    expect(find.text('ACME0WIDGET'), findsOneWidget);
    expect(find.text('4205'), findsNothing);
  });

  testWidgets('a subclass that only overrides getLinkOptions keeps the full '
      'prefetch', (tester) async {
    final svc = _LegacyService();
    await tester.pumpWidget(
      _wrap(LinkField(field: _field(), linkOptionService: svc)),
    );
    await tester.pumpAndSettle();
    expect(svc.prefetches, 1);
  });

  testWidgets('a service that cannot answer usesServerSearch keeps the '
      'prefetch instead of leaving the picker empty', (tester) async {
    final svc = _UnansweringService();
    await tester.pumpWidget(
      _wrap(LinkField(field: _field(), linkOptionService: svc)),
    );
    await tester.pumpAndSettle();
    expect(svc.prefetches, 1);
    expect(find.byType(TextField), findsOneWidget);
  });

  group('a failed server request falls back to the full list', () {
    testWidgets('first page fails: the full list loads and is filtered in '
        'memory, never searched', (tester) async {
      final svc = _FlakyService(
        firstPage: _tenRows,
        failFirstPage: true,
        fullList: _fullList,
      );
      await tester.pumpWidget(
        _wrap(LinkField(field: _field(), linkOptionService: svc)),
      );
      await tester.pumpAndSettle();
      expect(svc.prefetches, 1);
      await _type(tester, 'ACME0WID');
      expect(find.text('ACME0WIDGET'), findsOneWidget);
      expect(find.textContaining('Search failed'), findsNothing);
      // The whole list is held, so typing never asks the server again.
      expect(svc.searches, ['']);
    });

    testWidgets('first page and full list both fail: the empty state with '
        'Refresh, as before', (tester) async {
      final svc = _FlakyService(
        firstPage: _tenRows,
        failFirstPage: true,
        failFullList: true,
      );
      await tester.pumpWidget(
        _wrap(LinkField(field: _field(), linkOptionService: svc)),
      );
      await tester.pumpAndSettle();
      expect(find.text('No options available'), findsWidgets);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });

    testWidgets('a typed search fails: the full list loads once, the typed '
        'text filters it, and later typing stays on the device', (
      tester,
    ) async {
      final svc = _FlakyService(
        firstPage: _tenRows,
        failSearch: true,
        fullList: _fullList,
      );
      final picked = <dynamic>[];
      await tester.pumpWidget(
        _wrap(
          LinkField(
            field: _field(),
            linkOptionService: svc,
            onChanged: picked.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _type(tester, 'ACME0WID');
      expect(svc.searches, ['', 'ACME0WID']);
      expect(svc.prefetches, 1);
      expect(find.textContaining('Search failed'), findsNothing);
      expect(find.text('ACME0WIDGET'), findsOneWidget);
      // A row past the first page, typed after the fallback: no new request.
      // Part of the label, so the only full label on screen is the row.
      await tester.enterText(find.byType(TextField), '0000014');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(find.text('ITEM0000014'), findsOneWidget);
      expect(svc.searches, ['', 'ACME0WID']);
      expect(svc.prefetches, 1);
      await tester.tap(find.text('ITEM0000014'));
      await tester.pumpAndSettle();
      expect(picked, ['14']);
    });

    testWidgets('a typed search and the full list both fail: the first page '
        'stays and the search says it failed', (tester) async {
      final svc = _FlakyService(
        firstPage: _tenRows,
        failSearch: true,
        failFullList: true,
      );
      await tester.pumpWidget(
        _wrap(LinkField(field: _field(), linkOptionService: svc)),
      );
      await tester.pumpAndSettle();
      await _type(tester, 'ITEM000000');
      expect(find.text('Search failed. Tap to retry'), findsOneWidget);
      // The first page's matches are still listed.
      expect(find.text('ITEM0000003'), findsOneWidget);
      expect(svc.prefetches, 1);
    });

    testWidgets('a typed search fails and the full list comes back empty: the '
        'search still says it failed, and a retry searches again', (
      tester,
    ) async {
      final svc = _FlakyService(firstPage: _tenRows, failSearch: true);
      await tester.pumpWidget(
        _wrap(LinkField(field: _field(), linkOptionService: svc)),
      );
      await tester.pumpAndSettle();
      await _type(tester, 'ITEM000000');
      expect(find.text('Search failed. Tap to retry'), findsOneWidget);
      expect(find.text('ITEM0000003'), findsOneWidget);
      await tester.tap(find.text('Search failed. Tap to retry'));
      await tester.pumpAndSettle();
      expect(svc.searches, ['', 'ITEM000000', 'ITEM000000']);
    });
  });
}

/// A server-searched target whose first page and/or typed searches fail, as on
/// a dropped connection, while the full list may still load.
class _FlakyService extends _ServerSearchService {
  _FlakyService({
    required super.firstPage,
    this.failFirstPage = false,
    this.failSearch = false,
    this.failFullList = false,
    this.fullList = const [],
  });

  final bool failFirstPage;
  final bool failSearch;
  final bool failFullList;
  final List<LinkOptionEntity> fullList;

  @override
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async {
    prefetches++;
    if (failFullList) throw Exception('connection reset');
    return fullList;
  }

  @override
  Future<List<LinkOptionEntity>> searchLinkOptions(
    String doctype, {
    required String txt,
    required int pageLength,
    List<List<dynamic>>? filters,
  }) async {
    searches.add(txt);
    pageLengths.add(pageLength);
    if (txt.isEmpty ? failFirstPage : failSearch) {
      throw Exception('connection reset');
    }
    return txt.isEmpty ? firstPage : results;
  }
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.tap(find.byType(TextField));
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pumpAndSettle();
}

final List<LinkOptionEntity> _fullList = [
  ..._tenRows,
  for (var i = 10; i < 15; i++) _opt('$i', 'ITEM00000$i'),
  _opt('4205', 'ACME0WIDGET'),
];

/// A host double that cannot answer the new question, like an unstubbed
/// mocktail `implements LinkOptionService` (it returns null, which throws).
class _UnansweringService extends _LegacyService {
  @override
  bool usesServerSearch(String doctype) => throw TypeError(); // what `null as bool` raises
}

class _LegacyService extends LinkOptionService {
  _LegacyService() : super.withoutResolver();
  int prefetches = 0;

  @override
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async {
    prefetches++;
    return _tenRows;
  }
}
