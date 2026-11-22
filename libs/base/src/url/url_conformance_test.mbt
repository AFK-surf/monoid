// ECMA-262 & RFC 3986 percent-encoding conformance tests for @url.
// Scope note: this package implements ECMA-262 encodeURIComponent / encodeURI /
// decodeURIComponent and RFC 3986 / x-www-form-urlencoded percent-encoding.

///|
fn make_lone(unit : Int) -> String {
  let s = StringBuilder()
  s.write_char(unit.unsafe_to_char())
  s.to_string()
}

///|
test "conformance: RFC 3986 unreserved vs reserved vs sub-delims" {
  // RFC 3986 §2.3 unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~"
  // ECMA-262 uriUnescaped adds: "!" / "'" / "(" / ")" / "*"
  assert_eq(@url.encode_uri_component("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"), "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
  // RFC 3986 gen-delims: : / ? # [ ] @
  // encodeURIComponent encodes all of them; encodeURI keeps : / ? # @ but encodes [ ]
  assert_eq(@url.encode_uri_component(":/?#[]@"), "%3A%2F%3F%23%5B%5D%40")
  assert_eq(@url.encode_uri(":/?#[]@"), ":/?#%5B%5D@")
  // RFC 3986 sub-delims: ! $ & ' ( ) * + , ; =
  assert_eq(@url.encode_uri_component("!$&'()*+,;="), "!%24%26'()*%2B%2C%3B%3D")
  assert_eq(@url.encode_uri("!$&'()*+,;="), "!$&'()*+,;=")
  // Characters always percent-encoded in both
  assert_eq(@url.encode_uri_component(" \"%<>\\^`{|}"), "%20%22%25%3C%3E%5C%5E%60%7B%7C%7D")
  assert_eq(@url.encode_uri(" \"%<>\\^`{|}"), "%20%22%25%3C%3E%5C%5E%60%7B%7C%7D")
}

///|
test "conformance: UTF-8 boundary code points across 1/2/3/4 byte ranges" {
  // 1-byte boundaries: U+0000, U+001F, U+007F
  assert_eq(@url.encode_uri_component("\u{0000}\u{001F}\u{007F}"), "%00%1F%7F")
  assert_eq(@url.decode_uri_component("%00%1F%7F"), Some("\u{0000}\u{001F}\u{007F}"))
  // 2-byte boundaries: U+0080 (C2 80), U+07FF (DF BF)
  assert_eq(@url.encode_uri_component("\u{0080}\u{07FF}"), "%C2%80%DF%BF")
  assert_eq(@url.decode_uri_component("%C2%80%DF%BF"), Some("\u{0080}\u{07FF}"))
  // 3-byte boundaries: U+0800 (E0 A0 80), U+D7FF (ED 9F BF), U+E000 (EE 80 80), U+FFFF (EF BF BF)
  assert_eq(@url.encode_uri_component("\u{0800}\u{D7FF}\u{E000}\u{FFFF}"), "%E0%A0%80%ED%9F%BF%EE%80%80%EF%BF%BF")
  assert_eq(@url.decode_uri_component("%E0%A0%80%ED%9F%BF%EE%80%80%EF%BF%BF"), Some("\u{0800}\u{D7FF}\u{E000}\u{FFFF}"))
  // 4-byte boundaries: U+10000 (F0 90 80 80), U+10FFFF (F4 8F BF BF)
  assert_eq(@url.encode_uri_component("\u{10000}\u{10FFFF}"), "%F0%90%80%80%F4%8F%BF%BF")
  assert_eq(@url.decode_uri_component("%F0%90%80%80%F4%8F%BF%BF"), Some("\u{10000}\u{10FFFF}"))
  // Lowercase hex in input decodes identically to uppercase
  assert_eq(@url.decode_uri_component("%f0%90%80%80%f4%8f%bf%bf"), Some("\u{10000}\u{10FFFF}"))
}

///|
test "conformance: decode_uri_component rejects all invalid UTF-8 and malformed escapes" {
  let invalid = [
    // Truncated percent escapes
    "%", "%0", "%A", "abc%", "abc%1", "%G0", "%0G", "%-1", "%+1", "% 0",
    // Unexpected continuation bytes (0x80..0xBF)
    "%80", "%9F", "%BF",
    // Overlong 2-byte sequences (C0 xx, C1 xx)
    "%C0%80", "%C0%AF", "%C1%BF",
    // Overlong 3-byte sequences (E0 80..9F xx)
    "%E0%80%80", "%E0%9F%BF",
    // Overlong 4-byte sequences (F0 80..8F xx xx)
    "%F0%80%80%80", "%F0%8F%BF%BF",
    // UTF-16 surrogates encoded in UTF-8 (ED A0 80 .. ED BF BF)
    "%ED%A0%80", "%ED%AD%BF", "%ED%AE%80", "%ED%BF%BF",
    // Above U+10FFFF (F4 90 80 80 .. F7 BF BF BF) and 5/6-byte prefixes (F8..FF)
    "%F4%90%80%80", "%F5%80%80%80", "%F8%80%80%80%80", "%FC%80%80%80%80%80", "%FE", "%FF",
    // Truncated multi-byte sequences
    "%C2", "%E0%A0", "%F0%90", "%F0%90%80",
    // Non-continuation byte following valid lead byte
    "%C2%00", "%C2%C0", "%C2a", "%E0%A0%00", "%E0%A0z", "%F0%90%80%7F", "%F0%90%80x",
  ]
  for s in invalid {
    assert_eq(@url.decode_uri_component(s), None)
  }
}

///|
test "conformance: surrogate pairs and lone surrogates in strict vs lossy modes" {
  // Valid surrogate pair: U+1F600 = D83D DE00 -> F0 9F 98 80
  let pair = make_lone(0xD83D) + make_lone(0xDE00)
  assert_eq(@url.encode_uri_component(pair), "%F0%9F%98%80")
  assert_eq(@url.encode_uri_component_strict(pair), Some("%F0%9F%98%80"))
  assert_eq(@url.encode_uri(pair), "%F0%9F%98%80")
  // High surrogate at end of string
  let hi_end = "ok" + make_lone(0xD800)
  assert_eq(@url.encode_uri_component_strict(hi_end), None)
  assert_eq(@url.encode_uri_component(hi_end), "ok%EF%BF%BD")
  // High surrogate followed by non-surrogate ASCII
  let hi_ascii = make_lone(0xDBFF) + "A"
  assert_eq(@url.encode_uri_component_strict(hi_ascii), None)
  assert_eq(@url.encode_uri_component(hi_ascii), "%EF%BF%BDA")
  // Low surrogate at start
  let lo_start = make_lone(0xDC00) + "B"
  assert_eq(@url.encode_uri_component_strict(lo_start), None)
  assert_eq(@url.encode_uri_component(lo_start), "%EF%BF%BDB")
  // Reversed surrogate pair (low then high)
  let rev = make_lone(0xDE00) + make_lone(0xD83D)
  assert_eq(@url.encode_uri_component_strict(rev), None)
  assert_eq(@url.encode_uri_component(rev), "%EF%BF%BD%EF%BF%BD")
  // High + High + Low: first high is lone (U+FFFD), second+third form valid pair
  let hhl = make_lone(0xD800) + make_lone(0xD83D) + make_lone(0xDE00)
  assert_eq(@url.encode_uri_component_strict(hhl), None)
  assert_eq(@url.encode_uri_component(hhl), "%EF%BF%BD%F0%9F%98%80")
}

///|
test "conformance: application/x-www-form-urlencoded space/+ roundtrip and lossy decode" {
  // WHATWG URLSearchParams / form-urlencoded set: * - . _ and alnum, space as +
  let form_keep = (b : Int) => (b >= 'a' && b <= 'z') ||
    (b >= 'A' && b <= 'Z') ||
    (b >= '0' && b <= '9') ||
    b == '*' ||
    b == '-' ||
    b == '.' ||
    b == '_'
  let encoded = @url.percent_encode("hello world+100%&a=b/中", form_keep, space_plus=true)
  assert_eq(encoded, "hello+world%2B100%25%26a%3Db%2F%E4%B8%AD")
  assert_eq(@url.percent_decode_lossy(encoded, plus_space=true), "hello world+100%&a=b/中")
  // Without plus_space, + stays literal +
  assert_eq(@url.percent_decode_lossy("a+b%20c", plus_space=false), "a+b c")
  // Invalid % sequences pass through verbatim in lossy mode
  assert_eq(@url.percent_decode_lossy("%E4%B8"), "\u{FFFD}")
  assert_eq(@url.percent_decode_lossy("foo%ZZbar%2"), "foo%ZZbar%2")
  assert_eq(@url.percent_decode_lossy("%C0%AF"), "\u{FFFD}\u{FFFD}")
}
