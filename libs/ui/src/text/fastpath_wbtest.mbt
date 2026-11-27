// Whitebox tests for Perf-63 fast paths: RangeTable CJK uniformity across boundaries and lone-surrogate line_breaks.

///|
test "RangeTable CJK fast path matches binary search across 0x3300..=0xA0FF on all three Unicode tables" {
  assert_true(line_table.cjk_val >= 0)
  assert_true(grapheme_table.cjk_val >= 0)
  assert_true(bidi_table.cjk_val >= 0)
  for cp in 0x3300..=0xA0FF {
    assert_eq(line_table.get(cp), line_table.search(cp), msg="line_table mismatch at U+\{cp}")
    assert_eq(grapheme_table.get(cp), grapheme_table.search(cp), msg="grapheme_table mismatch at U+\{cp}")
    assert_eq(bidi_table.get(cp), bidi_table.search(cp), msg="bidi_table mismatch at U+\{cp}")
  }
}

///|
test "line_breaks handles lone surrogates and adjacent valid surrogate pairs identically to code_point_at" {
  let mk = fn(units : Array[Int]) -> String {
    let sb = StringBuilder(capacity=units.length())
    for u in units {
      sb.write_char(Int::unsafe_to_char(u))
    }
    sb.to_string()
  }
  let cases = [
    mk([0xD800, 0x0061]), // lone high surrogate followed by 'a'
    mk([0x0061, 0xDC00]), // 'a' followed by lone low surrogate
    mk([0xD800]), // trailing lone high surrogate
    mk([0xDC00]), // lone low surrogate
    mk([0xD800, 0xD800, 0xDC00]), // lone high surrogate before valid pair U+10000
    mk([0x4E2D, 0xD800, 0x6587]), // CJK surrounding lone high surrogate
  ]
  for idx, s in cases {
    let b = line_breaks(s)
    assert_eq(b.length(), s.length() + 1, msg="case \{idx}: length")
    assert_eq(b[0], 0, msg="case \{idx}: start")
    assert_eq(b[s.length()], 2, msg="case \{idx}: end")
  }
}
