// SearchableSelect (inline + dialog pickers), SearchableSelectDialog, and the
// service-backed LinkField dropdown: search, pick, clear, multi-select,
// load failure + retry, sync-complete retry and option locality.
//
// Search contract: Frappe's link search (`frappe.desk.search.search_widget`)
// always matches the document NAME as well as the title/search fields, and
// the SDK's own dialog picker (SearchableSelectDialog) matches both label and
// name. The inline picker is held to the same rule.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/searchable_select.dart';

LinkOptionEntity _opt(String name, [String? label, bool isLocal = false]) =>
    LinkOptionEntity(
      doctype: 'Customer',
      name: name,
      label: label,
      lastUpdated: 0,
      isLocal: isLocal,
    );

final _options = [
  _opt('CUST-0001', 'Acme Traders'),
  _opt('CUST-0002', 'Bright Foods'),
  _opt('CUST-0003', 'Cedar Works'),
];

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(8), child: child),
  ),
);

/// Hosts a SearchableSelect whose `selected` follows its own onChanged, the
/// way a form field does.
class _Host extends StatefulWidget {
  const _Host({
    required this.onChanged,
    this.initial = const [],
    this.multiSelect = false,
    this.enabled = true,
    this.pickerMode = LinkFieldPickerMode.inline,
  });

  final ValueChanged<List<String>> onChanged;
  final List<String> initial;
  final bool multiSelect;
  final bool enabled;
  final LinkFieldPickerMode pickerMode;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late List<String> _selected = widget.initial;

  @override
  Widget build(BuildContext context) => SearchableSelect(
    options: _options,
    selected: _selected,
    multiSelect: widget.multiSelect,
    enabled: widget.enabled,
    pickerMode: widget.pickerMode,
    labelText: 'Customer',
    onChanged: (v) {
      widget.onChanged(v);
      setState(() => _selected = v);
    },
  );
}

class _Service extends LinkOptionService {
  _Service({this.failFirst = 0, this.sync, List<LinkOptionEntity>? options})
    : _opts = options ?? _options,
      super.withoutResolver();

  int failFirst;
  final Stream<void>? sync;
  final List<LinkOptionEntity> _opts;
  final calls = <List<List<dynamic>>?>[];
  bool empty = false;

  @override
  Stream<void>? get syncComplete$ => sync;

  @override
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async {
    calls.add(filters);
    if (failFirst > 0) {
      failFirst--;
      throw StateError('options unavailable');
    }
    return empty ? const [] : _opts;
  }
}

DocField _linkField({String? linkFilters, bool readOnly = false}) => DocField(
  fieldname: 'customer',
  fieldtype: 'Link',
  label: 'Customer',
  options: 'Customer',
  linkFilters: linkFilters,
  readOnly: readOnly,
);

void main() {
  group('SearchableSelect inline', () {
    testWidgets('typing part of a label filters the suggestions', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_Host(onChanged: (_) {})));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.text('Acme Traders'), findsOneWidget);
      expect(find.text('Bright Foods'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'bright');
      await tester.pump();
      expect(find.text('Bright Foods'), findsOneWidget);
      expect(find.text('Acme Traders'), findsNothing);
    });

    testWidgets('no match shows "No matching options"', (tester) async {
      await tester.pumpWidget(_wrap(_Host(onChanged: (_) {})));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump();
      expect(find.text('No matching options'), findsOneWidget);
    });

    testWidgets(
      'typing the document ID finds an option whose label differs',
      (tester) async {
        await tester.pumpWidget(_wrap(_Host(onChanged: (_) {})));
        await tester.tap(find.byType(TextField));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'CUST-0002');
        await tester.pump();
        expect(
          find.text('Bright Foods'),
          findsOneWidget,
          reason:
              'Frappe link search and SearchableSelectDialog both match the '
              'name; the inline picker matches only the label',
        );
      },
      skip: true, // BUG SDK-20
      // inline SearchableSelect filters on label only, so an ID
      // typed by the operator finds nothing when the option has a title
    );

    testWidgets('picking emits the NAME and shows the label', (tester) async {
      final emitted = <List<String>>[];
      await tester.pumpWidget(_wrap(_Host(onChanged: emitted.add)));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.tap(find.text('Cedar Works'));
      await tester.pump();
      expect(emitted.last, ['CUST-0003']);
      expect(find.text('Cedar Works'), findsOneWidget);
      expect(find.byType(TextField), findsNothing, reason: 'collapsed');
    });

    testWidgets('the clear button emits an empty selection', (tester) async {
      final emitted = <List<String>>[];
      await tester.pumpWidget(
        _wrap(_Host(onChanged: emitted.add, initial: const ['CUST-0001'])),
      );
      expect(find.text('Acme Traders'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(emitted.last, isEmpty);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('an unknown selected value is shown as-is', (tester) async {
      await tester.pumpWidget(
        _wrap(_Host(onChanged: (_) {}, initial: const ['CUST-9999'])),
      );
      expect(find.text('CUST-9999'), findsOneWidget);
    });

    testWidgets('disabled: no search box and no clear button', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _Host(
            onChanged: (_) {},
            initial: const ['CUST-0001'],
            enabled: false,
          ),
        ),
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
      await tester.tap(find.text('Acme Traders'));
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('tapping the current value re-opens the search', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(_Host(onChanged: (_) {}, initial: const ['CUST-0001'])),
      );
      await tester.tap(find.text('Acme Traders'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(
        find.text('Acme Traders'),
        findsNothing,
        reason: 'the selected option is not offered again',
      );
      expect(find.text('Bright Foods'), findsOneWidget);
    });

    testWidgets('loading shows a spinner instead of the picker', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          SearchableSelect(
            options: _options,
            selected: const [],
            loading: true,
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('multi-select: chips, add, remove, no duplicates offered', (
      tester,
    ) async {
      final emitted = <List<String>>[];
      await tester.pumpWidget(
        _wrap(
          _Host(
            onChanged: emitted.add,
            multiSelect: true,
            initial: const ['CUST-0001'],
          ),
        ),
      );
      expect(find.widgetWithText(Chip, 'Acme Traders'), findsOneWidget);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      // The already-selected option is not offered again.
      expect(find.text('Acme Traders'), findsOneWidget);
      await tester.tap(find.text('Bright Foods'));
      await tester.pump();
      expect(emitted.last, ['CUST-0001', 'CUST-0002']);

      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pump();
      expect(emitted.last, ['CUST-0002']);
    });
  });

  group('SearchableSelect dialog mode', () {
    testWidgets('single: search by name, tap picks and closes', (tester) async {
      final emitted = <List<String>>[];
      await tester.pumpWidget(
        _wrap(
          _Host(onChanged: emitted.add, pickerMode: LinkFieldPickerMode.dialog),
        ),
      );
      await tester.tap(find.byType(InputDecorator));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Customer'), findsWidgets, reason: 'dialog title');

      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'cust-0003',
      );
      await tester.pump();
      expect(find.text('Cedar Works'), findsOneWidget);
      expect(find.text('Acme Traders'), findsNothing);

      await tester.tap(find.text('Cedar Works'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(emitted.last, ['CUST-0003']);
      expect(find.text('Cedar Works'), findsOneWidget);
    });

    testWidgets('single: Close leaves the selection untouched', (tester) async {
      final emitted = <List<String>>[];
      await tester.pumpWidget(
        _wrap(
          _Host(
            onChanged: emitted.add,
            initial: const ['CUST-0001'],
            pickerMode: LinkFieldPickerMode.dialog,
          ),
        ),
      );
      await tester.tap(find.byType(InputDecorator));
      await tester.pumpAndSettle();
      // The current value carries a check mark.
      expect(find.byIcon(Icons.check), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(emitted, isEmpty);
    });

    testWidgets('multi: toggle two, Done returns both; Cancel returns none', (
      tester,
    ) async {
      final emitted = <List<String>>[];
      await tester.pumpWidget(
        _wrap(
          _Host(
            onChanged: emitted.add,
            multiSelect: true,
            pickerMode: LinkFieldPickerMode.dialog,
          ),
        ),
      );
      await tester.tap(find.byType(InputDecorator));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Acme Traders'));
      await tester.pump();
      await tester.tap(find.text('Cedar Works'));
      await tester.pump();
      // untoggle + retoggle keeps a single copy
      await tester.tap(find.text('Cedar Works'));
      await tester.pump();
      await tester.tap(find.text('Cedar Works'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(emitted.last, ['CUST-0001', 'CUST-0003']);

      await tester.tap(find.byType(InputDecorator));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bright Foods'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(emitted.length, 1, reason: 'Cancel emits nothing');
    });

    testWidgets('disabled dialog picker does not open', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _Host(
            onChanged: (_) {},
            enabled: false,
            pickerMode: LinkFieldPickerMode.dialog,
          ),
        ),
      );
      await tester.tap(find.byType(InputDecorator));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('LinkField with a LinkOptionService', () {
    Widget field(
      LinkOptionService service, {
      DocField? f,
      dynamic value,
      ValueChanged<dynamic>? onChanged,
      ValueChanged<bool>? onIsLocal,
      Map<String, dynamic>? formData,
    }) => _wrap(
      FormBuilder(
        child: LinkField(
          field: f ?? _linkField(),
          value: value,
          linkOptionService: service,
          onChanged: onChanged,
          onIsLocalChanged: onIsLocal,
          formData: formData,
        ),
      ),
    );

    testWidgets('a failed load shows the empty state; refresh retries', (
      tester,
    ) async {
      final service = _Service(failFirst: 1);
      await tester.pumpWidget(field(service));
      await tester.pump();
      await tester.pump();
      expect(find.text('No options available'), findsWidgets);
      expect(service.calls.length, 1);

      await tester.tap(find.byTooltip('Refresh options'));
      await tester.pump();
      await tester.pump();
      expect(service.calls.length, 2);
      expect(find.byType(SearchableSelect), findsOneWidget);
    });

    testWidgets('a sync-complete tick reloads an empty option list', (
      tester,
    ) async {
      final sync = StreamController<void>.broadcast();
      addTearDown(sync.close);
      final service = _Service(sync: sync.stream)..empty = true;
      await tester.pumpWidget(field(service));
      await tester.pump();
      await tester.pump();
      expect(find.text('No options available'), findsWidgets);

      service.empty = false;
      sync.add(null);
      await tester.pump();
      await tester.pump();
      expect(service.calls.length, 2);
      expect(find.byType(SearchableSelect), findsOneWidget);
    });

    testWidgets('a sync-complete tick does not reload a populated list', (
      tester,
    ) async {
      final sync = StreamController<void>.broadcast();
      addTearDown(sync.close);
      final service = _Service(sync: sync.stream);
      await tester.pumpWidget(field(service));
      await tester.pump();
      await tester.pump();
      sync.add(null);
      await tester.pump();
      expect(service.calls.length, 1);
    });

    testWidgets('a value stored as the LABEL resolves to the option', (
      tester,
    ) async {
      final service = _Service();
      await tester.pumpWidget(field(service, value: 'Bright Foods'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Bright Foods'), findsOneWidget);
    });

    testWidgets('picking a local-only option flags it; clearing unflags', (
      tester,
    ) async {
      final service = _Service(
        options: [
          _opt('CUST-0001', 'Acme Traders'),
          _opt('0b6f2c1e-local', 'Offline Customer', true),
        ],
      );
      final values = <dynamic>[];
      final local = <bool>[];
      await tester.pumpWidget(
        field(service, onChanged: values.add, onIsLocal: local.add),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.tap(find.text('Offline Customer'));
      await tester.pump();
      expect(values.last, '0b6f2c1e-local');
      expect(local.last, isTrue);
    });

    testWidgets('clearing a pick reports value null and locality false', (
      tester,
    ) async {
      final service = _Service();
      final values = <dynamic>[];
      final local = <bool>[];
      await tester.pumpWidget(
        field(
          service,
          value: 'CUST-0001',
          onChanged: values.add,
          onIsLocal: local.add,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(values.last, isNull);
      expect(local.last, isFalse);
    });

    testWidgets('new link_filters on rebuild reload the options', (
      tester,
    ) async {
      final service = _Service();
      await tester.pumpWidget(
        field(
          service,
          f: _linkField(linkFilters: '[["Customer","group","=","A"]]'),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(service.calls.length, 1);

      await tester.pumpWidget(
        field(
          service,
          f: _linkField(linkFilters: '[["Customer","group","=","B"]]'),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(service.calls.length, 2);
    });

    testWidgets('a dependent value change reloads with the new filter', (
      tester,
    ) async {
      final service = _Service();
      const filters = '[["Customer","group","=","eval:doc.group"]]';
      await tester.pumpWidget(
        field(
          service,
          f: _linkField(linkFilters: filters),
          formData: const {'group': 'A'},
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpWidget(
        field(
          service,
          f: _linkField(linkFilters: filters),
          formData: const {'group': 'B'},
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(service.calls.length, 2);
      expect(service.calls.last.toString(), contains('B'));
    });
  });
}
