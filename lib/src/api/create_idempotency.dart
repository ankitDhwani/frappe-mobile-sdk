import 'exceptions.dart';

/// The document identity a create carries, and the only key this guard uses.
const String kMobileUuidField = 'mobile_uuid';

/// How many completed `(doctype, uuid)` attempts to remember per registry.
///
/// Only the KEY is retained, never the document, so the cost is a short string
/// each. The cap exists so a long session filling hundreds of forms cannot grow
/// this without bound; evicting the oldest is safe because eviction only costs
/// a retry its pre-flight lookup, and the ambiguous-failure lookup — which is
/// the one that actually prevents a duplicate — does not consult this set.
const int kMaxRememberedAttempts = 512;

/// Whether a failed create might STILL have landed on the server.
///
/// This is the whole judgement call of the guard, so it is deliberately
/// conservative in one direction only: answering `true` for a request that did
/// not land costs one wasted lookup, while answering `false` for one that did
/// land costs a duplicate document. Duplicates are the thing we are here to
/// prevent, so anything that is not a positively-identified refusal counts as
/// ambiguous.
///
/// * [NetworkException] — a timeout, a dropped socket, a connection reset. The
///   request may have been fully processed with only the response lost. This is
///   the classic duplicate generator: the operator sees a failure, taps again,
///   and the first one was already committed.
/// * 5xx — the server was reached. A gateway timeout in particular is routinely
///   returned for a request that is still running and goes on to commit.
/// * **4xx is NOT ambiguous.** 400 / 403 / 409 / 417 are the server positively
///   refusing the write; nothing was created, and a retry should proceed
///   normally rather than pay for a lookup that will find nothing.
bool isAmbiguousCreateFailure(Object error) {
  if (error is NetworkException) return true;
  if (error is FrappeException) {
    final code = error.statusCode;
    if (code == null) return true;
    return code >= 500;
  }
  // An error type this layer does not model at all. It cannot be shown to be a
  // refusal, so it is treated as ambiguous — see the note above on which
  // direction is safe to be wrong in.
  return true;
}

/// Reads the document identity out of a create payload, treating blank as absent.
///
/// A blank value must NEVER reach the server. `mobile_uuid` carries a UNIQUE
/// index on most doctypes, and MariaDB permits many NULLs in a unique index but
/// only ONE empty string — so a payload sending `''` either fails the second
/// write with a confusing duplicate-key error, or writes a single empty
/// identity that every later blank collides with. Absent is correct; empty is
/// actively harmful.
String? readMobileUuid(Map<String, dynamic> data) {
  final raw = data[kMobileUuidField];
  if (raw == null) return null;
  final value = raw.toString().trim();
  return value.isEmpty ? null : value;
}

/// Returns a payload with a blank [kMobileUuidField] removed entirely.
///
/// Returns the SAME instance when there is nothing to strip, so the common path
/// allocates nothing and callers that rely on identity are unaffected.
Map<String, dynamic> withoutBlankMobileUuid(Map<String, dynamic> data) {
  if (!data.containsKey(kMobileUuidField)) return data;
  if (readMobileUuid(data) != null) return data;
  return Map<String, dynamic>.from(data)..remove(kMobileUuidField);
}

/// Looks a document up by its [kMobileUuidField]. Null when none exists.
typedef FindByMobileUuid =
    Future<Map<String, dynamic>?> Function(String doctype, String mobileUuid);

/// Called when a create was answered by a document that ALREADY existed, rather
/// than by writing a new one.
///
/// This exists because "indistinguishable from a real create" is the property
/// that makes the guard safe for plumbing and unsafe for people. The reachable
/// sequence: a create times out but lands; the resolving lookup also fails on
/// the same dead network, so the error surfaces; the operator corrects a field
/// and saves again; the pre-flight lookup now finds the document written from
/// the FIRST payload and returns it. The screen reports success and the
/// correction is gone, with nothing said.
///
/// Before idempotency that operator got a duplicate — visible, and fixable in
/// Desk. A silent no-op on a record they believe they just corrected is worse.
/// The guard cannot resolve this on its own: it cannot know whether [payload]
/// differs meaningfully from what was stored, and guessing would be its own
/// bug. So it reports, and the UI decides what to say.
typedef OnResolvedExisting =
    void Function(
      String doctype,
      String mobileUuid,
      Map<String, dynamic> existing,
      Map<String, dynamic> payload,
    );

/// Makes an ONLINE create idempotent on `mobile_uuid`.
///
/// ## Why this exists in the client at all
///
/// Offline creates have never duplicated, and not because that path is more
/// careful: the uuid is minted once into the local row and IS its primary key,
/// so every push retry sends the same value and the server's unique index
/// rejects the twin. The property doing the work is that the value is **stable
/// across retries** — not that a uuid exists.
///
/// The online path had neither half. Nothing minted, so the column was NULL;
/// MariaDB permits unlimited NULLs in a unique index, so no two rows ever
/// collided. And on the doctypes where the field was provisioned WITHOUT
/// `unique: 1` there is no index to collide with even when a value is sent — so
/// on those, a server-side constraint cannot be the answer and the client has
/// to do the catching itself. That is what this class is: the catching.
///
/// ## What it does, in order
///
/// 1. **Single-flight.** A second create for a `(doctype, uuid)` already in
///    flight awaits the first instead of issuing its own POST. This is the
///    double-tap case.
/// 2. **Pre-flight lookup on a KNOWN retry.** Once a key has been attempted in
///    this session, the next attempt asks the server whether that uuid already
///    exists and returns the existing document if so. Deliberately NOT done on
///    a first attempt: that would put a second round trip in front of every
///    create in the app for no benefit, since a uuid never sent cannot exist.
/// 3. **Lookup after an ambiguous failure.** A timeout or 5xx is resolved by
///    asking the server what actually happened, converting "I don't know" into
///    a definite answer before the error reaches the operator.
///
/// ## What it does NOT claim
///
/// This is not atomic. Two devices, or two isolates, posting the same uuid at
/// the same instant can still both pass their lookups. Only a database
/// constraint closes that, and on the doctypes lacking the unique index nothing
/// client-side can. What it does close is the window that actually produces
/// duplicates in the field: one operator, one device, retrying a submit that
/// looked like it failed — observed at gaps of 16 s to 5 minutes, all of them
/// far wider than any race this leaves open.
class CreateIdempotencyGuard {
  CreateIdempotencyGuard({
    required FindByMobileUuid findByMobileUuid,
    OnResolvedExisting? onResolvedExisting,
  }) : _find = findByMobileUuid,
       _onResolved = onResolvedExisting;

  final FindByMobileUuid _find;

  /// Notified whenever a create is answered by an existing document. Optional:
  /// a null listener keeps the old silent behaviour, so adopting this is not a
  /// breaking change for a host that has not wired a message yet.
  final OnResolvedExisting? _onResolved;

  /// Creates currently in flight, keyed by `(doctype, uuid)`.
  final Map<String, Future<Map<String, dynamic>>> _inFlight = {};

  /// Keys that have been attempted at least once, newest last.
  final Set<String> _attempted = <String>{};

  // Separator is a NUL, written as an ESCAPE rather than a literal control
  // character. A raw 0x00 in the source makes git treat the whole file as
  // binary: no diff, no line comments, no blame, and fragile to anything that
  // normalises text. `\u0000` is byte-identical at runtime and keeps the file
  // reviewable. NUL is the separator because it cannot occur in a doctype name
  // or a uuid, so no pair of inputs can collide by straddling it.
  static String _key(String doctype, String uuid) => '$doctype\u0000$uuid';

  /// Runs [create] for [data] under the guarantees described on the class.
  ///
  /// When [data] carries no usable `mobile_uuid` this delegates straight to
  /// [create] — same request, same errors, no extra round trips. Adopting the
  /// guard is therefore opt-in per payload: a caller that does not mint a uuid
  /// sees no behaviour change at all.
  Future<Map<String, dynamic>> run({
    required String doctype,
    required Map<String, dynamic> data,
    required Future<Map<String, dynamic>> Function(Map<String, dynamic> payload)
    create,
  }) {
    final payload = withoutBlankMobileUuid(data);
    final uuid = readMobileUuid(payload);
    if (uuid == null) return create(payload);

    final key = _key(doctype, uuid);

    // (1) Single-flight. Hand back the in-flight future rather than starting a
    // second POST for the same document.
    final running = _inFlight[key];
    if (running != null) return running;

    final future = _runGuarded(doctype, uuid, key, payload, create);
    _inFlight[key] = future;
    // Cleared in a `whenComplete` rather than a `finally` inside `_runGuarded`
    // so the entry survives exactly as long as the future itself, including the
    // error path where callers may still be attaching handlers.
    return future.whenComplete(() => _inFlight.remove(key));
  }

  Future<Map<String, dynamic>> _runGuarded(
    String doctype,
    String uuid,
    String key,
    Map<String, dynamic> payload,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) create,
  ) async {
    // (2) A key we have already attempted means this is a retry, so ask the
    // server before writing. A lookup FAILURE here must not block the create —
    // being unable to check is not evidence of a duplicate, and refusing to
    // save on it would turn a transient read error into lost operator work.
    if (_attempted.contains(key)) {
      final existing = await _findQuietly(doctype, uuid);
      if (existing != null) {
        _onResolved?.call(doctype, uuid, existing, payload);
        return existing;
      }
    }

    _remember(key);

    try {
      return await create(payload);
    } catch (e) {
      // (3) The request may have landed. Resolve it rather than reporting a
      // failure the operator will answer by retrying.
      if (isAmbiguousCreateFailure(e)) {
        final existing = await _findQuietly(doctype, uuid);
        if (existing != null) {
          _onResolved?.call(doctype, uuid, existing, payload);
          return existing;
        }
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _findQuietly(
    String doctype,
    String uuid,
  ) async {
    try {
      return await _find(doctype, uuid);
    } catch (_) {
      return null;
    }
  }

  void _remember(String key) {
    // Re-insert to refresh recency: a Dart LinkedHashSet preserves insertion
    // order, so removing first makes `.first` genuinely the oldest entry.
    _attempted
      ..remove(key)
      ..add(key);
    while (_attempted.length > kMaxRememberedAttempts) {
      _attempted.remove(_attempted.first);
    }
  }

  /// Forgets every remembered attempt. For tests and for logout, where a new
  /// user must not inherit the previous session's create history.
  void reset() {
    _inFlight.clear();
    _attempted.clear();
  }
}
