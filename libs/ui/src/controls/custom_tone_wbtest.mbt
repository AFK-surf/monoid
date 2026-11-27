// A colour theme of one's own hue (tokens.mbt custom_tone): every hue stands as the five do.

///|
test "a theme of any hue: its ink reads on its page and on what is chosen, white on its accent, by day and by night" {
  for hue in 0..<360 {
    let a = custom_tone(hue)
    let day = a.light_grounds.unwrap()
    let night = a.dark_grounds.unwrap()
    let at = "hue \{hue}"
    assert_true(@ui.contrast_ratio(a.light_text, day.bg) >= 6.8, msg="\{at}: ink on the page")
    assert_true(@ui.contrast_ratio(a.light_text, day.selected) >= 5.4, msg="\{at}: ink on what is chosen")
    assert_true(@ui.contrast_ratio(0xFFFFFFFFL, a.light) >= 4.3, msg="\{at}: white on the accent")
    assert_true(@ui.contrast_ratio(a.dark_text, night.bg) >= 8.0, msg="\{at}: ink on the night's page")
    assert_true(@ui.contrast_ratio(a.dark_text, night.raised) >= 7.0, msg="\{at}: ink on what floats")
    assert_true(@ui.contrast_ratio(0xFFFFFFFFL, a.dark) >= 3.0, msg="\{at}: white on the night's accent")
    // the words' grey on its page as on the orange's
    assert_true(@ui.contrast_ratio(light_palette.muted, day.bg) >= 4.5, msg="\{at}: muted words")
    assert_true(@ui.contrast_ratio(dark_palette.muted, night.bg) >= 4.5, msg="\{at}: muted words by night")
  }
}

///|
test "a theme's key: one of the five, rainbow, custom:<0..359>, nothing else" {
  assert_true(tone_of("teal") is Some(_))
  assert_eq(tone_of("rainbow").map(fn(a) { a.key }), Some("rainbow"))
  assert_eq(tone_of("custom:0").map(fn(a) { a.key }), Some("custom:0"))
  assert_eq(tone_of("custom:359").map(fn(a) { a.key }), Some("custom:359"))
  for bad in ["custom:360", "custom:", "custom:-1", "custom:1a", "custom:0123", "indigo"] {
    assert_true(tone_of(bad) is None, msg=bad)
  }
}

///|
test "rainbow accent: deterministic seed mixing into 0..359 and reactive theme resolution" {
  let h0 = rainbow_hue_of_seed(1790000000000L)
  let h1 = rainbow_hue_of_seed(1790000000001L)
  assert_true(h0 >= 0 && h0 < 360)
  assert_true(h1 >= 0 && h1 < 360)
  assert_eq(rainbow_hue_of_seed(1790000000000L), h0)
  assert_true(h0 != h1)
  set_accent(rainbow_accent_key)
  set_rainbow_hue(h0)
  assert_eq(accent_key(), rainbow_accent_key)
  assert_eq(theme().p.accent, custom_tone(h0).light)
  assert_eq(palette_of(true).accent, custom_tone(h0).dark)
  set_rainbow_hue(h1)
  assert_eq(theme().p.accent, custom_tone(h1).light)
  assert_eq(palette_of(true).accent, custom_tone(h1).dark)
  set_accent("")
}

///|
test "the grounds untinted: in no hue whatever the theme, as light as the orange's, the accent as chosen" {
  let grounds = fn(p : Palette) { [p.bg, p.canvas, p.raised, p.sidebar, p.list, p.selected, p.paper, p.card, p.card2, p.chip] }
  let grey = fn(c : Int64) { ((c >> 24) & 0xFFL) == ((c >> 16) & 0xFFL) && ((c >> 16) & 0xFFL) == ((c >> 8) & 0xFFL) }
  set_ground_tint(false)
  assert_false(ground_tint())
  for dark in [false, true] {
    set_dark(Some(dark))
    set_accent("")
    let plain = grounds(theme().p)
    let own = grounds(if dark { dark_palette } else { light_palette })
    for i, c in plain {
      assert_true(grey(c), msg="\{dark} \{i}: a grey")
      // (as light as the orange's own: what is read on it reads as it did)
      let k = @ui.contrast_ratio(c, own[i])
      assert_true(k < 1.02, msg="\{dark} \{i}: \{k}")
    }
    assert_true(grey(ui_theme().faint), msg="\{dark}: faint")
    assert_eq(theme().p.accent, if dark { accents[0].dark } else { accents[0].light })
    for key in ["blue", "pink", "custom:140", "rainbow"] {
      set_accent(key)
      let a = tone_of(key).unwrap()
      assert_eq(grounds(theme().p), plain, msg=key)
      assert_eq(grounds(palette_of(dark)), plain, msg=key)
      assert_true(grey(ui_theme().faint), msg=key)
      assert_eq(theme().p.accent, if dark { a.dark } else { a.light }, msg=key)
      assert_eq(theme().p.accent_text, if dark { a.dark_text } else { a.light_text }, msg=key)
    }
  }
  // by day what is on the page is white, the page a light grey under it
  set_dark(Some(false))
  assert_eq(theme().p.canvas, 0xFFFFFFFFL)
  assert_eq(theme().p.card, 0xFFFFFFFFL)
  // tinted again: the theme's own grounds
  set_ground_tint(true)
  set_accent("blue")
  assert_eq(theme().p.bg, accents[1].light_grounds.unwrap().bg)
  set_accent("")
  set_dark(None)
}
