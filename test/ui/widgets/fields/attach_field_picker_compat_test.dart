import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';

/// Stands in for file_picker 11/12's `FilePickerResult`, whose selection hangs
/// off `.files`. Duck-typed on purpose: `pickedFilesOf` reaches `.files`
/// dynamically, so the real class is not needed to prove the branch.
class _LegacyResult {
  _LegacyResult(this.files);
  final List<Object?> files;
}

class _Bogus {
  final String files = 'not a list';
}

void main() {
  group('pickedFilesOf — file_picker 11/12/13 compatibility', () {
    test('13.x shape: a List is passed straight through', () {
      final sel = <Object?>['a', 'b'];
      expect(pickedFilesOf(sel), same(sel));
    });

    test('13.x cancel: an empty List stays empty', () {
      expect(pickedFilesOf(<Object?>[]), isEmpty);
    });

    test('11/12 shape: the wrapper is unwrapped to .files', () {
      expect(pickedFilesOf(_LegacyResult(<Object?>['x'])), <Object?>['x']);
    });

    test('11/12 cancel: null reads as no selection', () {
      expect(pickedFilesOf(null), isEmpty);
    });

    test('an unrecognised shape reads as cancel, never throws', () {
      // A picker we cannot interpret must not take the form down — the field
      // stays empty, which is the cancel path.
      expect(pickedFilesOf(_Bogus()), isEmpty);
      expect(pickedFilesOf(42), isEmpty);
    });
  });
}
