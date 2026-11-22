///|
/// What node's toLowerCase gives (the final sigma, U+0130, title case, beyond the BMP, Kelvin's sign).
test "lowered as JavaScript lowers" {
  let cases = [
    ("ΑΣ", "ας"),
    ("ΑΣ.", "ας."),
    ("Σ", "σ"),
    ("ΑΣΑ", "ασα"),
    ("A.Σ", "a.ς"),
    ("İstanbul", "i̇stanbul"),
    ("ẞ", "ß"),
    ("ǅ", "ǆ"),
    ("ΌΣΟΣ ΣΟΦΌΣ", "όσος σοφός"),
    ("Ⅻ", "ⅻ"),
    ("𐐀𐐁", "𐐨𐐩"),
    ("Kelvin\u{212a}", "kelvink"),
    ("ΑΣ\u{301}", "ας\u{301}"),
    ("Hello World", "hello world"),
    ("ÀÉÎ", "àéî"),
    ("ΑΣ 1", "ας 1"),
  ]
  for c in cases {
    assert_eq(@jscase.lower(c.0), c.1)
  }
}

///|
/// What node's `s.split(/[^\p{L}\p{N}]+/u).includes(w)` says (a letter or a number of any script joins a word; a mark,
/// a lone surrogate, punctuation and `_` part words).
test "words as a regular expression's letters and numbers split them" {
  let cases = [
    ("api error: 401 invalid", "401", true),
    ("api error:401", "401", true),
    ("x4010", "401", false),
    ("4401", "401", false),
    ("状态401", "401", false),
    ("状态 401", "401", true),
    ("a_401", "401", true),
    ("é401", "401", false),
    ("401\u{301}", "401", true),
    ("𐐨401", "401", false),
    ("٤401", "401", false),
    ("401", "401", true),
    ("", "401", false),
  ]
  for c in cases {
    assert_eq(@jscase.has_word(c.0, c.1), c.2, msg="\{c.0}")
  }
}

///|
test "trim_start and trim_end for JS space vs Unicode White_Space" {
  // U+FEFF is JS \s but not Unicode White_Space; U+0085 is Unicode White_Space but not JS \s
  assert_eq(@jscase.trim_start(" \t\u{feff}abc \n"), "abc \n")
  assert_eq(@jscase.trim_end(" \t\u{feff}abc \n\u{3000}"), " \t\u{feff}abc")
  assert_eq(@jscase.trim_start("\u{0085}abc"), "\u{0085}abc")
  assert_eq(@jscase.trim_start_white("\u{0085} abc "), "abc ")
  assert_eq(@jscase.trim_end_white(" abc\u{0085}\n"), " abc")
  assert_eq(@jscase.trim_start_white("\u{feff}abc"), "\u{feff}abc")
  assert_eq(@jscase.trim_end_white("abc\u{feff}"), "abc\u{feff}")
  assert_eq(@jscase.trim_start("   "), "")
  assert_eq(@jscase.trim_end("   "), "")
}
