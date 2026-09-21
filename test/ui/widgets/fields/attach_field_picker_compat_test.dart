import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';

/// Stands in for file_picker 11's `FilePickerResult`, whose selection hangs off
/// `.files`. Duck-typed on purpose: `pickedFilesOf` reaches `.files`
/// dynamically, so the real class is not needed to prove the branch — and the
/// real class does not exist in 12.x/13.x, so it could not be referenced here
/// without breaking the build at that end.
class _LegacyResult {
  _LegacyResult(this.files);
  final List<Object?> files;
}

/// Stands in for `PlatformFile`, of which only `.path` is read.
class _Picked {
  _Picked(this.path);
  final String? path;
}

class _Bogus {
  final String files = 'not a list';
}

void main() {
  group('pickedFilesOf — file_picker 11 vs 12/13 result shapes', () {
    test('12.x/13.x shape: a List is passed straight through', () {
      final sel = <Object?>['a', 'b'];
      expect(pickedFilesOf(sel), same(sel));
    });

    test('12.x/13.x cancel: an empty List stays empty', () {
      expect(pickedFilesOf(<Object?>[]), isEmpty);
    });

    test('11.x shape: the wrapper is unwrapped to .files', () {
      expect(pickedFilesOf(_LegacyResult(<Object?>['x'])), <Object?>['x']);
    });

    test('11.x cancel: null reads as no selection', () {
      expect(pickedFilesOf(null), isEmpty);
    });

    test('a multi-file selection is passed through intact, not truncated', () {
      // 12.x and 13.x removed `allowMultiple`, so this is reachable in normal
      // use. The shim must not silently drop the extras — deciding what to do
      // with them belongs to pickedPathOf.
      expect(pickedFilesOf(<Object?>['a', 'b', 'c']), hasLength(3));
      expect(pickedFilesOf(_LegacyResult(<Object?>['a', 'b'])), hasLength(2));
    });

    test('an unrecognised shape reads as cancel, never throws', () {
      // A picker we cannot interpret must not take the form down — the field
      // stays empty, which is the cancel path.
      expect(pickedFilesOf(_Bogus()), isEmpty);
      expect(pickedFilesOf(42), isEmpty);
    });
  });

  group('pickedPathOf — one path out of any selection', () {
    test('REGRESSION: two files yield the first, and do not throw', () {
      // This is the defect. `.single` on a 2-element selection threw
      // StateError, which the call site's catch-all reported as a generic
      // "attach failed" — so picking two files silently attached nothing.
      final sel = <Object?>[_Picked('/tmp/a.pdf'), _Picked('/tmp/b.pdf')];
      expect(pickedPathOf(sel), '/tmp/a.pdf');
      expect(pickedPathOf(_LegacyResult(sel)), '/tmp/a.pdf');
    });

    test('one file yields its path, in both result shapes', () {
      expect(
        pickedPathOf(<Object?>[_Picked('/tmp/only.pdf')]),
        '/tmp/only.pdf',
      );
      expect(
        pickedPathOf(_LegacyResult(<Object?>[_Picked('/tmp/only.pdf')])),
        '/tmp/only.pdf',
      );
    });

    test('cancel yields null in both shapes', () {
      expect(pickedPathOf(null), isNull);
      expect(pickedPathOf(<Object?>[]), isNull);
    });

    test('a selection whose entry has no usable path yields null', () {
      // file_picker 13 derives `path` from a URI and returns null for a
      // non-`file:` scheme, so a null path is reachable rather than theoretical.
      expect(pickedPathOf(<Object?>[_Picked(null)]), isNull);
    });

    test('an entry that is not a picked file yields null, never throws', () {
      expect(pickedPathOf(<Object?>[42]), isNull);
      expect(pickedPathOf(_Bogus()), isNull);
    });
  });
}
