/// How Link pickers load and search their options when the SDK runs
/// online-first (offline mode disabled).
///
/// By default a picker loads the first [prefetchSize] options, filters them in
/// memory as the user types, and asks the server only when the typed text does
/// not resolve among them. Without this a picker reaches only the first page of
/// its target doctype: a record past that page cannot be found by typing.
///
/// The server search matches the typed text with `LIKE %text%` against the
/// target's `name`, title field and `search_fields`, which is what Frappe Desk's
/// Link control matches (`frappe.desk.search.search_widget`). It goes through
/// the same `frappe.client.get_list` path as the prefetch, so option labels are
/// built exactly as before.
///
/// Offline-first reads are not affected: they keep the local list.
class LinkSearchPolicy {
  const LinkSearchPolicy({
    this.enabled = true,
    this.prefetchSize = 10,
    this.minChars = 2,
    this.debounce = const Duration(milliseconds: 500),
    this.pageLength = 20,
    this.prefetchOnlyDoctypes = const {},
  }) : assert(prefetchSize >= 2, 'prefetchSize must be at least 2'),
       assert(pageLength >= 1, 'pageLength must be at least 1');

  /// A policy that keeps the full prefetch for every picker.
  static const LinkSearchPolicy disabled = LinkSearchPolicy(enabled: false);

  /// `false` keeps the full prefetch for every picker.
  final bool enabled;

  /// Options loaded when a picker opens. Fewer rows than this means the picker
  /// already holds every match, so typing never reaches the server.
  ///
  /// At least 2. A single matching option is auto-selected only when the page
  /// holds every match, and with a page of 1 a lone row cannot be told apart
  /// from the first of many.
  final int prefetchSize;

  /// No server search below this many typed characters.
  final int minChars;

  /// Wait after the last keystroke before searching. 500 ms is Desk's.
  final Duration debounce;

  /// Rows returned by one server search. At least 1: Frappe reads
  /// `limit_page_length=0` as "no limit" and would return the whole doctype.
  final int pageLength;

  /// Target doctypes that keep the full prefetch even when [enabled].
  final Set<String> prefetchOnlyDoctypes;
}
