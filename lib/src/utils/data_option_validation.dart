import 'translate.dart';

// Frappe's own patterns (frappe/utils/__init__.py and
// frappe/public/js/frappe/utils/utils.js `validate_type`).
final RegExp _email = RegExp(
  r"^[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*@(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$",
  caseSensitive: false,
);
final RegExp _phone = RegExp(r'^([0-9 +_\-,.*#()]){1,20}$');
// Python's \w is Unicode-aware; spell it out so names in any script pass.
final RegExp _name = RegExp(
  r"^[\p{L}\p{M}\p{N}_][\p{L}\p{M}\p{N}_'\-]*( [\p{L}\p{M}\p{N}_][\p{L}\p{M}\p{N}_'\-]*)*$",
  unicode: true,
);
final RegExp _angleEmail = RegExp(r'<([^>]+)>');

/// The error Frappe gives on save for [value] in a Data field whose options
/// are Email, Phone, Name or URL (`BaseDocument._validate_data_fields`), or
/// null when the value is valid, empty, or the options name no check.
///
/// Offline the SDK would only hear that error at sync, with the record stuck
/// in the outbox; checking on the form catches it while the user is there.
String? dataOptionError(String? options, String? value) {
  final v = value?.trim() ?? '';
  if (v.isEmpty) return null;
  switch (options) {
    case 'Email':
      // split_emails: a comma- or newline-separated list.
      for (final part in v.split(RegExp(r'[,\n]'))) {
        final p = part.trim();
        if (p.isEmpty) continue;
        final addr = _angleEmail.firstMatch(p)?.group(1)?.trim() ?? p;
        if (!_email.hasMatch(addr)) {
          return sdkTr('{0} is not a valid Email Address', [p]);
        }
      }
      return null;
    case 'Phone':
      return _phone.hasMatch(v)
          ? null
          : sdkTr('{0} is not a valid Phone Number', [v]);
    case 'Name':
      return _name.hasMatch(v) ? null : sdkTr('{0} is not a valid Name', [v]);
    case 'URL':
      // validate_url: a scheme with a host or path, or a path on the site.
      final uri = Uri.tryParse(v);
      final ok =
          v.startsWith('/') ||
          (uri != null &&
              uri.scheme.isNotEmpty &&
              (uri.host.isNotEmpty || uri.path.isNotEmpty));
      return ok ? null : sdkTr("'{0}' is not a valid URL", [v]);
    default:
      return null;
  }
}
