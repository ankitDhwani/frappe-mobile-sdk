import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/link_search_policy.dart';

void main() {
  // Variables, not literals: a failing assert in a const invocation is a
  // compile error, and these must fail at run time.
  final zero = 0;
  final one = 1;
  final two = 2;

  test('the defaults and the disabled policy are valid', () {
    expect(const LinkSearchPolicy().prefetchSize, 10);
    expect(const LinkSearchPolicy().pageLength, 20);
    expect(LinkSearchPolicy.disabled.enabled, isFalse);
  });

  test('pageLength 0 is refused: Frappe reads limit_page_length=0 as "no '
      'limit"', () {
    expect(() => LinkSearchPolicy(pageLength: zero), throwsAssertionError);
    expect(LinkSearchPolicy(pageLength: one).pageLength, 1);
  });

  test('prefetchSize below 2 is refused: a one-row first page could not tell '
      '"the only match" from "the first of many"', () {
    expect(() => LinkSearchPolicy(prefetchSize: zero), throwsAssertionError);
    expect(() => LinkSearchPolicy(prefetchSize: one), throwsAssertionError);
    expect(LinkSearchPolicy(prefetchSize: two).prefetchSize, 2);
  });
}
