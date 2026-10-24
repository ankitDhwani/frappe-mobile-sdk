import 'package:flutter/material.dart';
import '../../../database/entities/link_option_entity.dart';
import 'link_field_picker_mode.dart';
import 'link_remote_search.dart';
import 'searchable_select_dialog.dart';

/// Reusable searchable select widget for Frappe Link options.
///
/// Two modes controlled by [multiSelect]:
/// - **Single** (`false`): type-ahead search -> pick one value -> collapses.
/// - **Multi** (`true`): chips for selected values + search -> pick many.
///
/// Call site only needs to supply [options] (pre-loaded) and handle changes.
/// Option loading is the caller's responsibility. With [onSearch] set, typing
/// that does not resolve among [options] also asks the caller for more.
class SearchableSelect extends StatefulWidget {
  const SearchableSelect({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.multiSelect = false,
    this.enabled = true,
    this.loading = false,
    this.hintText,
    this.labelText,
    this.errorText,
    this.pickerMode = LinkFieldPickerMode.inline,
    this.onSearch,
    this.searchDebounce = const Duration(milliseconds: 500),
    this.searchMinChars = 2,
    this.optionsComplete = true,
    this.onPickOption,
    this.searchScope,
  });

  /// All available options (already loaded).
  final List<LinkOptionEntity> options;

  /// Currently selected value(s).
  final List<String> selected;

  /// Called when selection changes — single list for both modes.
  final ValueChanged<List<String>> onChanged;

  final bool multiSelect;
  final bool enabled;
  final bool loading;
  final String? hintText;

  /// Floating label shown inside the input border (mirrors [InputDecoration.labelText]).
  /// Derives from the parent field's [FieldStyle.decoration.labelText] so the
  /// Link field matches every other field type in the form's visual style.
  final String? labelText;

  final String? errorText;
  final LinkFieldPickerMode pickerMode;

  /// Server search for options beyond [options]. Called [searchDebounce] after
  /// the last keystroke, once the text has [searchMinChars] characters and
  /// does not resolve locally; its rows are added after the local matches.
  ///
  /// The text resolves locally when [optionsComplete] is true, or when it
  /// equals an option's docname. A label or partial match does NOT stop the
  /// search: [options] may be only the first page, labels repeat, and the row
  /// the user wants can be past it.
  final Future<List<LinkOptionEntity>> Function(String text)? onSearch;
  final Duration searchDebounce;
  final int searchMinChars;

  /// True when [options] already hold every match, so [onSearch] is never
  /// needed.
  final bool optionsComplete;

  /// Called with the picked option before [onChanged], so a caller can keep an
  /// option that came from [onSearch] (it is not in [options]).
  final ValueChanged<LinkOptionEntity>? onPickOption;

  /// What the [onSearch] results depend on besides the text, e.g. the
  /// picker's filters. When it changes, cached and in-flight results are
  /// dropped and the current text is searched again.
  final Object? searchScope;

  @override
  State<SearchableSelect> createState() => _SearchableSelectState();
}

class _SearchableSelectState extends State<SearchableSelect> {
  String _search = '';
  bool _showSuggestions = false;
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  LinkRemoteSearch? _remote;

  /// Options picked from a server search, for their labels.
  final Map<String, LinkOptionEntity> _picked = {};

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    _syncRemote();
  }

  @override
  void didUpdateWidget(SearchableSelect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.onSearch == null) != (widget.onSearch == null)) {
      _remote?.dispose();
      _remote = null;
      _syncRemote();
    } else if (oldWidget.searchScope != widget.searchScope) {
      // Rows found under the old filters are wrong now: drop them and search
      // the current text again. A new options list alone (a pick, a reload
      // with the same filters) keeps the cache and any reply in flight.
      _remote?.reset();
      _remote?.update(_search, resolvedLocally: _resolvesLocally(_search));
    }
  }

  void _syncRemote() {
    final search = widget.onSearch;
    if (search == null || _remote != null) return;
    _remote = LinkRemoteSearch(
      search: (text) => widget.onSearch!(text),
      debounce: widget.searchDebounce,
      minChars: widget.searchMinChars,
      onUpdate: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _remote?.dispose();
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!mounted) return;
    setState(() => _showSuggestions = _focusNode.hasFocus);
  }

  String _labelFor(String name) =>
      widget.options
          .where((o) => o.name == name)
          .map((o) => o.label ?? o.name)
          .firstOrNull ??
      _picked[name]?.label ??
      name;

  bool _resolvesLocally(String text) => LinkRemoteSearch.resolvesLocally(
    widget.options,
    text,
    complete: widget.optionsComplete,
  );

  List<LinkOptionEntity> get _filtered {
    final q = _search.toLowerCase();
    // Label or docname, as the dialog matches: a docname typed in full counts
    // as resolved locally, so its row has to be on screen.
    final local = widget.options
        .where(
          (o) =>
              q.isEmpty ||
              (o.label ?? o.name).toLowerCase().contains(q) ||
              o.name.toLowerCase().contains(q),
        )
        .toList();
    final merged = LinkRemoteSearch.merge(local, _remote?.resultsFor(_search));
    return merged.where((o) => !widget.selected.contains(o.name)).toList();
  }

  void _onSearchChanged(String text) {
    final remote = _remote;
    if (remote == null) {
      setState(() => _search = text);
      return;
    }
    // update() always reports through onUpdate (one setState), so setting the
    // text here without a setState of its own avoids a second rebuild.
    _search = text;
    remote.update(text, resolvedLocally: _resolvesLocally(text));
  }

  void _pick(LinkOptionEntity option) {
    final name = option.name;
    _picked[name] = option;
    widget.onPickOption?.call(option);
    if (widget.multiSelect) {
      if (widget.selected.contains(name)) return;
      widget.onChanged([...widget.selected, name]);
    } else {
      widget.onChanged([name]);
    }
    _controller.clear();
    _remote?.update('', resolvedLocally: true);
    setState(() {
      _search = '';
      _showSuggestions = false;
    });
    _focusNode.unfocus();
  }

  void _remove(String name) {
    widget.onChanged(widget.selected.where((v) => v != name).toList());
  }

  void _clear() {
    widget.onChanged([]);
    _controller.clear();
    _remote?.update('', resolvedLocally: true);
    setState(() => _search = '');
  }

  void _openDialog() async {
    if (!widget.enabled) return;

    final List<String>? result = await showDialog<List<String>>(
      context: context,
      builder: (context) {
        return SearchableSelectDialog(
          options: widget.options,
          initialSelected: widget.selected,
          multiSelect: widget.multiSelect,
          title: widget.labelText,
          onSearch: widget.onSearch,
          searchDebounce: widget.searchDebounce,
          searchMinChars: widget.searchMinChars,
          optionsComplete: widget.optionsComplete,
          onPickOption: (o) {
            _picked[o.name] = o;
            widget.onPickOption?.call(o);
          },
        );
      },
    );

    if (result != null) {
      widget.onChanged(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final selected = widget.selected;
    final filtered = _filtered;
    final hasValue = selected.isNotEmpty;
    final searching = _remote?.searching ?? false;
    final searchError = _remote?.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Multi-select chips
        if (widget.multiSelect && hasValue)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: selected.map((val) {
                return Chip(
                  label: Text(
                    _labelFor(val),
                    style: const TextStyle(fontSize: 13),
                  ),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: widget.enabled ? () => _remove(val) : null,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          ),

        if (widget.pickerMode == LinkFieldPickerMode.dialog)
          InkWell(
            onTap: _openDialog,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: widget.labelText,
                errorText: widget.errorText,
                hintText:
                    widget.hintText ??
                    (widget.multiSelect
                        ? (hasValue ? 'Add more...' : 'Select options...')
                        : 'Select...'),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: const OutlineInputBorder(),
                suffixIcon: (!widget.multiSelect && hasValue && widget.enabled)
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _clear,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      )
                    : const Icon(Icons.arrow_drop_down),
              ),
              child: Text(
                (!widget.multiSelect && hasValue)
                    ? _labelFor(selected.first)
                    : '',
                style: const TextStyle(fontSize: 14),
              ),
            ),
          )
        else ...[
          // Single-select current value
          if (!widget.multiSelect && hasValue && !_showSuggestions)
            GestureDetector(
              onTap: widget.enabled
                  ? () {
                      _focusNode.requestFocus();
                      setState(() => _showSuggestions = true);
                    }
                  : null,
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: widget.labelText,
                  errorText: widget.errorText,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: const OutlineInputBorder(),
                  suffixIcon: widget.enabled
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: _clear,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        )
                      : null,
                ),
                child: Text(
                  _labelFor(selected.first),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ),

          // Search input
          if (widget.enabled &&
              (widget.multiSelect || !hasValue || _showSuggestions))
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              decoration: InputDecoration(
                labelText: widget.labelText,
                errorText: widget.errorText,
                hintText:
                    widget.hintText ??
                    (widget.multiSelect
                        ? (hasValue ? 'Add more...' : 'Search & select...')
                        : 'Search...'),
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: const OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 14),
              onChanged: _onSearchChanged,
            ),

          if (_showSuggestions && searching)
            const LinearProgressIndicator(minHeight: 2),

          // Suggestion list
          if (_showSuggestions && filtered.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(4),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final opt = filtered[index];
                  return InkWell(
                    onTap: () => _pick(opt),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Text(
                        opt.label ?? opt.name,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  );
                },
              ),
            ),

          // A failed search must not read as "nothing matches".
          if (_showSuggestions && _search.isNotEmpty && searchError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: InkWell(
                onTap: () => _remote?.retry(_search),
                child: Text(
                  'Search failed. Tap to retry',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            )
          // Empty state
          else if (_showSuggestions && _search.isNotEmpty && filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                searching ? 'Searching...' : 'No matching options',
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
            ),
        ],
      ],
    );
  }
}
