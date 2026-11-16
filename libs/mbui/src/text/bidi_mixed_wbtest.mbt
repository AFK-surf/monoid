// bidi_mixed: a text's levels worked out only where a character in it may make some of it read right to left
// (may_be_bidi), the same as Bidi::new's wherever they are.

///|
test "may_be_bidi is over every BMP character whose class makes levels worth working out, and every surrogate" {
  let missed = []
  for cp in 0..<0x10000 {
    if cp >= 0xD800 && cp <= 0xDFFF {
      if !may_be_bidi(cp) {
        missed.push(cp)
      }
    } else if complex_class(bidi_class(cp)) && !may_be_bidi(cp) {
      missed.push(cp)
    }
  }
  assert_eq(missed, [])
}

///|
test "bidi_mixed of each character alone, BMP and past it, is what Bidi::new says" {
  let differ = []
  for cp in 0..=0x10FFFF {
    if cp >= 0xD800 && cp <= 0xDFFF {
      continue
    }
    let s = Int::unsafe_to_char(cp).to_string()
    let fast = bidi_mixed(s)
    let whole = Bidi::new(s)
    let same = match fast {
      Some(b) => whole.mixed && b.levels == whole.levels && b.classes == whole.classes && b.para == whole.para
      None => !whole.mixed
    }
    if !same {
      differ.push(cp)
    }
  }
  assert_eq(differ, [])
}

///|
test "bidi_mixed: words left to right (Chinese, English, numbers, brackets) are None; right to left, Bidi::new's" {
  let ltr = [
    "", "plain ASCII words (and brackets) [1, 2] {3}", "中文和 English 混排，含数字 123 与括号（全角）和 (半角)。",
    "日本語のテキスト、한국어 텍스트", "Ελληνικά и кириллица — ‘quotes’ “dumb” • 😀 emoji 👍🏽",
  ]
  let rtl = [
    "שלום עולם", "hello שלום (world) 123", "مرحبا بالعالم ١٢٣", "a \u{202E}reversed\u{202C} b", "x \u{2067}iso\u{2069} y",
    "中文 \u{200F} mark", "\u{202A}left embed\u{202C} only", "数字 ٣ 中", "𐤀𐤁 Phoenician",
  ]
  for s in ltr {
    assert_true(bidi_mixed(s) is None)
    assert_true(!Bidi::new(s).mixed)
  }
  for s in rtl {
    let whole = Bidi::new(s)
    match bidi_mixed(s) {
      Some(b) => {
        assert_true(whole.mixed)
        assert_eq(b.levels, whole.levels)
        assert_eq(b.classes, whole.classes)
        assert_eq(b.para, whole.para)
      }
      None => assert_true(!whole.mixed)
    }
  }
}
