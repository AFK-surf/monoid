// JSONTestSuite (y_, n_, i_) & Node.js JSON.parse/JSON.stringify conformance tests for @jsjson.

///|
fn can_parse(s : String) -> Bool {
  (try Some(@jsjson.parse(s)) catch { _ => None }) is Some(_)
}

///|
test "conformance: JSONTestSuite y_ valid vectors" {
  let valid : Array[(String, String)] = [
    ("[]", "[]"),
    ("{}", "{}"),
    ("true", "true"),
    ("false", "false"),
    ("null", "null"),
    ("0", "0"),
    ("-0", "0"),
    ("-0.0", "0"),
    ("-0e0", "0"),
    ("0e0", "0"),
    ("0e+1", "0"),
    ("0e-1", "0"),
    ("123e65", "1.23e+67"),
    ("1e-2", "0.01"),
    ("1e+2", "100"),
    ("1E2", "100"),
    ("1E+2", "100"),
    ("1E-2", "0.01"),
    ("123.456e-78", "1.23456e-76"),
    ("0.0000001", "1e-7"),
    ("1e-400", "0"),
    ("-1e-400", "0"),
    ("0e999999", "0"),
    ("-0e999999", "0"),
    ("0.0e999999", "0"),
    ("1e400", "null"),
    ("-1e400", "null"),
    // 401-digit integer without 'e' overflows to Infinity -> stringifies as null (matches Node JSON.parse)
    ("1" + "0".repeat(400), "null"),
    ("-1" + "0".repeat(400), "null"),
    // Whitespace: SP, HT, LF, CR only
    (" \t\r\n [ \t\r\n 1 \t\r\n , \t\r\n 2 \t\r\n ] \t\r\n ", "[1,2]"),
    // String escapes & unicode
    ("\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"", "\"\\\"\\\\/\\b\\f\\n\\r\\t\""),
    ("\"\\u0000\\u001f\"", "\"\\u0000\\u001f\""),
    ("\"\\u0061\\u0062\"", "\"ab\""),
    // Surrogate pair U+1F600 -> literal UTF-16 pair (round-trips as emoji)
    ("\"\\uD83D\\uDE00\"", "\"😀\""),
    // Non-BMP literal
    ("\"😀\"", "\"😀\""),
    // Empty key
    ("{\"\":0}", "{\"\":0}"),
    // Duplicate key keeps first position and last value
    ("{\"a\":1,\"b\":2,\"a\":3}", "{\"a\":3,\"b\":2}"),
    // Integer-like array index keys sorted ascending before string keys (2^32-2 is index, 2^32-1 is not)
    ("{\"b\":1,\"4294967295\":2,\"4294967294\":3,\"0\":4,\"01\":5,\"2\":6}", "{\"0\":4,\"2\":6,\"4294967294\":3,\"b\":1,\"4294967295\":2,\"01\":5}"),
  ]
  for c in valid {
    let parsed = @jsjson.parse(c.0)
    assert_eq(@jsjson.stringify(parsed), c.1)
  }
}

///|
test "conformance: JSONTestSuite i_ implementation-defined (surrogates, -0, huge exponents)" {
  // Lone high surrogate \uD800 preserved as code unit 0xD800 and escaped on stringify (matches Node)
  let hi = @jsjson.parse("\"\\uD800\"")
  assert_eq(@jsjson.stringify(hi), "\"\\ud800\"")
  // Lone low surrogate \uDFFF preserved as code unit 0xDFFF and escaped on stringify
  let lo = @jsjson.parse("\"\\uDFFF\"")
  assert_eq(@jsjson.stringify(lo), "\"\\udfff\"")
  // Reversed surrogate pair \uDE00\uD83D preserved as two lone surrogates
  let rev = @jsjson.parse("\"\\uDE00\\uD83D\"")
  assert_eq(@jsjson.stringify(rev), "\"\\ude00\\ud83d\"")
  // High + valid surrogate pair: first stays escaped, pair becomes emoji
  let hpair = @jsjson.parse("\"\\uD800\\uD83D\\uDE00\"")
  assert_eq(@jsjson.stringify(hpair), "\"\\ud800😀\"")
  // -0 preserves sign bit in Num(-0.0) and stringifies as "0"
  match @jsjson.parse("-0") {
    Num(d) => {
      assert_eq(d, 0.0)
      assert_true(1.0 / d < 0.0)
      assert_eq(@jsjson.stringify(Num(d)), "0")
    }
    _ => fail("expected Num")
  }
  // 0e999999 is 0.0, NOT Infinity; -0e999999 is -0.0, NOT -Infinity
  match @jsjson.parse("0e999999") {
    Num(d) => {
      assert_eq(d, 0.0)
      assert_true(!d.is_inf())
    }
    _ => fail("expected Num")
  }
  match @jsjson.parse("-0e999999") {
    Num(d) => {
      assert_eq(d, 0.0)
      assert_true(!d.is_inf())
      assert_true(1.0 / d < 0.0)
    }
    _ => fail("expected Num")
  }
}

///|
test "conformance: JSONTestSuite n_ invalid vectors must all be rejected" {
  let invalid = [
    // Empty / whitespace only
    "", " ", "\t\r\n",
    // Trailing garbage
    "true false", "1 2", "{}[]", "[]]", "{}}",
    // Leading zeros
    "01", "-01", "00", "01.5", "-00.5",
    // Leading plus / missing digits / bare dot
    "+1", "+0", ".5", "-.5", "1.", "-1.", "1.e1", "-", "0e", "0e+", "0e-", "1e", "1E+", "1E-", "1.2.3",
    // Non-JSON numbers
    "NaN", "Infinity", "-Infinity", "0x10", "0b10", "0o10",
    // Trailing commas & missing commas/colons
    "[1,]", "[,]", "[1,,2]", "[1 2]", "{\"a\":1,}", "{,}", "{\"a\":1 \"b\":2}", "{\"a\" 1}", "{:1}",
    // Unquoted / single-quoted strings & keys
    "'abc'", "{a:1}", "{'a':1}",
    // Unclosed structures & strings
    "[", "{", "\"abc", "\"abc\\\"", "[1,2", "{\"a\":1",
    // Bad escapes
    "\"\\a\"", "\"\\x41\"", "\"\\u123\"", "\"\\u123g\"", "\"\\u\"", "\"\\\"", "\"\\0\"", "\"\\'\"",
    // Unescaped control characters U+0000..U+001F
    "\"\u{0000}\"", "\"\u{0001}\"", "\"\u{0008}\"", "\"\u{0009}\"", "\"\u{000a}\"", "\"\u{000d}\"", "\"\u{001f}\"",
    // Non-JSON whitespace (NBSP U+00A0, BOM U+FEFF, form feed U+000C, vertical tab U+000B)
    "\u{00a0}1", "\u{feff}1", "\u{000c}1", "\u{000b}1",
    // Bad literals & comments
    "True", "FALSE", "NULL", "undefined", "tru", "fals", "nul", "// comment\n1", "/* comment */1",
  ]
  for s in invalid {
    if can_parse(s) {
      fail("should have rejected invalid JSON: \{repr(s)}")
    }
  }
}

///|
test "conformance: deep nesting does not stack-overflow" {
  // 200 levels of nested arrays & objects must parse and stringify cleanly
  let open200 = "[".repeat(200) + "1" + "]".repeat(200)
  let v = @jsjson.parse(open200)
  assert_eq(@jsjson.stringify(v), open200)
  // Extreme nesting (10,000 deep) must fail cleanly with SyntaxError rather than crashing with stack overflow
  let deep = "[".repeat(10000) + "1" + "]".repeat(10000)
  let ok = try {
    let _ = @jsjson.parse(deep)
    true
  } catch {
    _ => false
  }
  assert_eq(ok, false)
}
