// Upstream WPT / ECMA-262 percent-encoding corpus tests for libs/base/src/url.

///|
test "upstream WPT/ECMA-262: percent-encoding full ASCII table and UTF-8 sequences" {
  // Verify every ASCII byte 0x00..0x7F matches ECMA-262 encodeURIComponent & encodeURI sets
  let comp_keep = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
  let uri_extra = ";,/?:@&=+$#"
  for i in 0..<128 {
    let ch = i.unsafe_to_char().to_string()
    let got_comp = @url.encode_uri_component(ch)
    if comp_keep.contains(ch) {
      assert_eq(got_comp, ch)
    } else {
      assert_true(got_comp.has_prefix("%") && got_comp.length() == 3)
      assert_eq(@url.decode_uri_component(got_comp), Some(ch))
    }
    let got_uri = @url.encode_uri(ch)
    if comp_keep.contains(ch) || uri_extra.contains(ch) {
      assert_eq(got_uri, ch)
    } else {
      assert_true(got_uri.has_prefix("%") && got_uri.length() == 3)
    }
  }
  // WPT-style query & form-urlencoded vectors with multibyte UTF-8 and invalid percent escapes
  assert_eq(@url.percent_decode_lossy("a+b%20c%2B%25%26", plus_space=true), "a b c+%&")
  assert_eq(@url.percent_decode_lossy("%E2%9C%93%F0%9F%9A%80", plus_space=false), "✓🚀")
  assert_eq(@url.percent_decode_lossy("%80%FF%C0%80", plus_space=false), "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}")
}
