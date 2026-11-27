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
  let cases : Array[(Array[Int], Array[Int])] = [
    ([0xD800, 0x0061], [0, 0, 2]), // lone high surrogate (SG->AL) + 'a' (AL): LB28 no break
    ([0x0061, 0xDC00], [0, 0, 2]), // 'a' (AL) + lone low surrogate (SG->AL): LB28 no break
    ([0xD800], [0, 2]), // trailing lone high surrogate
    ([0xDC00], [0, 2]), // lone low surrogate
    ([0xD800, 0xD800, 0xDC00], [0, 0, 0, 2]), // lone high surrogate + valid U+10000 (AL)
    ([0x4E2D, 0xD800, 0x6587], [0, 1, 1, 2]), // '中' (ID) ÷ lone 0xD800 (AL) ÷ '文' (ID)
  ]
  for idx, pair in cases {
    let s = mk(pair.0)
    let want = pair.1
    let b = line_breaks(s)
    assert_eq(b.length(), want.length(), msg="case \{idx}: length")
    for i in 0..<want.length() {
      assert_eq(b[i], want[i], msg="case \{idx} pos \{i}")
    }
  }
}
