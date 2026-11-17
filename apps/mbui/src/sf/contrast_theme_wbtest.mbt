// The theme as the system asking for more contrast has it (tokens.mbt contrasted): the quiet words half way to the
// words' own ink, the lines twice as seen, the rest as it is; asked not, the palette as it is.

///|
test "more contrast asked: quiet words half way to the words' ink, lines twice as seen, the accent and grounds as they are" {
  for dark in [false, true] {
    let base = theme_of(dark, false).p
    let more = theme_of(dark, true).p
    assert_eq(
      (
        more.muted == mix(base.text, 0.5, base.muted),
        more.subtle == mix(base.text, 0.5, base.subtle),
        more.line == twice_seen(base.line),
        more.line_strong == twice_seen(base.line_strong),
        more.accent == base.accent,
        more.bg == base.bg,
        more.text == base.text,
      ),
      (true, true, true, true, true, true, true),
    )
  }
}

///|
test "a colour twice as seen: its opacity doubled, opaque at most" {
  assert_eq((twice_seen(0x11223340L), twice_seen(0x112233A0L)), (0x11223380L, 0x112233FFL))
}
