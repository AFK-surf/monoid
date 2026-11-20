// Upstream nst/JSONTestSuite (commit 1ef36fa01286573e846ac449e8683f8833c5b26a, MIT)
// regression & boundary tests for @jsjson.
// Full 318-file corpus is also cross-checked live against Node JSON.parse in station/test/mb-upstream-corpora.test.ts.

///|
test "upstream JSONTestSuite: tricky y_ valid structures, numbers, unicode" {
  let valid : Array[(String, String)] = [
    // y_array_arraysWithSpaces, y_array_empty-string, y_array_heterogeneous
    ("[[]   ]", "[[]]"),
    ("[\"\"]", "[\"\"]"),
    ("[null, 1, \"1\", {}]", "[null,1,\"1\",{}]"),
    // y_number_double_close_to_zero, y_number_int_with_exp, y_number_real_capital_e_neg_exp
    ("[-0.000000000000000000000000000000000000000000000000000000000000000000000000000001]", "[-1e-78]"),
    ("[20e1]", "[200]"),
    ("[1E-2]", "[0.01]"),
    // y_object_duplicated_key_and_value, y_object_extreme_numbers
    ("{\"a\":\"b\",\"a\":\"b\"}", "{\"a\":\"b\"}"),
    ("{\"min\": -1.0e+28, \"max\": 1.0e+28}", "{\"min\":-1e+28,\"max\":1e+28}"),
    // y_string_nonCharacterInUTF-8_U+10FFFF, y_string_nbsp_uescaped, y_string_pi
    ("[\"\\u00A0\"]", "[\"\u{00A0}\"]"),
    ("[\"π\"]", "[\"π\"]"),
    ("[\"\\u0020\"]", "[\" \"]"),
    ("[\"\\u002F\"]", "[\"/\"]"),
    // y_string_1_2_3_bytes_UTF-8_sequences
    ("[\"\\u0060\\u012a\\u12AB\"]", "[\"`Ī\u{12AB}\"]"),
  ]
  for c in valid {
    assert_eq(@jsjson.stringify(@jsjson.parse(c.0)), c.1)
  }
}

///|
test "upstream JSONTestSuite: n_ invalid vectors and i_ 500 nested arrays" {
  // i_structure_500_nested_arrays.json: 500 levels must succeed (max_parse_depth = 1024)
  let depth500 = "[".repeat(500) + "]".repeat(500)
  assert_eq(@jsjson.stringify(@jsjson.parse(depth500)), depth500)

  // n_structure_100000_opening_arrays.json: must reject cleanly without stack overflow
  let bad_cases = [
    "[".repeat(2000),
    "[1,2,3,]",
    "{\"a\":1,}",
    "[0e]",
    "[0e+]",
    "[1.0e-]",
    "[-.123]",
    "[-01]",
    "[0x42]",
    "[1+2]",
    "{\"x\"::\"b\"}",
    "{\"a\":\"b\"\"c\":\"d\"}",
    "[\"\\u00A\"]",
    "[\"\\uZZZZ\"]",
    "[\"\\x00\"]",
    "[\"a\u{0000}a\"]",
    "[\"\t\"]",
    "[\"\n\"]",
    "[\u{000c}1]",
    "[\u{000b}1]",
    "[\u{00a0}1]",
  ]
  for s in bad_cases {
    let ok = (try Some(@jsjson.parse(s)) catch { _ => None }) is Some(_)
    if ok {
      fail("expected rejection for: \{repr(s)}")
    }
  }
}
