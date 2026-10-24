import '../models/doc_field.dart';
import '../models/session_user.dart';
import 'date_helpers.dart';
import 'frappe_reserved_fields.dart';

/// The value a new document starts with for [field], the way Desk sets it
/// (`frappe.model.get_default_value`, then `set_default_values`).
///
/// Tokens are resolved first:
/// - `__user` / `user` -> the signed-in [user]'s id, `user_fullname` -> their
///   full name;
/// - `now` -> the current time in the field type's format, `Today` on a Date
///   -> today's date (from [now], default [DateTime.now]);
/// - a token the SDK cannot resolve (no [user], or `:Doctype`, which reads
///   Desk's boot defaults) gives null, so the field starts unset and the server
///   fills it on insert instead of receiving the token's text.
///
/// The value is then typed: Int and Check go through `cint`, Float and
/// Currency through `flt`, every other type keeps the text. A Select with no
/// default starts on its first option. Desk assigns a
/// default only when its text is non-empty (`if (v)`), so an empty default on
/// a numeric field returns null.
///
/// Without the typing a Check whose default is `"0"` starts as the string
/// `"0"`, which `eval:doc.flag` reads as true (a non-empty string): every
/// field gated on a switch that is off is shown until the user flips it.
///
/// [newDocument]: Desk applies `set_default_values` to a NEW document only.
/// Frappe omits null fields from a saved document it returns, so a saved
/// record's empty field (or one the user has just cleared) has no value here;
/// giving it its default would write the current user, the current time, the
/// literal default or a Select's first option on the next save. When
/// [newDocument] is false this therefore returns null for every field.
Object? typedDefaultValue(
  DocField field, {
  SessionUser? user,
  DateTime Function()? now,
  bool newDocument = true,
}) {
  if (!newDocument) return null;
  final raw = field.defaultValue;
  if (raw != null && raw.isNotEmpty) {
    final token = raw.toLowerCase();
    if (raw == '__user' || token == 'user') return user?.name;
    if (raw == 'user_fullname') return user?.fullName;
    if (raw.startsWith(':')) return null;
    if (token == 'now') {
      final t = (now ?? DateTime.now)();
      return switch (field.fieldtype) {
        'Time' => frappeTime(t),
        'Date' => frappeDate(t),
        _ => frappeDatetime(t),
      };
    }
    if (token == 'today' && field.fieldtype == 'Date') {
      return frappeDate((now ?? DateTime.now)());
    }
  }
  switch (field.fieldtype) {
    case 'Int':
    case 'Check':
      return (raw == null || raw.isEmpty) ? null : _cint(raw);
    case 'Float':
    case 'Currency':
      return (raw == null || raw.isEmpty) ? null : _flt(raw);
    case 'Select':
      if (raw != null && raw.isNotEmpty) return raw;
      return _firstSelectOption(field);
    default:
      return raw;
  }
}

/// Whether [data] is a document that has never been saved: no server `name`
/// (or local `server_name`) and no `mobile_uuid` of a record created on this
/// device. Null or empty data is new.
bool isNewDocumentData(Map<String, dynamic>? data) {
  if (data == null) return true;
  bool blank(Object? v) => v == null || v.toString().trim().isEmpty;
  return blank(data['name']) &&
      blank(data['server_name']) &&
      blank(data['mobile_uuid']);
}

/// Desk starts a Select with no default on its first option
/// (set_default_values), blank when the list starts with an empty line.
///
/// Left to [SelectField], which already preselects a sole option and reports
/// it as a change: a list with one option, a reserved field such as
/// `naming_series` (never preselected), and a multi-select.
String? _firstSelectOption(DocField field) {
  if (field.allowMultiple || isFrappeReservedField(field.fieldname)) {
    return null;
  }
  final options = field.options;
  if (options == null ||
      options.isEmpty ||
      options == '[Select]' ||
      options == 'Loading...') {
    return null;
  }
  final lines = options.split('\n');
  final first = lines.first;
  if (first.trim().isEmpty) return null;
  if (lines.where((l) => l.trim().isNotEmpty).length < 2) return null;
  return first;
}

final RegExp _leadingInt = RegExp(r'^\s*[+-]?\d+');
final RegExp _leadingNumber = RegExp(
  r'^\s*[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?',
);

/// Frappe's `cint`: the leading integer (`parseInt`), or 0.
int _cint(String v) {
  final m = _leadingInt.firstMatch(v);
  return m == null ? 0 : int.parse(m.group(0)!.trim());
}

/// Frappe's `flt` without a precision: digit-group commas removed, then the
/// leading number (`parseFloat`), or 0. A whole number stays an int, as
/// JavaScript prints it.
num _flt(String v) {
  final m = _leadingNumber.firstMatch(v.replaceAll(',', ''));
  return m == null ? 0 : num.parse(m.group(0)!.trim());
}
