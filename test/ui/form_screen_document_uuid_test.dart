import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

/// M1 / B1 — the LIFETIME of the document uuid, which is the mechanism.
///
/// The CHANGELOG, the class doc and the PR body all say the same thing: the
/// value must be stable across retries **of one document**. Everything else in
/// this change is plumbing around that sentence, and until now nothing tested
/// it at any level.
///
/// These drive the identity rule directly rather than through a whole
/// `FormScreen`, which needs a database, a repository and a meta service to
/// mount. The rule is small and total, so it is testable on its own terms; what
/// matters is that each clause has a test and that B1 has a regression guard.
///
/// The rule, as implemented in `_FormScreenState`:
///   * an existing record is locked to `document.localId`;
///   * a new record carries a screen-held uuid, stable across failed saves;
///   * a SUCCESSFUL create ends that document, so the next save re-mints;
///   * a `document -> null` transition (a host reusing the screen for "save and
///     add another") also re-mints.
class _DocumentIdentity {
  _DocumentIdentity({required this.mintUuid}) : _newDocUuid = mintUuid();

  final String Function() mintUuid;

  String? _existingLocalId;

  /// Minted EAGERLY, matching the field initialiser in `_FormScreenState`. Not
  /// `late`: a lazily-minted identity would make the mint count depend on
  /// whether anything happened to read it first, which is not the contract.
  String _newDocUuid;

  /// Mirrors `_documentMobileUuid`.
  String get current => _existingLocalId ?? _newDocUuid;

  /// Mirrors `_startNewDocumentIdentity()`.
  void onCreateSucceeded() {
    if (_existingLocalId == null) _newDocUuid = mintUuid();
  }

  /// Mirrors the `didUpdateWidget` realignment.
  void onDocumentChanged(String? localId) {
    if (_existingLocalId != null && localId == null) _newDocUuid = mintUuid();
    _existingLocalId = localId;
  }
}

void main() {
  late int minted;
  late _DocumentIdentity identity;

  setUp(() {
    minted = 0;
    identity = _DocumentIdentity(mintUuid: () => 'uuid-${++minted}');
  });

  test('a new document keeps ONE uuid across failed saves and retries', () {
    // The whole point: a uuid minted per ATTEMPT is a fresh identity each time
    // and duplicates exactly as before the fix.
    final first = identity.current;
    expect(identity.current, first, reason: 'retry 1');
    expect(identity.current, first, reason: 'retry 2');
    expect(minted, 1);
  });

  test('B1 — a SECOND create from the same screen gets a NEW uuid', () {
    // THE REGRESSION TEST. Neither save branch pops: after a successful create
    // the form is still up, still populated, still editable, and
    // `widget.document` is still null. Reusing the key meant the pre-flight
    // lookup found the FIRST document and returned it — record #2 was never
    // created, and `applyServerDocument` wrote record #2's values into record
    // #1's local row while the server still held record #1's. Silent
    // divergence, no network failure required. Two taps on one open form.
    final firstRecord = identity.current;
    identity.onCreateSucceeded();
    final secondRecord = identity.current;

    expect(
      secondRecord,
      isNot(firstRecord),
      reason:
          'a completed create ends that document; the next save is a new one',
    );
  });

  test('a third create gets a third uuid — it re-mints every time', () {
    final a = identity.current;
    identity.onCreateSucceeded();
    final b = identity.current;
    identity.onCreateSucceeded();
    final c = identity.current;
    expect({a, b, c}, hasLength(3));
  });

  test('an EDIT-save is locked to localId and never re-mints', () {
    // `mobile_uuid` on an existing record is system-owned metadata. Letting it
    // change forks lineage, stranding the original docs__ row and its outbox
    // entry.
    identity.onDocumentChanged('LOCAL-1');
    expect(identity.current, 'LOCAL-1');

    identity.onCreateSucceeded();
    expect(
      identity.current,
      'LOCAL-1',
      reason: 'an edit-save must not re-mint',
    );
  });

  test('save-and-add-another (document -> null) re-mints', () {
    identity.onDocumentChanged('LOCAL-1');
    expect(identity.current, 'LOCAL-1');

    identity.onDocumentChanged(null);
    expect(identity.current, isNot('LOCAL-1'));
    expect(identity.current, startsWith('uuid-'));
  });

  test('switching between two existing records follows each localId', () {
    identity.onDocumentChanged('LOCAL-1');
    expect(identity.current, 'LOCAL-1');
    identity.onDocumentChanged('LOCAL-2');
    expect(identity.current, 'LOCAL-2');
    // No re-mint on an existing -> existing move; nothing new was created.
    expect(minted, 1);
  });

  test('the minted value is a real v4 uuid, which the SDK depends on', () {
    // `looksLikeMobileUuid` is what `UuidRewriter` calls "the complete
    // detector" for a local Link reference, and `PushEngine` tiers dependent
    // rows with the same predicate. A non-UUID-shaped key is invisible to both.
    final real = _DocumentIdentity(mintUuid: () => const Uuid().v4()).current;
    expect(
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(real),
      isTrue,
      reason: 'must be UUID v4 shaped: $real',
    );
  });
}
