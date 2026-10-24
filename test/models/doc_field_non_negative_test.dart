import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';

/// Frappe's `non_negative` docfield flag (Int / Float / Currency / Percent).
/// The server rejects a negative value on save (`Document._validate_non_negative`),
/// so the form has to know about the flag to stop the save before it syncs.
void main() {
  group('DocField.nonNegative', () {
    test('non_negative=1 / true / "1" → true', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [
          {'fieldname': 'a', 'fieldtype': 'Float', 'non_negative': 1},
          {'fieldname': 'b', 'fieldtype': 'Int', 'non_negative': true},
          {'fieldname': 'c', 'fieldtype': 'Currency', 'non_negative': '1'},
        ],
      });
      expect(m.fields.map((f) => f.nonNegative), everyElement(isTrue));
    });

    test('non_negative=0 / absent → false', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [
          {'fieldname': 'a', 'fieldtype': 'Float', 'non_negative': 0},
          {'fieldname': 'b', 'fieldtype': 'Float'},
        ],
      });
      expect(m.fields.map((f) => f.nonNegative), everyElement(isFalse));
    });

    test('accepts the camelCase alias', () {
      final f = DocField.fromJson({
        'fieldname': 'a',
        'fieldtype': 'Float',
        'nonNegative': true,
      });
      expect(f.nonNegative, isTrue);
    });

    test('toJson writes non_negative and a round trip keeps it', () {
      final f = DocField.fromJson({
        'fieldname': 'a',
        'fieldtype': 'Float',
        'non_negative': 1,
      });
      expect(f.toJson()['non_negative'], 1);
      expect(DocField.fromJson(f.toJson()).nonNegative, isTrue);
    });

    test('an edited field serialises its own flag, not a stale raw one', () {
      final raw = {'fieldname': 'a', 'fieldtype': 'Float', 'nonNegative': 1};
      final edited = DocField(
        fieldname: 'a',
        fieldtype: 'Float',
        nonNegative: false,
        rawData: raw,
      );
      final json = edited.toJson();
      expect(json['non_negative'], 0);
      expect(json.containsKey('nonNegative'), isFalse);
      expect(DocField.fromJson(json).nonNegative, isFalse);
    });
  });
}
