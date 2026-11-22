// Each encoder and the decoder against what ECMA-262's `encodeURIComponent`, `encodeURI` and `decodeURIComponent`
// give in Node (every ASCII byte, UTF-8 of two to four bytes, a surrogate pair, a lone surrogate either way), what the
// decoder refuses as they throw, a caller's own set with a form's `+`, and the way back. On both targets.

///|
/// Every ASCII code unit in turn.
fn ascii() -> String {
  let s = StringBuilder()
  for i in 0..<128 {
    s.write_char(i.unsafe_to_char())
  }
  s.to_string()
}

///|
/// `before`, a lone surrogate `unit`, then `after`.
fn lone(before : String, unit : Int, after : String) -> String {
  let s = StringBuilder()
  s.write_string(before)
  s.write_char(unit.unsafe_to_char())
  s.write_string(after)
  s.to_string()
}

///|
test "encode_uri_component and encode_uri write what ECMA-262's do" {
  let cases : Array[(String, String, String)] = [
    ("", "", ""),
    ("abcXYZ019", "abcXYZ019", "abcXYZ019"),
    ("-_.!~*'()", "-_.!~*'()", "-_.!~*'()"),
    (";,/?:@&=+$#", "%3B%2C%2F%3F%3A%40%26%3D%2B%24%23", ";,/?:@&=+$#"),
    (
      " %\"<>\\^`{|}[]", "%20%25%22%3C%3E%5C%5E%60%7B%7C%7D%5B%5D", "%20%25%22%3C%3E%5C%5E%60%7B%7C%7D%5B%5D",
    ),
    ("中文", "%E4%B8%AD%E6%96%87", "%E4%B8%AD%E6%96%87"),
    ("é🚀 中", "%C3%A9%F0%9F%9A%80%20%E4%B8%AD", "%C3%A9%F0%9F%9A%80%20%E4%B8%AD"),
    ("a\u{0}\u{7f}\u{80}", "a%00%7F%C2%80", "a%00%7F%C2%80"),
  ]
  for one in cases {
    assert_eq(@url.encode_uri_component(one.0), one.1)
    assert_eq(@url.encode_uri_component_strict(one.0), Some(one.1))
    assert_eq(@url.encode_uri(one.0), one.2)
  }
  assert_eq(
    @url.encode_uri_component(ascii()),
    "%00%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13%14%15%16%17%18%19%1A%1B%1C%1D%1E%1F%20!%22%23%24%25%26'()*%2B%2C-.%2F0123456789%3A%3B%3C%3D%3E%3F%40ABCDEFGHIJKLMNOPQRSTUVWXYZ%5B%5C%5D%5E_%60abcdefghijklmnopqrstuvwxyz%7B%7C%7D~%7F",
  )
  assert_eq(
    @url.encode_uri(ascii()),
    "%00%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13%14%15%16%17%18%19%1A%1B%1C%1D%1E%1F%20!%22#$%25&'()*+,-./0123456789:;%3C=%3E?@ABCDEFGHIJKLMNOPQRSTUVWXYZ%5B%5C%5D%5E_%60abcdefghijklmnopqrstuvwxyz%7B%7C%7D~%7F",
  )
}

///|
test "a lone surrogate is U+FFFD, or refused where strict, as ECMA-262 throws" {
  for unit in [0xD800, 0xDBFF, 0xDC00, 0xDFFF] {
    for at in [("", ""), ("a", ""), ("", "b"), ("x", "y")] {
      let s = lone(at.0, unit, at.1)
      assert_eq(@url.encode_uri_component_strict(s), None)
      let fffd = @url.encode_uri_component(at.0) + "%EF%BF%BD" + @url.encode_uri_component(at.1)
      assert_eq(@url.encode_uri_component(s), fffd)
      assert_eq(@url.encode_uri(s), fffd)
      assert_eq(@url.percent_encode(s, _ => true), at.0 + "%EF%BF%BD" + at.1)
    }
  }
  // a high surrogate before another high one, and a low one before a high one: each lone
  let two = lone(lone("", 0xD800, ""), 0xD83D, "")
  assert_eq(@url.encode_uri_component(two), "%EF%BF%BD%EF%BF%BD")
  let back = lone(lone("", 0xDE80, ""), 0xD83D, "")
  assert_eq(@url.encode_uri_component(back), "%EF%BF%BD%EF%BF%BD")
  assert_eq(@url.encode_uri_component_strict(back), None)
  // a pair written by its halves is one code point
  let pair = lone(lone("", 0xD83D, ""), 0xDE80, "")
  assert_eq(@url.encode_uri_component_strict(pair), Some("%F0%9F%9A%80"))
}

///|
test "decode_uri_component reads what ECMA-262's does, and refuses where it throws" {
  let read : Array[(String, String)] = [
    ("", ""),
    ("%41%4a%4A", "AJJ"),
    ("%E4%B8%AD", "中"),
    ("%F0%9F%9A%80", "🚀"),
    ("a+b%2B", "a+b+"),
    ("%2F%3f", "/?"),
    ("中 é", "中 é"),
    ("%C3%A9%F0%9F%9A%80%20%E4%B8%AD", "é🚀 中"),
  ]
  for one in read {
    assert_eq(@url.decode_uri_component(one.0), Some(one.1))
  }
  let refused = [
    "%", "%4", "%zz", "a%", "%%41", "%C0%80", "%E0%80%80", "%F0%80%80%80", "%ED%A0%80", "%ED%BF%BF", "%F4%90%80%80",
    "%80", "%BF", "%F8%88%80%80%80", "%FF", "%E4%B8", "%E4%B8%41", "%E4%B8x", "%E4%B8%A", "%F0%9F%9A",
  ]
  for one in refused {
    assert_eq(@url.decode_uri_component(one), None)
  }
  // a lone surrogate written as it is, not escaped, passes as it is
  let s = lone("a", 0xD800, "%41")
  assert_eq(@url.decode_uri_component(s), Some(lone("a", 0xD800, "A")))
}

///|
test "percent_encode keeps what its caller says, a space as + where asked" {
  let alnum = (b : Int) => (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
  assert_eq(@url.percent_encode("a b+c/中", alnum), "a%20b%2Bc%2F%E4%B8%AD")
  assert_eq(@url.percent_encode("a b+c/中", alnum, space_plus=true), "a+b%2Bc%2F%E4%B8%AD")
  // a space is a + where asked even if kept, and a byte past ASCII is encoded even if kept
  assert_eq(@url.percent_encode("a b é", _ => true, space_plus=true), "a+b+%C3%A9")
  assert_eq(@url.percent_encode("a b", _ => false), "%61%20%62")
  assert_eq(@url.percent_encode("", _ => false), "")
}

///|
test "what is encoded decodes back" {
  let texts = [
    "", "plain", "a b&c=d/e?f#g", "中文 é 🚀 ∑", ascii(), lone(lone("x", 0xD83D, ""), 0xDE80, "y"), "%41 is not A",
  ]
  for t in texts {
    assert_eq(@url.decode_uri_component(@url.encode_uri_component(t)), Some(t))
    assert_eq(@url.decode_uri_component(@url.percent_encode(t, _ => false)), Some(t))
  }
  // what decodes from a lone surrogate's U+FFFD
  assert_eq(@url.decode_uri_component(@url.encode_uri_component(lone("a", 0xDC00, ""))), Some("a\u{FFFD}"))
}

///|
test "percent_decode_lossy decodes %XX and optional + lossily" {
  assert_eq(@url.percent_decode_lossy("a+b%20%E4%B8%AD"), "a+b 中")
  assert_eq(@url.percent_decode_lossy("a+b%20%E4%B8%AD", plus_space=true), "a b 中")
  assert_eq(@url.percent_decode_lossy("100%25+%zz+%2", plus_space=true), "100% %zz %2")
  assert_eq(@url.percent_decode_lossy("%FF%41"), "\u{FFFD}A")
  assert_eq(@url.percent_decode_lossy(lone("a", 0xD800, "%20b")), "a\u{FFFD} b")
  assert_eq(@url.percent_decode_lossy(lone("a", 0xDC00, "+b"), plus_space=true), "a\u{FFFD} b")
  let pair = lone(lone("x", 0xD83D, ""), 0xDE80, "%21")
  assert_eq(@url.percent_decode_lossy(pair), "x🚀!")
}
