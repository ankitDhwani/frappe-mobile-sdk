import 'package:flutter/material.dart';
import '../../../database/entities/link_option_entity.dart';
import 'link_remote_search.dart';

class SearchableSelectDialog extends StatefulWidget {
  final List<LinkOptionEntity> options;
  final List<String> initialSelected;
  final bool multiSelect;
  final String? title;

  /// Server search for options beyond [options]; see [SearchableSelect.onSearch].
  final Future<List<LinkOptionEntity>> Function(String text)? onSearch;
  final Duration searchDebounce;
  final int searchMinChars;
  final bool optionsComplete;

  /// Called with the picked option before the dialog closes, so a caller can
  /// keep an option that came from [onSearch].
  final ValueChanged<LinkOptionEntity>? onPickOption;

  const SearchableSelectDialog({
    super.key,
    required this.options,
    required this.initialSelected,
    required this.multiSelect,
    this.title,
    this.onSearch,
    this.searchDebounce = const Duration(milliseconds: 500),
    this.searchMinChars = 2,
    this.optionsComplete = true,
    this.onPickOption,
  });

  @override
  State<SearchableSelectDialog> createState() => _SearchableSelectDialogState();
}

class _SearchableSelectDialogState extends State<SearchableSelectDialog> {
  String _searchQuery = '';
  late List<String> _selected;
  LinkRemoteSearch? _remote;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.initialSelected);
    final search = widget.onSearch;
    if (search != null) {
      _remote = LinkRemoteSearch(
        search: search,
        debounce: widget.searchDebounce,
        minChars: widget.searchMinChars,
        onUpdate: () {
          if (mounted) setState(() {});
        },
      );
    }
  }

  @override
  void dispose() {
    _remote?.dispose();
    super.dispose();
  }

  bool _resolvesLocally(String text) => LinkRemoteSearch.resolvesLocally(
    widget.options,
    text,
    complete: widget.optionsComplete,
  );

  void _toggleSelection(LinkOptionEntity option) {
    final value = option.name;
    setState(() {
      if (widget.multiSelect) {
        if (_selected.contains(value)) {
          _selected.remove(value);
        } else {
          _selected.add(value);
          // A row from the server search is not in [options]: report it so
          // the caller can keep its label once the dialog closes.
          widget.onPickOption?.call(option);
        }
      } else {
        _selected = [value];
        widget.onPickOption?.call(option);
        Navigator.of(context).pop(_selected);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final filteredOptions = LinkRemoteSearch.merge(
      widget.options.where((option) {
        if (_searchQuery.isEmpty) return true;
        final labelLower = (option.label ?? option.name).toLowerCase();
        final nameLower = option.name.toLowerCase();
        final queryLower = _searchQuery.toLowerCase();
        return labelLower.contains(queryLower) ||
            nameLower.contains(queryLower);
      }).toList(),
      _remote?.resultsFor(_searchQuery),
    );
    final searching = _remote?.searching ?? false;
    final error = _remote?.error;

    return AlertDialog(
      title: Text(widget.title ?? 'Select Options'),
      contentPadding: const EdgeInsets.only(top: 16.0),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 24.0,
                vertical: 8.0,
              ),
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Search...',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.0),
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                ),
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value;
                  });
                  _remote?.update(
                    value,
                    resolvedLocally: _resolvesLocally(value),
                  );
                },
              ),
            ),
            if (searching) const LinearProgressIndicator(minHeight: 2),
            if (error != null)
              TextButton(
                onPressed: () => _remote?.retry(_searchQuery),
                child: const Text('Search failed. Tap to retry'),
              ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: filteredOptions.length,
                itemBuilder: (context, index) {
                  final option = filteredOptions[index];
                  final isSelected = _selected.contains(option.name);

                  if (widget.multiSelect) {
                    return CheckboxListTile(
                      title: Text(option.label ?? option.name),
                      value: isSelected,
                      onChanged: (bool? checked) {
                        _toggleSelection(option);
                      },
                    );
                  } else {
                    return ListTile(
                      title: Text(option.label ?? option.name),
                      trailing: isSelected
                          ? const Icon(Icons.check, color: Colors.blue)
                          : null,
                      onTap: () {
                        _toggleSelection(option);
                      },
                    );
                  }
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.multiSelect ? 'Cancel' : 'Close'),
        ),
        if (widget.multiSelect)
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(_selected),
            child: const Text('Done'),
          ),
      ],
    );
  }
}
