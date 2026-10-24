/// Coerces a dynamic value into a [DateTime] or null.
/// - `null` → null
/// - `DateTime` → returned as-is
/// - `String` → parsed via [DateTime.tryParse]; null on parse failure
/// - any other type → null
///
/// Shared by the date and datetime field widgets and by the form builder's
/// patched-value normalizer so the coercion logic lives in one place.
DateTime? parseDateTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// Formats a duration expressed in seconds as `HH:MM:SS` (when hours > 0)
/// or `MM:SS`. Each component is zero-padded to two digits. Shared by the
/// Duration field widget and the form builder's patched-value formatter.
String formatDurationSeconds(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final secs = seconds % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${secs.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${secs.toString().padLeft(2, '0')}';
}

/// Field types whose value a date/time picker holds.
const Set<String> temporalFieldtypes = {'Date', 'Datetime', 'Time'};

String _two(int n) => n.toString().padLeft(2, '0');

/// `YYYY-MM-DD`, the way Frappe stores a Date.
String frappeDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

/// `YYYY-MM-DD HH:mm:ss`, the way Frappe stores a Datetime.
String frappeDatetime(DateTime d) =>
    '${frappeDate(d)} ${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

/// `HH:mm:ss`, the way Frappe stores a Time.
String frappeTime(DateTime d) =>
    '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

/// The value a picker for [fieldtype] can hold: a [DateTime], or null for an
/// empty or unreadable value. Accepts Frappe's stored text (and the ISO text
/// earlier SDK versions saved); a Time is read as `HH:mm[:ss]`.
DateTime? pickerDateTime(String fieldtype, Object? value) {
  if (value is DateTime) return value;
  if (value is! String || value.trim().isEmpty) return null;
  if (fieldtype == 'Time') {
    final parts = value.trim().split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final s = parts.length > 2 ? int.tryParse(parts[2].split('.').first) : 0;
    if (h == null || m == null || s == null) return null;
    return DateTime(2000, 1, 1, h, m, s);
  }
  return DateTime.tryParse(value.trim());
}

/// [value] the way Frappe saves it for a [fieldtype] field: an empty value is
/// null, a [DateTime] becomes Frappe's text. Anything else (including text an
/// earlier SDK version stored) is returned unchanged.
Object? frappeTemporalValue(String fieldtype, Object? value) {
  if (value is String && value.trim().isEmpty) return null;
  if (value is DateTime) {
    return switch (fieldtype) {
      'Date' => frappeDate(value),
      'Time' => frappeTime(value),
      _ => frappeDatetime(value),
    };
  }
  return value;
}
