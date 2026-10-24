import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/searchable_select.dart';

LinkOptionEntity _opt(String name, [String? label]) => LinkOptionEntity(
  doctype: 'Product Code',
  name: name,
  label: label ?? name,
  lastUpdated: 0,
);

/// Ten first-page options; the wanted row is not among them.
final List<LinkOptionEntity> _page = [
  for (var i = 0; i < 10; i++) _opt('IT-0000$i', 'ITEM000000$i'),
];

class _Search {
  final List<String> calls = [];
  final Map<String, Completer<List<LinkOptionEntity>>> pending = {};
  Future<List<LinkOptionEntity>> call(String text) {
    calls.add(text);
    return (pending[text] = Completer<List<LinkOptionEntity>>()).future;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required _Search search,
  List<LinkOptionEntity>? options,
  bool complete = false,
  List<String> picked = const [],
  void Function(List<String>)? onChanged,
  void Function(LinkOptionEntity)? onPickOption,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SearchableSelect(
        options: options ?? _page,
        selected: picked,
        onChanged: onChanged ?? (_) {},
        onSearch: search.call,
        searchDebounce: const Duration(milliseconds: 500),
        searchMinChars: 2,
        optionsComplete: complete,
        onPickOption: onPickOption,
      ),
    ),
  ),
);

Future<void> _type(WidgetTester tester, String text) async {
  await tester.tap(find.byType(TextField));
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
}

void main() {
  testWidgets('one request after the pause, not one per keystroke', (
    tester,
  ) async {
    final search = _Search();
    await _pump(tester, search: search);
    for (final t in ['AC', 'ACM', 'ACME', 'ACME0', 'ACME0W']) {
      await _type(tester, t);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(search.calls, isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    expect(search.calls, ['ACME0W']);
    expect(find.text('Searching...'), findsOneWidget);
    search.pending['ACME0W']!.complete([_opt('4205', 'ACME0WIDGET')]);
    await tester.pump();
    expect(find.text('ACME0WIDGET'), findsOneWidget);
    expect(find.text('No matching options'), findsNothing);
  });

  testWidgets('below minChars: no request', (tester) async {
    final search = _Search();
    await _pump(tester, search: search);
    await _type(tester, 'B');
    await tester.pump(const Duration(seconds: 1));
    expect(search.calls, isEmpty);
  });

  testWidgets('an exact DOCNAME match on the first page: no request, and the '
      'row is shown', (tester) async {
    final search = _Search();
    await _pump(tester, search: search);
    await _type(tester, 'it-00003');
    await tester.pump(const Duration(seconds: 1));
    expect(search.calls, isEmpty);
    expect(find.text('ITEM0000003'), findsOneWidget);
  });

  testWidgets('an exact LABEL match still searches: labels repeat, and a '
      'namesake can be past the first page', (tester) async {
    final search = _Search();
    await _pump(tester, search: search);
    await _type(tester, 'item0000003');
    await tester.pump(const Duration(milliseconds: 500));
    expect(search.calls, ['item0000003']);
    search.pending['item0000003']!.complete([
      _opt('IT-00003', 'ITEM0000003'),
      _opt('IT-99003', 'ITEM0000003 (second copy)'),
    ]);
    await tester.pump();
    expect(find.text('ITEM0000003'), findsOneWidget);
    expect(find.text('ITEM0000003 (second copy)'), findsOneWidget);
  });

  testWidgets('an empty server reply never hides the local matches', (
    tester,
  ) async {
    final search = _Search();
    await _pump(tester, search: search);
    await _type(tester, 'ITEM000000');
    await tester.pump(const Duration(milliseconds: 500));
    search.pending['ITEM000000']!.complete(const []);
    await tester.pump();
    expect(find.text('ITEM0000001'), findsOneWidget);
    expect(find.text('No matching options'), findsNothing);
  });

  testWidgets('new filters (searchScope) drop the cached rows and search '
      'again; a new options list alone keeps a reply in flight', (
    tester,
  ) async {
    final search = _Search();
    Widget build(Object scope, List<LinkOptionEntity> options) => MaterialApp(
      home: Scaffold(
        body: SearchableSelect(
          options: options,
          selected: const [],
          onChanged: (_) {},
          onSearch: search.call,
          searchDebounce: const Duration(milliseconds: 500),
          optionsComplete: false,
          searchScope: scope,
        ),
      ),
    );
    await tester.pumpWidget(build('group=X', _page));
    await _type(tester, 'ACME');
    await tester.pump(const Duration(milliseconds: 500));
    // Same filters, new list instance (e.g. a picked row was kept).
    await tester.pumpWidget(build('group=X', [..._page]));
    search.pending['ACME']!.complete([_opt('77', 'ACME0OLD')]);
    await tester.pump();
    expect(find.text('ACME0OLD'), findsOneWidget);
    // Filters changed: the X rows are wrong now and the text is re-searched.
    await tester.pumpWidget(build('group=Y', _page));
    await tester.pump();
    expect(find.text('ACME0OLD'), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    expect(search.calls, ['ACME', 'ACME']);
  });

  testWidgets('a complete first page: no request, and the old empty state', (
    tester,
  ) async {
    final search = _Search();
    await _pump(tester, search: search, complete: true);
    await _type(tester, 'ACME0WIDGET');
    await tester.pump(const Duration(seconds: 1));
    expect(search.calls, isEmpty);
    expect(find.text('No matching options'), findsOneWidget);
  });

  testWidgets('a partial match on a truncated page still searches, and the '
      'local rows show meanwhile', (tester) async {
    final search = _Search();
    await _pump(tester, search: search);
    await _type(tester, 'ITEM');
    expect(find.text('ITEM0000001'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(search.calls, ['ITEM']);
    search.pending['ITEM']!.complete([_opt('77', 'ITEM0099999')]);
    await tester.pump();
    // The server's row first; the local matches stay below it.
    expect(find.text('ITEM0099999'), findsOneWidget);
    expect(find.text('ITEM0000001'), findsOneWidget);
  });

  testWidgets('a slow reply to an older text never replaces a newer one', (
    tester,
  ) async {
    final search = _Search();
    await _pump(tester, search: search);
    await _type(tester, 'ACME');
    await tester.pump(const Duration(milliseconds: 500));
    await _type(tester, 'ACME0WID');
    await tester.pump(const Duration(milliseconds: 500));
    expect(search.calls, ['ACME', 'ACME0WID']);
    search.pending['ACME0WID']!.complete([_opt('4205', 'ACME0WIDGET')]);
    await tester.pump();
    search.pending['ACME']!.complete([_opt('2', 'ACME0OLDROW')]);
    await tester.pump();
    expect(find.text('ACME0WIDGET'), findsOneWidget);
    expect(find.text('ACME0OLDROW'), findsNothing);
  });

  testWidgets('a failed search says so and keeps the text; retry searches', (
    tester,
  ) async {
    final search = _Search();
    await _pump(tester, search: search);
    await _type(tester, 'ACME0WID');
    await tester.pump(const Duration(milliseconds: 500));
    search.pending['ACME0WID']!.completeError(Exception('offline'));
    await tester.pump();
    expect(find.text('Search failed. Tap to retry'), findsOneWidget);
    expect(find.text('No matching options'), findsNothing);
    expect(find.text('ACME0WID'), findsOneWidget); // the typed text
    await tester.tap(find.text('Search failed. Tap to retry'));
    await tester.pump();
    expect(search.calls, ['ACME0WID', 'ACME0WID']);
  });

  testWidgets('picking a searched row reports the option, then its name', (
    tester,
  ) async {
    final search = _Search();
    final events = <String>[];
    await _pump(
      tester,
      search: search,
      onPickOption: (o) => events.add('option:${o.name}'),
      onChanged: (v) => events.add('changed:${v.join()}'),
    );
    await _type(tester, 'ACME0WID');
    await tester.pump(const Duration(milliseconds: 500));
    search.pending['ACME0WID']!.complete([_opt('4205', 'ACME0WIDGET')]);
    await tester.pump();
    await tester.tap(find.text('ACME0WIDGET'));
    await tester.pump();
    expect(events, ['option:4205', 'changed:4205']);
  });

  testWidgets('dialog multi-select reports a row picked from the search, so '
      'its chip keeps the label', (tester) async {
    final search = _Search();
    final picked = <String>[];
    var selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SearchableSelect(
              options: _page,
              selected: selected,
              multiSelect: true,
              pickerMode: LinkFieldPickerMode.dialog,
              onChanged: (v) => setState(() => selected = v),
              onSearch: search.call,
              optionsComplete: false,
              onPickOption: (o) => picked.add(o.name),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(InputDecorator));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ACME0WID');
    await tester.pump(const Duration(milliseconds: 500));
    search.pending['ACME0WID']!.complete([_opt('4205', 'ACME0WIDGET')]);
    await tester.pump();
    await tester.tap(find.text('ACME0WIDGET'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(picked, ['4205']);
    expect(selected, ['4205']);
    expect(find.text('ACME0WIDGET'), findsOneWidget); // the chip
  });

  testWidgets('no onSearch: behaves as before (in-memory only)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchableSelect(
            options: _page,
            selected: const [],
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await _type(tester, 'ACME0WIDGET');
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('No matching options'), findsOneWidget);
    expect(find.text('Searching...'), findsNothing);
  });
}
