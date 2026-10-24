/// Whether [doc] is already saved on the server: it has a `name`, or, for a
/// record read from the offline store, a `server_name`. A record created
/// offline and not pushed yet has neither, so it is still new — Desk's
/// `__islocal`, and Frappe's own test `__islocal or not name`
/// (`document.py`).
bool isSavedOnServer(Map<String, dynamic>? doc) {
  if (doc == null) return false;
  bool has(String key) {
    final v = doc[key];
    return v != null && v.toString().isNotEmpty;
  }

  return has('name') || has('server_name');
}
