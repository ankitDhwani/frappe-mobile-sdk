import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';
import '../../../models/doc_field.dart';
import '../../../models/link_filter_result.dart';
import '../../../services/link_option_service.dart';
import '../../../services/link_field_coordinator.dart';
import '../../../database/entities/link_option_entity.dart';
import '../../../utils/frappe_reserved_fields.dart';
import '../../../utils/sdk_log.dart';
import '../../../utils/uuid_pattern.dart';
import 'field_helpers.dart';
import 'searchable_select.dart';

/// Widget for Link field type with cached options
class LinkField extends BaseField {
  final LinkOptionService? linkOptionService;
  final LinkFieldCoordinator? linkFieldCoordinator;
  final List<String>? options;
  final Map<String, dynamic>? formData;
  final Map<String, dynamic> parentFormData;
  final LinkFilterBuilder? Function(String doctype, String fieldname)?
  getLinkFilterBuilder;

  /// Fires whenever the picked option's locality changes, including on
  /// clear (false). Wires the `<field>__is_local` companion in the host
  /// form data so [UuidRewriter] can rewrite the value at push time.
  final ValueChanged<bool>? onIsLocalChanged;

  /// When false, the single-option preselect never fires for this field.
  /// `FieldFactory` sets it from [isFrappeReservedField]. The Link fields
  /// this actually protects are the framework-owned ones — `amended_from`
  /// (`options: self`, `read_only`), `auto_repeat` (`options: Auto Repeat`,
  /// `read_only`) and the `is_tree` `parent_<scrubbed doctype>` Link, which
  /// is neither hidden nor read-only and so is the one that would otherwise
  /// silently acquire a parent the user never picked. Defaults to true so a
  /// host constructing this widget directly keeps the previous behaviour.
  final bool allowPreselect;

  const LinkField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
    this.linkOptionService,
    this.linkFieldCoordinator,
    this.options,
    this.formData,
    this.parentFormData = const {},
    this.getLinkFilterBuilder,
    this.onIsLocalChanged,
    this.allowPreselect = true,
  });

  @override
  Widget buildField(BuildContext context) {
    // If options are provided directly, use them
    if (options != null && options!.isNotEmpty) {
      // Deduplicated, order-preserving. [options] is a `createField` parameter
      // the SDK never populates itself, so the list is whatever the host
      // passed — and `DropdownButton` asserts when two `DropdownMenuItem`s
      // share the value it is showing ("There should be exactly one item with
      // [DropdownButton]'s value"). Deduping also restores the preselect for a
      // sole option written twice: the count is 1 again, not 2. Mirrors
      // `SelectField._getRawOptions`.
      final staticOptions = LinkedHashSet<String>.of(options!).toList();
      // Validate initialValue is in options list
      final initialValueStr = value?.toString();
      String? validInitialValue;
      if (initialValueStr != null && initialValueStr.isNotEmpty) {
        if (staticOptions.contains(initialValueStr)) {
          validInitialValue = initialValueStr;
        } else {
          // Value not in options - use null
          validInitialValue = null;
        }
      }

      // Auto-select when exactly one option and no valid selection.
      // Propagate `onIsLocalChanged` so an auto-picked UUID-shaped
      // option (offline mobile_uuid) flips `<field>__is_local` for
      // UuidRewriter at push time — matches `_applyOptionsAndAutoSelect`.
      if (staticOptions.length == 1 &&
          (validInitialValue == null || validInitialValue.isEmpty) &&
          allowPreselect &&
          enabled &&
          !field.readOnly) {
        validInitialValue = staticOptions.first;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onChanged?.call(staticOptions.first);
          onIsLocalChanged?.call(looksLikeMobileUuid(staticOptions.first));
        });
      }

      // Full-box tap target: redistribute horizontal padding into the
      // dropdown's clickable padding (see [dropdownFullTap]).
      final tap = dropdownFullTap(
        style?.decoration ??
            InputDecoration(
              hintText: field.placeholder ?? 'Select ${field.displayLabel}',
              border: const OutlineInputBorder(),
              filled: field.readOnly,
              fillColor: field.readOnly ? Colors.grey[200] : null,
            ),
      );
      return FormBuilderDropdown<String>(
        autovalidateMode: AutovalidateMode.onUserInteraction,
        key: ValueKey('link_${field.fieldname}_${staticOptions.length}'),
        name: field.fieldname ?? '',
        initialValue: validInitialValue,
        enabled: enabled && !field.readOnly,
        isExpanded: true,
        decoration: tap.decoration,
        padding: tap.padding,
        items: staticOptions
            .map(
              (option) => DropdownMenuItem(value: option, child: Text(option)),
            )
            .toList(),
        validator: field.reqd
            ? (value) => requiredValidator(value, field.displayLabel)
            : null,
        onChanged: (val) => onChanged?.call(val),
      );
    }

    // If field.options contains a DocType name, fetch from service or coordinator
    final effectiveService =
        linkOptionService ?? linkFieldCoordinator?.linkOptionService;
    if (field.options != null &&
        field.options!.isNotEmpty &&
        effectiveService != null) {
      return FormBuilderField<String>(
        autovalidateMode: AutovalidateMode.onUserInteraction,
        key: ValueKey('linkfield_${field.fieldname}'),
        name: field.fieldname ?? '',
        initialValue: value?.toString() ?? field.defaultValue?.toString(),
        enabled: enabled && !field.readOnly,
        validator: field.reqd
            ? (val) => requiredValidator(val, field.displayLabel)
            : null,
        builder: (state) {
          return _LinkFieldDropdown(
            field: field,
            value: state.value,
            onChanged: (val) {
              state.didChange(val);
              onChanged?.call(val);
            },
            enabled: enabled && !field.readOnly,
            linkOptionService: effectiveService,
            linkFieldCoordinator: linkFieldCoordinator,
            linkedDoctype: field.options!,
            linkFilters: field.linkFilters,
            formData: formData ?? {},
            parentFormData: parentFormData,
            getLinkFilterBuilder: getLinkFilterBuilder,
            style: style,
            onIsLocalChanged: onIsLocalChanged,
            errorText: state.errorText,
            allowPreselect: allowPreselect,
          );
        },
      );
    }

    // Fallback to text field
    return FormBuilderTextField(
      autovalidateMode: AutovalidateMode.onUserInteraction,
      key: ValueKey('link_text_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: value?.toString() ?? field.defaultValue ?? '',
      enabled: enabled && !field.readOnly,
      decoration: InputDecoration(
        hintText: field.placeholder ?? 'Enter ${field.displayLabel}',
        border: const OutlineInputBorder(),
        filled: field.readOnly,
        fillColor: field.readOnly ? Colors.grey[200] : null,
        suffixIcon: const Icon(Icons.search),
      ),
      validator: field.reqd
          ? (value) => requiredValidator(value, field.displayLabel)
          : null,
      onChanged: (val) => onChanged?.call(val),
    );
  }
}

/// Dropdown widget that loads options from service or coordinator
class _LinkFieldDropdown extends StatefulWidget {
  final dynamic field;
  final dynamic value;
  final ValueChanged<dynamic>? onChanged;
  final bool enabled;
  final LinkOptionService linkOptionService;
  final LinkFieldCoordinator? linkFieldCoordinator;
  final String linkedDoctype;
  final String? linkFilters;
  final Map<String, dynamic> formData;
  final Map<String, dynamic> parentFormData;
  final LinkFilterBuilder? Function(String doctype, String fieldname)?
  getLinkFilterBuilder;
  final FieldStyle? style;
  final ValueChanged<bool>? onIsLocalChanged;
  final String? errorText;
  final bool allowPreselect;

  const _LinkFieldDropdown({
    required this.field,
    this.value,
    this.onChanged,
    required this.enabled,
    required this.linkOptionService,
    this.linkFieldCoordinator,
    required this.linkedDoctype,
    this.linkFilters,
    required this.formData,
    this.parentFormData = const {},
    this.getLinkFilterBuilder,
    this.style,
    this.onIsLocalChanged,
    this.errorText,
    this.allowPreselect = true,
  });

  @override
  State<_LinkFieldDropdown> createState() => _LinkFieldDropdownState();
}

class _LinkFieldDropdownState extends State<_LinkFieldDropdown> {
  List<LinkOptionEntity> _options = [];
  bool _isLoading = true;
  bool _waitingForDependent = false;
  String _dependentFieldName = '';
  StreamSubscription<void>? _syncSub;

  /// This picker loads a short first page and searches the server as the user
  /// types ([LinkOptionService.usesServerSearch]).
  bool _serverSearch = false;

  /// Bumped by every [_loadOptions]; a load whose number is no longer current
  /// drops its result.
  int _loadGen = 0;

  /// The first page held every match, so typing never needs the server.
  bool _optionsComplete = true;

  /// Filters the first page was loaded with; every search reuses them.
  List<List<dynamic>>? _searchFilters;

  @override
  void initState() {
    super.initState();
    if (widget.linkFieldCoordinator != null &&
        widget.linkFieldCoordinator!.useCoordinator) {
      _loadOptionsViaCoordinator();
    } else {
      _loadOptions();
    }

    // Pickers opened mid-sync see an empty `docs__<doctype>` table and
    // return an empty option list. Without this subscription the dropdown
    // stayed empty forever even after the closure pull populated the
    // table. On every sync-complete tick, retry the load if we currently
    // have nothing — the coordinator's empty results aren't cached, so
    // the retry hits the resolver and picks up freshly-synced rows.
    final stream = widget.linkOptionService.syncComplete$;
    if (stream != null) {
      _syncSub = stream.listen((_) {
        if (!mounted) return;
        if (_isLoading || _waitingForDependent) return;
        if (_options.isNotEmpty) return;
        if (widget.linkFieldCoordinator != null &&
            widget.linkFieldCoordinator!.useCoordinator) {
          _loadOptionsViaCoordinator();
        } else {
          _loadOptions();
        }
      });
    }
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    super.dispose();
  }

  /// [autoSelect] false skips the single-option preselect: a server-searched
  /// first page that may not hold every match.
  void _applyOptionsAndAutoSelect(
    List<LinkOptionEntity> options, {
    bool autoSelect = true,
  }) {
    if (!mounted) return;
    setState(() {
      _options = options;
      _isLoading = false;
      _waitingForDependent = false;
    });
    // `widget.enabled` already folds in `field.readOnly` (see the call site in
    // [LinkField.buildField]), so this one clause covers both.
    if (autoSelect &&
        options.length == 1 &&
        widget.allowPreselect &&
        widget.enabled) {
      final currentVal = widget.value?.toString();
      final hasValidSelection =
          currentVal != null &&
          currentVal.isNotEmpty &&
          options.any(
            (o) => o.name == currentVal || (o.label ?? o.name) == currentVal,
          );
      if (!hasValidSelection) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          widget.onChanged?.call(options.first.name);
          // Auto-select must also propagate the option's locality —
          // otherwise an auto-picked offline target leaves
          // `<field>__is_local` at 0 and [UuidRewriter] skips the
          // rewrite at push time, sending the raw mobile_uuid to
          // the server (LinkValidationError 417).
          widget.onIsLocalChanged?.call(options.first.isLocal);
        });
      }
    }
  }

  void _loadOptionsViaCoordinator() {
    final coordinator = widget.linkFieldCoordinator;
    if (coordinator == null || !coordinator.useCoordinator) {
      _loadOptions();
      return;
    }
    // The coordinator caches one full option list per (doctype, filters); a
    // server-searched picker loads its own short first page instead.
    if (_usesServerSearch()) {
      _loadOptions();
      return;
    }
    final docField = widget.field is DocField
        ? widget.field as DocField
        : _docFieldFromDynamic(widget.field);
    if (docField == null) {
      _loadOptions();
      return;
    }
    if (!coordinator.canFetchNow(docField, widget.formData) &&
        coordinator.getTier(docField) > 0) {
      final dependentNames = LinkOptionService.getDependentFieldNames(
        widget.linkFilters,
      );
      _setWaitingForDependent(dependentNames);
      return;
    }
    setState(() => _isLoading = true);
    coordinator.registerField(
      docField,
      widget.formData,
      _applyOptionsAndAutoSelect,
    );
  }

  /// Puts the dropdown into the "waiting for parent field" state. Always
  /// guards `.first` against an empty list (defensive — the coordinator
  /// path historically did this with a ternary, the `_loadOptions` path
  /// relied on an outer `.isNotEmpty` if-condition; consolidating into
  /// one helper means a future code edit can't accidentally call `.first`
  /// unguarded).
  void _setWaitingForDependent(List<String> dependentNames) {
    setState(() {
      _options = [];
      _isLoading = false;
      _waitingForDependent = true;
      _dependentFieldName = dependentNames.isNotEmpty
          ? dependentNames.first
          : '';
    });
  }

  DocField? _docFieldFromDynamic(dynamic f) {
    if (f == null) return null;
    if (f is DocField) return f;
    return DocField(
      fieldname: f.fieldname?.toString(),
      fieldtype: f.fieldtype ?? 'Link',
      label: f.label?.toString(),
      options: f.options?.toString(),
      linkFilters: f.linkFilters?.toString(),
    );
  }

  Future<void> _loadOptions() async {
    // Only the newest load may apply its result: when a parent field changes
    // twice quickly, an older load finishing last would otherwise leave the
    // picker on the old filters (and search the server with them).
    final gen = ++_loadGen;
    setState(() {
      _isLoading = true;
      _waitingForDependent = false;
    });
    final docField =
        _docFieldFromDynamic(widget.field) ??
        DocField(
          fieldname: widget.field?.fieldname?.toString(),
          fieldtype: 'Link',
          options: widget.linkedDoctype,
          linkFilters: widget.linkFilters,
        );
    final filters = LinkOptionService.resolveFilters(
      field: docField,
      rowData: widget.formData,
      parentFormData: widget.parentFormData,
      hook: LinkOptionService.safeHook(
        widget.getLinkFilterBuilder,
        docField.options ?? '',
        docField.fieldname ?? '',
      ),
    );
    final dependentNames = LinkOptionService.getDependentFieldNames(
      widget.linkFilters,
    );
    if (widget.linkFilters != null &&
        widget.linkFilters!.isNotEmpty &&
        filters == null &&
        dependentNames.isNotEmpty) {
      _setWaitingForDependent(dependentNames);
      return;
    }
    try {
      final svc = widget.linkOptionService;
      if (_usesServerSearch()) {
        // At least 2, as [LinkSearchPolicy] asserts; the assert is gone in a
        // release build. Clamped here because [size] also decides below
        // whether the page holds every match. 0 would ask for every row.
        final size = math.max(2, svc.searchPolicy.prefetchSize);
        final List<LinkOptionEntity> options;
        try {
          options = await svc.searchLinkOptions(
            widget.linkedDoctype,
            txt: '',
            pageLength: size,
            filters: filters,
          );
        } catch (e, st) {
          // Load the full list instead, as before server search: it is
          // filtered in memory and typing never needs the server. If that
          // fails too, the catch below shows the empty state with Refresh.
          sdkLog(
            'LinkField: first page of ${widget.linkedDoctype} failed, '
            'loading the full list — $e\n$st',
          );
          if (!mounted || gen != _loadGen) return;
          final all = await svc.getLinkOptions(
            widget.linkedDoctype,
            filters: filters,
          );
          if (!mounted || gen != _loadGen) return;
          _serverSearch = false;
          _searchFilters = filters;
          _optionsComplete = true;
          _applyOptionsAndAutoSelect(all);
          return;
        }
        if (!mounted || gen != _loadGen) return;
        // More rows than asked for: the service returned its whole list (a
        // translated doctype, matched on device-side labels). Filter that in
        // memory as before; there is nothing more to search for.
        final wholeList = options.length > size;
        _serverSearch = !wholeList;
        _searchFilters = filters;
        // Fewer rows than asked for: the page holds every match.
        _optionsComplete = wholeList || options.length < size;
        final withHeld = await _withHeldValue(options);
        if (!mounted || gen != _loadGen) return;
        _applyOptionsAndAutoSelect(withHeld, autoSelect: _optionsComplete);
        return;
      }
      _serverSearch = false;
      final options = await svc.getLinkOptions(
        widget.linkedDoctype,
        filters: filters,
      );
      if (!mounted || gen != _loadGen) return;
      _applyOptionsAndAutoSelect(options);
    } catch (e, st) {
      debugPrint(
        'LinkField: getLinkOptions(${widget.linkedDoctype}) failed — $e\n$st',
      );
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _serverSearch = false;
        _options = [];
        _isLoading = false;
        _waitingForDependent = false;
      });
    }
  }

  /// [LinkOptionService.usesServerSearch], answering false when the service
  /// cannot answer. A host's `implements LinkOptionService` double (e.g. a
  /// mocktail Mock) that does not stub it returns null, which would throw and
  /// leave the picker empty; such a service keeps the prefetch, as before.
  bool _usesServerSearch() {
    try {
      return widget.linkOptionService.usesServerSearch(widget.linkedDoctype);
    } catch (e) {
      sdkLog(
        'LinkField: usesServerSearch(${widget.linkedDoctype}) unanswered — '
        'keeping the prefetch. $e',
      );
      return false;
    }
  }

  /// Adds the held value as an option carrying its title when the first page
  /// does not contain it, so a value past that page shows its title rather
  /// than the raw docname. A complete page is left alone: a held value missing
  /// from it does not match the filters, exactly as with a full prefetch.
  Future<List<LinkOptionEntity>> _withHeldValue(
    List<LinkOptionEntity> options,
  ) async {
    final held = widget.value?.toString() ?? '';
    if (held.isEmpty || _optionsComplete) return options;
    if (options.any((o) => o.name == held)) return options;
    final option = await _heldOption(held);
    return option == null ? options : [...options, option];
  }

  /// The held value [held] as an option labelled with its title, or null when
  /// no distinct title is available (the raw value then shows, as before).
  Future<LinkOptionEntity?> _heldOption(String held) async {
    String? title;
    try {
      title = await widget.linkOptionService.getLinkTitle(
        widget.linkedDoctype,
        held,
      );
    } catch (e, st) {
      sdkLog(
        'LinkField: getLinkTitle(${widget.linkedDoctype}, $held) failed — '
        '$e\n$st',
      );
    }
    if (title == null || title.isEmpty) return null;
    return LinkOptionEntity(
      doctype: widget.linkedDoctype,
      name: held,
      label: title,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// A value set after the first page loaded (a client script, fetch_from,
  /// a prefill) may be past that page; give it its title too.
  Future<void> _addHeldOptionIfMissing() async {
    final held = widget.value?.toString() ?? '';
    if (held.isEmpty || !_serverSearch || _optionsComplete) return;
    if (_options.any((o) => o.name == held)) return;
    final option = await _heldOption(held);
    if (option == null || !mounted) return;
    if (widget.value?.toString() != held) return;
    if (_options.any((o) => o.name == held)) return;
    setState(() => _options = [..._options, option]);
  }

  /// Keeps an option picked from a server search, which is not in [_options],
  /// so its label and locality stay known after the pick.
  void _keepPickedOption(LinkOptionEntity option) {
    if (_options.any((o) => o.name == option.name)) return;
    setState(() => _options = [..._options, option]);
  }

  /// The server search behind the picker. When it fails, the full list is
  /// loaded once ([_loadFullListAfterFailedSearch]) and the typed text
  /// filters it, so the picker no longer depends on the server. If the full
  /// list fails too, the search error stands ("Search failed").
  Future<List<LinkOptionEntity>> _search(String text) async {
    final svc = widget.linkOptionService;
    try {
      return await svc.searchLinkOptions(
        widget.linkedDoctype,
        txt: text,
        // At least 1, as [LinkSearchPolicy] asserts (not in a release
        // build): Frappe reads a page length of 0 as "every row".
        pageLength: math.max(1, svc.searchPolicy.pageLength),
        filters: _searchFilters,
      );
    } catch (e, st) {
      sdkLog(
        'LinkField: search of ${widget.linkedDoctype} for "$text" failed, '
        'loading the full list — $e\n$st',
      );
      final all = await _loadFullListAfterFailedSearch();
      if (all == null) rethrow;
      final q = text.trim().toLowerCase();
      return all
          .where(
            (o) =>
                (o.label ?? o.name).toLowerCase().contains(q) ||
                o.name.toLowerCase().contains(q),
          )
          .toList();
    }
  }

  /// The full-list load started by a failed search, and the [_loadGen] it
  /// belongs to: concurrent failures share it, and a reload starts over.
  Future<List<LinkOptionEntity>?>? _fullListLoad;
  int _fullListLoadGen = -1;

  /// Loads the full list (the prefetch the picker used before server search)
  /// and switches the picker to it: in-memory filtering, no more server
  /// searches. Options already held (the first page, the held value, rows
  /// picked from a search) are kept. Null when the load failed or a reload
  /// made it stale.
  Future<List<LinkOptionEntity>?> _loadFullListAfterFailedSearch() {
    final pending = _fullListLoad;
    if (pending != null && _fullListLoadGen == _loadGen) return pending;
    final gen = _loadGen;
    _fullListLoadGen = gen;
    return _fullListLoad = () async {
      try {
        final all = await widget.linkOptionService.getLinkOptions(
          widget.linkedDoctype,
          filters: _searchFilters,
        );
        if (!mounted || gen != _loadGen) return null;
        // An empty full list beside a non-empty first page answers nothing:
        // switching to it would stop every later search. Keep the error.
        if (all.isEmpty && _options.isNotEmpty) {
          if (_fullListLoadGen == gen) _fullListLoad = null;
          return null;
        }
        final seen = <String>{for (final o in all) o.name};
        setState(() {
          _options = [...all, ..._options.where((o) => seen.add(o.name))];
          _serverSearch = false;
          _optionsComplete = true;
        });
        return all;
      } catch (e, st) {
        sdkLog(
          'LinkField: full list of ${widget.linkedDoctype} failed too — '
          '$e\n$st',
        );
        // Let the next failed search try again.
        if (_fullListLoadGen == gen) _fullListLoad = null;
        return null;
      }
    }();
  }

  @override
  void didUpdateWidget(_LinkFieldDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    final useCoordinator =
        widget.linkFieldCoordinator != null &&
        widget.linkFieldCoordinator!.useCoordinator;
    final loadFn = useCoordinator ? _loadOptionsViaCoordinator : _loadOptions;

    if (oldWidget.value != widget.value) {
      unawaited(_addHeldOptionIfMissing());
    }

    if (oldWidget.linkFilters != widget.linkFilters) {
      loadFn();
      return;
    }
    final dependentNames = LinkOptionService.getDependentFieldNames(
      widget.linkFilters,
    );
    if (dependentNames.isEmpty) return;
    for (final key in dependentNames) {
      if (oldWidget.formData[key] != widget.formData[key]) {
        loadFn();
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      final loadingValue = widget.value?.toString();
      final hasValue = loadingValue != null && loadingValue.isNotEmpty;
      return DropdownButtonFormField<String>(
        // Same reason as the empty-state dropdown below: the resolved value shown
        // while loading can be a long docname, which would overflow the row.
        isExpanded: true,
        key: ValueKey('${widget.field.fieldname}_loading'),
        initialValue: hasValue ? loadingValue : null,
        onChanged: null,
        decoration:
            widget.style?.decoration?.copyWith(errorText: widget.errorText) ??
            InputDecoration(
              hintText: 'Loading...',
              errorText: widget.errorText,
              border: const OutlineInputBorder(),
              suffixIcon: const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        items: [
          if (!hasValue)
            DropdownMenuItem<String>(
              value: null,
              child: Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text('Loading...', style: TextStyle(color: Colors.grey[600])),
                ],
              ),
            ),
          if (hasValue)
            DropdownMenuItem<String>(
              value: loadingValue,
              child: Text(loadingValue),
            ),
        ],
      );
    }

    // An empty first page means nothing matches the filters at all (the page
    // is complete), so this is the same empty state as before, Refresh
    // included: there is nothing further to search for.
    if (_options.isEmpty) {
      final isWaiting = _waitingForDependent && _dependentFieldName.isNotEmpty;
      // Humanized, not the raw fieldname: this hint is user-facing and used to
      // read "Select diagnostic_framework first".
      final hint = isWaiting
          ? 'Select ${DocField.humanizeFieldname(_dependentFieldName)} first'
          : 'No options available';
      return DropdownButtonFormField<String>(
        key: ValueKey('${widget.field.fieldname}_empty_$isWaiting'),
        initialValue: null,
        // A DropdownButton sizes itself to its content, so a hint longer than
        // the field width overflowed the row (visible as a RenderFlex overflow
        // stripe in debug). `isExpanded` makes the child fill the available
        // width so the text ellipsizes instead.
        isExpanded: true,
        onChanged: (!isWaiting && widget.enabled && !widget.field.readOnly)
            ? (v) => widget.onChanged?.call(v)
            : null,
        decoration:
            widget.style?.decoration?.copyWith(errorText: widget.errorText) ??
            InputDecoration(
              hintText: hint,
              errorText: widget.errorText,
              border: const OutlineInputBorder(),
              suffixIcon: isWaiting
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: _loadOptions,
                      tooltip: 'Refresh options',
                    ),
            ),
        items: [
          DropdownMenuItem<String>(
            value: null,
            child: Text(hint, style: TextStyle(color: Colors.grey[600])),
          ),
        ],
      );
    }

    // Resolve current value from options
    final currentVal = widget.value?.toString();
    final selected = <String>[];
    if (currentVal != null && currentVal.isNotEmpty) {
      // Match by name or label
      final match = _options.any((o) => o.name == currentVal)
          ? currentVal
          : _options
                .where((o) => o.label == currentVal)
                .map((o) => o.name)
                .firstOrNull;
      if (match != null) selected.add(match);
      // Keep unknown values so existing docs still display
      if (match == null) selected.add(currentVal);
    }

    // Read only in server-search mode: a service that does not search (or a
    // test double that does not stub it) is never asked for its policy.
    final policy = _serverSearch ? widget.linkOptionService.searchPolicy : null;
    return SearchableSelect(
      options: _options,
      selected: selected,
      multiSelect: false,
      enabled: widget.enabled && !widget.field.readOnly,
      hintText:
          widget.field.placeholder ?? 'Search ${widget.field.displayLabel}...',
      labelText: widget.style?.decoration?.labelText,
      errorText: widget.errorText,
      pickerMode:
          widget.style?.linkFieldPickerMode ?? LinkFieldPickerMode.inline,
      onSearch: policy == null ? null : _search,
      searchDebounce: policy?.debounce ?? const Duration(milliseconds: 500),
      searchMinChars: policy?.minChars ?? 2,
      optionsComplete: !_serverSearch || _optionsComplete,
      onPickOption: _serverSearch ? _keepPickedOption : null,
      searchScope: _serverSearch ? '${_searchFilters ?? const []}' : null,
      onChanged: (values) {
        final picked = values.isEmpty ? null : values.first;
        widget.onChanged?.call(picked);
        // Mirror the picked option's locality into `<field>__is_local`. On
        // clear, force false so a stale `1` from a prior local pick doesn't
        // linger.
        if (widget.onIsLocalChanged != null) {
          var isLocal = false;
          if (picked != null) {
            for (final o in _options) {
              if (o.name == picked) {
                isLocal = o.isLocal;
                break;
              }
            }
          }
          widget.onIsLocalChanged!(isLocal);
        }
      },
    );
  }
}
