// JavaScript-semantics checks for the `eval:` interpreter in
// lib/src/utils/js_expression.dart.
//
// Frappe Desk evaluates `depends_on` / `mandatory_depends_on` /
// `read_only_depends_on` with `new Function(..., 'let out = <code>; return
// out')` (frappe/public/js/frappe/utils/utils.js `eval`). Every expected value
// below is what that real JavaScript evaluation returns, except where the
// library documents a deliberate DEPARTURE (bool<->0/1 bridging, numeric-text
// relational compare, number/numeric-string membership, non-mutating pop) —
// those are asserted as the documented contract.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/depends_on_evaluator.dart';
import 'package:frappe_mobile_sdk/src/utils/js_expression.dart';

Object? _ev(String src, [Map<String, Object?> doc = const {}]) =>
    evalJsExpression(src, {'doc': doc, 'parent': doc});

bool _b(String src, [Map<String, Object?> doc = const {}]) =>
    evalJsExpressionAsBool(src, {'doc': doc, 'parent': doc});

Matcher get _throwsJs => throwsA(isA<JsEvalException>());

void main() {
  group('arithmetic', () {
    test('+ adds numbers and concatenates when either side is a string', () {
      expect(_ev('1 + 2'), 3);
      expect(_ev("'a' + 1"), 'a1');
      expect(_ev("1 + '2'"), '12');
      expect(_ev('true + 1'), 2);
      expect(_ev('null + 1'), 1);
      expect(_ev("'x' + null"), 'xnull');
    });

    test('+ with undefined is NaN (falsy)', () {
      expect(_b('doc.missing + 1'), isFalse);
      expect((_ev('doc.missing + 1') as num).isNaN, isTrue);
    });

    test('- * / coerce operands to numbers', () {
      expect(_ev("'10' - 4"), 6);
      expect(_ev("'3' * '4'"), 12);
      expect(_ev('10 / 4'), 2.5);
      expect(_ev('1 / 0'), double.infinity);
      expect((_ev("'x' - 1") as num).isNaN, isTrue);
    });

    test('% follows JS remainder (sign of the dividend, NaN on zero)', () {
      expect(_ev('7 % 3'), 1);
      expect(_ev('-7 % 3'), -1);
      expect(_ev('5.5 % 2'), 1.5);
      expect((_ev('5 % 0') as num).isNaN, isTrue);
      expect(_b('5 % 0'), isFalse);
    });

    test('unary + and - coerce numeric text', () {
      expect(_ev("+'5'"), 5);
      expect(_ev("-'5'"), -5);
      expect(_ev('-doc.qty', {'qty': 3}), -3);
      expect((_ev("-'abc'") as num).isNaN, isTrue);
    });

    test('an integral double prints without ".0" when concatenated', () {
      expect(_ev("(4 / 2) + ''"), '2');
      expect(_ev("(5 / 2) + ''"), '2.5');
    });

    test('precedence: * binds tighter than +, + tighter than comparison', () {
      expect(_ev('1 + 2 * 3'), 7);
      expect(_b('1 + 2 * 3 == 7'), isTrue);
      expect(_ev('(1 + 2) * 3'), 9);
    });
  });

  group('comparison', () {
    test('two non-numeric strings compare lexicographically', () {
      expect(_b("'b' > 'a'"), isTrue);
      expect(_b("'abc' <= 'abd'"), isTrue);
      expect(_b("'abc' <= 'abc'"), isTrue);
      expect(_b("'b' >= 'c'"), isFalse);
      expect(_b("'b' < 'a'"), isFalse);
    });

    test('documented departure: two numeric strings compare as numbers', () {
      expect(_b("'10' > '9'"), isTrue);
      expect(_b('doc.a > doc.b', {'a': '10', 'b': '9'}), isTrue);
    });

    test('null coerces to 0 in relational compare; undefined does not', () {
      expect(_b('null >= 0'), isTrue);
      expect(_b('doc.missing >= 0'), isFalse);
      expect(_b('doc.missing < 0'), isFalse);
    });

    test('loose equality coerces like JS', () {
      expect(_b("'5' == 5"), isTrue);
      expect(_b("'' == 0"), isTrue);
      expect(_b("'0' == false"), isTrue);
      expect(_b('null == 0'), isFalse);
      expect(_b('null == undefined'), isTrue);
      expect(_b("'abc' == 1"), isFalse);
      expect(_b('[1] == 1'), isTrue);
      expect(_b("['A'] == 'A'"), isTrue);
      expect(_b("doc.x != 'Y'", {'x': 'Y'}), isFalse);
    });

    test('strict equality distinguishes null from undefined', () {
      expect(_b('null === null'), isTrue);
      expect(_b('undefined === undefined'), isTrue);
      expect(_b('null === undefined'), isFalse);
      expect(_b('doc.missing === undefined'), isTrue);
      expect(_b("'5' === 5"), isFalse);
      expect(_b("'5' !== 5"), isTrue);
    });

    test('documented departure: a Check held as bool equals 0/1', () {
      expect(_b('doc.flag === 1', {'flag': true}), isTrue);
      expect(_b('doc.flag == 0', {'flag': false}), isTrue);
    });

    test('an unknown global equals nothing, even an absent field', () {
      expect(_b('doc.owner == frappe.session.user'), isFalse);
      expect(_b('frappe.boot.developer_mode'), isFalse);
      expect(_b('!frappe.boot.developer_mode'), isTrue);
    });
  });

  group('logical operators and ternary', () {
    test('&& / || return an operand, not a bool', () {
      expect(_ev("doc.a || 'fallback'"), 'fallback');
      expect(_ev("doc.a || 'fallback'", {'a': 'set'}), 'set');
      expect(_ev("doc.a && 'next'", {'a': ''}), '');
      expect(_ev('(doc.rows || []).length'), 0);
    });

    test('ternary picks the alternate when the test is falsy', () {
      expect(_ev("doc.a ? 'yes' : 'no'"), 'no');
      expect(_ev("doc.a ? 'yes' : 'no'", {'a': 1}), 'yes');
    });

    test('nested ternary is right-associative', () {
      const src = "doc.a ? 'A' : doc.b ? 'B' : 'C'";
      expect(_ev(src, {'a': 0, 'b': 1}), 'B');
      expect(_ev(src, {'a': 0, 'b': 0}), 'C');
      expect(_ev(src, {'a': 1, 'b': 1}), 'A');
    });

    test('! has higher precedence than ==', () {
      // (!doc.a) == false  ->  true == false when a is unset
      expect(_b('!doc.a == false'), isFalse);
      expect(_b('!(doc.a == false)'), isTrue);
    });
  });

  group('truthiness', () {
    test('JS falsy set: 0, NaN, "", null, undefined, false', () {
      expect(jsTruthy(0), isFalse);
      expect(jsTruthy(double.nan), isFalse);
      expect(jsTruthy(''), isFalse);
      expect(jsTruthy(null), isFalse);
      expect(jsTruthy(JsUndefined.instance), isFalse);
      expect(jsTruthy(JsUnknownGlobal.instance), isFalse);
      expect(jsTruthy(false), isFalse);
    });

    test('"0", [] and {} are truthy', () {
      expect(jsTruthy('0'), isTrue);
      expect(jsTruthy(<Object?>[]), isTrue);
      expect(jsTruthy(<String, Object?>{}), isTrue);
      expect(jsTruthy(-1), isTrue);
    });
  });

  group('member access', () {
    test('.length on list, string, and a non-container', () {
      expect(
        _ev('doc.rows.length', {
          'rows': [1, 2, 3],
        }),
        3,
      );
      expect(_ev("'hello'.length"), 5);
      // JS: (5).length is undefined, not an error.
      expect(_b('doc.qty.length', {'qty': 5}), isFalse);
    });

    test('a field literally named length wins over the length rule', () {
      expect(_ev('doc.length', {'length': 12}), 12);
    });

    test('computed member and index access', () {
      expect(_ev("doc['status']", {'status': 'Open'}), 'Open');
      expect(
        _ev('doc.rows[1]', {
          'rows': ['a', 'b'],
        }),
        'b',
      );
      expect(
        _b('doc.rows[5]', {
          'rows': ['a'],
        }),
        isFalse,
      );
    });

    test('reading a property of undefined is an error (caller defaults)', () {
      expect(() => _ev('doc.missing.x'), _throwsJs);
      expect(() => _ev("doc.missing.includes('a')"), _throwsJs);
    });

    test('bare identifier resolves as a doc field (eval:fieldname form)', () {
      expect(_b('status', {'status': 'Open'}), isTrue);
      expect(_b("status == 'Open'", {'status': 'Open'}), isTrue);
      expect(_b('status', {'status': ''}), isFalse);
      expect(_b('not_a_field'), isFalse);
    });
  });

  group('string methods', () {
    test('trim / toLowerCase / toUpperCase', () {
      expect(_ev("'  hi '.trim()"), 'hi');
      expect(_ev("'AbC'.toLowerCase()"), 'abc');
      expect(_ev("'abc'.toUpperCase()"), 'ABC');
    });

    test('includes / indexOf / startsWith / endsWith', () {
      expect(_b("'abcdef'.includes('cd')"), isTrue);
      expect(_ev("'abc'.indexOf('c')"), 2);
      expect(_ev("'abc'.indexOf('z')"), -1);
      expect(_b("'abc'.startsWith('ab')"), isTrue);
      expect(_b("'abc'.endsWith('bc')"), isTrue);
      expect(_b("'abc'.endsWith('ab')"), isFalse);
    });

    test('split with a separator', () {
      expect(_ev("'a,b,c'.split(',')"), ['a', 'b', 'c']);
      expect(_ev("'img.png'.split('.').pop()"), 'png');
    });

    test(
      'split() with no argument returns the whole string as one element',
      () {
        // JS: 'a,b'.split() -> ['a,b']
        expect(_ev("'a,b'.split()"), ['a,b']);
        expect(_ev("'abc'.split().length"), 1);
      },
      skip:
          'BUG SDK-9 (P3): split() with no separator splits into characters '
          '(treated as split(""))',
    );

    test('an unsupported string method throws', () {
      expect(() => _ev("'abc'.replace('a', 'b')"), _throwsJs);
    });
  });

  group('array methods', () {
    final rows = <String, Object?>{
      'rows': [
        {'x': 1, 'y': 'one'},
        {'x': 2, 'y': 'two'},
        {'x': 3, 'y': 'three'},
      ],
    };

    test('find returns the first match or undefined', () {
      expect(_ev('doc.rows.find(r => r.x == 2).y', rows), 'two');
      expect(_b('doc.rows.find(r => r.x == 9)', rows), isFalse);
    });

    test('filter / map / join compose', () {
      expect(_ev('doc.rows.filter(r => r.x > 1).length', rows), 2);
      expect(_ev("doc.rows.map(r => r.y).join('|')", rows), 'one|two|three');
      expect(_ev('doc.rows.map((r, i) => i)', rows), [0, 1, 2]);
    });

    test('join defaults to a comma separator', () {
      expect(_ev('[1, 2, 3].join()'), '1,2,3');
    });

    test(
      'join renders null / undefined elements as empty strings',
      () {
        // JS: [null, 'a', undefined].join('-') -> '-a-'
        expect(_ev("[null, 'a', undefined].join('-')"), '-a-');
      },
      skip:
          'BUG SDK-8 (P3): join stringifies null/undefined as "null"/'
          '"undefined" instead of ""',
    );

    test('indexOf / includes use membership equality', () {
      expect(_ev("['a', 'b'].indexOf('b')"), 1);
      expect(_ev("['a', 'b'].indexOf('z')"), -1);
      // documented departure: number vs numeric string
      expect(_b("[5, 6].includes('5')"), isTrue);
      expect(_b("['05'].includes('5')"), isFalse);
    });

    test('some / every on an empty list', () {
      expect(_b('[].some(r => true)'), isFalse);
      expect(_b('[].every(r => false)'), isTrue);
    });

    test('pop reads the last element without mutating the list', () {
      final doc = <String, Object?>{
        'tags': ['a', 'b'],
      };
      expect(_ev('doc.tags.pop()', doc), 'b');
      expect(doc['tags'], ['a', 'b']);
      expect(_b('[].pop()'), isFalse);
    });

    test('a method that needs an arrow rejects a non-function argument', () {
      expect(() => _ev('[1].some(1)'), _throwsJs);
    });

    test('mutating array methods are not in the grammar', () {
      expect(() => _ev('doc.rows.push(1)', rows), _throwsJs);
      expect(() => _ev('doc.rows.sort()', rows), _throwsJs);
    });

    test('a method on a number is unsupported', () {
      expect(() => _ev('(5).toFixed(2)'), _throwsJs);
    });
  });

  group('Frappe helpers', () {
    test('in_list', () {
      expect(_b("in_list(['A', 'B'], doc.s)", {'s': 'B'}), isTrue);
      expect(_b("in_list(['A', 'B'], doc.s)", {'s': 'C'}), isFalse);
      expect(() => _ev("in_list(['A'])"), _throwsJs);
    });

    test('cint parses the leading integer like frappe cint', () {
      expect(_ev("cint('12abc')"), 12);
      expect(_ev("cint('3.9')"), 3);
      expect(_ev("cint('-4.7')"), -4);
      expect(_ev("cint('abc')"), 0);
      expect(_ev('cint(true)'), 1);
      expect(_ev('cint()'), 0);
      expect(_ev("cint('007')"), 7);
    });

    test('flt parses the leading float like frappe flt', () {
      expect(_ev("flt('1,200.5')"), 1200.5);
      expect(_ev("flt('12.5kg')"), 12.5);
      expect(_ev("flt('  3')"), 3.0);
      // A real TAB before the digits (no space, so no currency split).
      expect(_ev("flt('\t3')"), 3.0);
      expect(_ev('flt(null)'), 0.0);
      expect(_ev('flt()'), 0.0);
      expect(_ev("flt('Infinity')"), double.infinity);
      expect(_ev("flt('-Infinity')"), double.negativeInfinity);
    });

    test('cstr and Boolean', () {
      expect(_ev('cstr(null)'), '');
      expect(_ev('cstr(5)'), '5');
      expect(_ev('cstr()'), '');
      expect(_ev('cstr(doc)', {'a': 1}), '[object Object]');
      expect(_ev('cstr([1, [2, 3]])'), '1,2,3');
      expect(_ev("Boolean('')"), isFalse);
      expect(_ev("Boolean('x')"), isTrue);
      expect(_ev('Boolean()'), isFalse);
    });

    test('an unknown global function is unsupported', () {
      expect(() => _ev('frappe_fn(1)'), _throwsJs);
    });
  });

  group('parse errors', () {
    test('malformed sources throw JsEvalException', () {
      expect(() => _ev('"abc'), _throwsJs); // unterminated string
      expect(() => _ev('doc.a doc.b'), _throwsJs); // trailing tokens
      expect(() => _ev('(doc.a'), _throwsJs); // missing )
      expect(() => _ev('doc.(a)'), _throwsJs); // property name expected
      expect(() => _ev('(doc.a)(1)'), _throwsJs); // call of non-member
      expect(() => _ev('1.2.3'), _throwsJs); // bad number
      expect(() => _ev('doc.a @ 1'), _throwsJs); // unexpected char
    });

    test('a trailing statement terminator is tolerated', () {
      expect(_b("doc.x === 'Y';", {'x': 'Y'}), isTrue);
      expect(_b("doc.x === 'Y' ;;", {'x': 'Y'}), isTrue);
    });

    test('escaped quotes inside string literals', () {
      expect(_ev(r"'it\'s'"), "it's");
      expect(_ev(r'"say \"hi\""'), 'say "hi"');
    });

    test('exception text carries the expression when known', () {
      const bare = JsEvalException('boom');
      expect(bare.toString(), 'JsEvalException: boom');
      const withSrc = JsEvalException('boom', 'doc.x');
      expect(withSrc.toString(), 'JsEvalException: boom (in "doc.x")');
      expect(JsUndefined.instance.toString(), 'undefined');
      expect(JsUnknownGlobal.instance.toString(), 'undefined');
    });
  });

  group('jsReferencedFields', () {
    test('walks ternaries and unary operands', () {
      expect(jsReferencedFields("doc.a ? doc.b : -doc.c"), {'a', 'b', 'c'});
    });

    test('excludes arrow parameters and parent fields', () {
      expect(
        jsReferencedFields("(doc.rows || []).some(r => r.x == parent.y)"),
        {'rows'},
      );
    });

    test('a bare identifier is a field reference; helpers are not', () {
      expect(jsReferencedFields("in_list(['A'], status)"), {'status'});
    });

    test('a computed member walks its key expression', () {
      expect(jsReferencedFields('doc.map[doc.key]'), {'map', 'key'});
    });

    test('a root outside doc/parent makes the set undeterminable', () {
      expect(() => jsReferencedFields('locals.x'), _throwsJs);
    });
  });

  group('DependsOnEvaluator wrapper', () {
    setUp(DependsOnEvaluator.resetLogGateForTest);

    test('an unparseable eval: falls back to the caller default', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.a @ 1', const {}), isTrue);
      expect(
        DependsOnEvaluator.evaluate(
          'eval:doc.a @ 1',
          const {},
          defaultOnError: false,
        ),
        isFalse,
      );
    });

    test('a runtime error (property of undefined) falls back too', () {
      expect(
        DependsOnEvaluator.evaluate(
          'eval:doc.missing.x == 1',
          const {},
          defaultOnError: false,
        ),
        isFalse,
      );
    });

    test('bare shorthand applies the array rule; eval: does not', () {
      final data = <String, dynamic>{'tags': <Object?>[]};
      expect(DependsOnEvaluator.evaluate('tags', data), isFalse);
      expect(DependsOnEvaluator.evaluate('eval:doc.tags', data), isTrue);
    });

    test('docstatus defaults to 0 and __islocal to 1 on an unsaved doc', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.docstatus === 0', const {}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.__islocal', const {}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.__islocal', {'name': 'T-1'}),
        isTrue,
      );
    });

    test('referencedFields falls back to a doc. token scan for JSON', () {
      expect(
        DependsOnEvaluator.referencedFields('{"district": "eval:doc.state"}'),
        {'state'},
      );
    });

    test('referencedFields of a bare word that does not parse', () {
      // `1abc` does not tokenize as one identifier, so the AST path fails and
      // the bare-word fallback answers.
      expect(DependsOnEvaluator.referencedFields('1abc'), {'1abc'});
    });
  });
}
