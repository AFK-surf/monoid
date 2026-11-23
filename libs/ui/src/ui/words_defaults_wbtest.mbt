// Default theme foreground ink (ink_theme) and single-line optical vertical centering (View::words_optical).

///|
fn glyph_colors_and_ys(c : Ctx) -> Array[(Int64, Double)] {
  let out : Array[(Int64, Double)] = []
  for k in 0..<c.ninst {
    let b = k * inst_size
    if c.inst[b + 5] == 1.0 {
      let r = (c.inst[b + 8] * 255.0).round().to_int64()
      let gr = (c.inst[b + 9] * 255.0).round().to_int64()
      let bl = (c.inst[b + 10] * 255.0).round().to_int64()
      let a = (c.inst[b + 11] * 255.0).round().to_int64()
      out.push(((r << 24) | (gr << 16) | (bl << 8) | a, c.inst[b + 1]))
    }
  }
  out
}

///|
test "View::words default ink follows tree_theme().fg across light/dark switches while explicit ink stays fixed" {
  let dark = @signals.signal(false, same=fn(a, b) { a == b })
  let t = Tester::tree(
    fn(root) {
      root.box(fn(b) {
        b.words(Is("Hi")) |> ignore
      })
      |> ignore
      root.box(fn(b) {
        b.words(Is("Red"), ink=0xFF0000FFL) |> ignore
      })
      |> ignore
    },
    w=300.0,
    h=120.0,
    theme=fn() { if dark.get() { Theme::dark() } else { Theme::light() } },
  )
  t.draw()
  let light_fg = Theme::light().fg
  let dark_fg = Theme::dark().fg
  assert_not_eq(light_fg, dark_fg, msg="light and dark themes have distinct fg")
  let before = glyph_colors_and_ys(g())
  assert_true(before.length() >= 5, msg="expected glyphs for Hi and Red")
  assert_true(before.iter().any(fn(p) { p.0 == light_fg }), msg="default words draw in light fg")
  assert_true(before.iter().any(fn(p) { p.0 == 0xFF0000FFL }), msg="explicit ink draws in red")
  let laid_before = view_app.val.unwrap().work().laid
  dark.set(true)
  t.frames_owed()
  let after = glyph_colors_and_ys(g())
  assert_eq(view_app.val.unwrap().work().laid, laid_before, msg="theme fg switch is paint-only (no layout)")
  assert_true(after.iter().any(fn(p) { p.0 == dark_fg }), msg="default words automatically repaint in dark fg")
  assert_false(after.iter().any(fn(p) { p.0 == light_fg }), msg="no stale light fg glyphs remain")
  assert_true(after.iter().any(fn(p) { p.0 == 0xFF0000FFL }), msg="explicit red ink unchanged after theme switch")
}

///|
test "View::words_runs default ink follows tree_theme().fg across light/dark switches while explicit ink stays fixed" {
  let dark = @signals.signal(false, same=fn(a, b) { a == b })
  let t = Tester::tree(
    fn(root) {
      root.box(fn(b) {
        b.words_runs(Is([@view.words_run("Runs")])) |> ignore
      })
      |> ignore
      root.box(fn(b) {
        b.words_runs(Is([@view.words_run("Green")]), ink=0x00FF00FFL) |> ignore
      })
      |> ignore
    },
    w=300.0,
    h=120.0,
    theme=fn() { if dark.get() { Theme::dark() } else { Theme::light() } },
  )
  t.draw()
  let light_fg = Theme::light().fg
  let dark_fg = Theme::dark().fg
  let before = glyph_colors_and_ys(g())
  assert_true(before.iter().any(fn(p) { p.0 == light_fg }), msg="default words_runs draw in light fg")
  assert_true(before.iter().any(fn(p) { p.0 == 0x00FF00FFL }), msg="explicit words_runs ink draws in green")
  dark.set(true)
  t.frames_owed()
  let after = glyph_colors_and_ys(g())
  assert_true(after.iter().any(fn(p) { p.0 == dark_fg }), msg="default words_runs repaint in dark fg")
  assert_false(after.iter().any(fn(p) { p.0 == light_fg }), msg="no stale light fg glyphs remain in words_runs")
  assert_true(after.iter().any(fn(p) { p.0 == 0x00FF00FFL }), msg="explicit green ink unchanged")
}

///|
test "optical_shift_y: Latin cap-height shift, CJK near-zero balance, scaling by size, and clamp bounds" {
  // Typical font metrics: size=15, ascent=14.6 (line_h=20, baseline at 14.6) -> Latin cap center = 14.6 - 5.3625 = 9.2375
  // When ascent is higher in the box (e.g. tight ascender/smaller descent: ascent=16.0, line_h=20.0):
  // Latin ink_mid = 16.0 - 0.715*15*0.5 = 10.6375 -> dy = 10.0 - 10.6375 = -0.6375 (shifts up into optical center)
  let dy_latin_15 = optical_shift_y("Save", 15.0, 16.0, 20.0)
  assert_true(dy_latin_15 < -0.5 && dy_latin_15 > -1.0, msg="15pt Latin dy=\{dy_latin_15} expected in (-1.0, -0.5)")
  // Scales proportionally with font size
  let dy_latin_30 = optical_shift_y("Save", 30.0, 32.0, 40.0)
  assert_true((dy_latin_30 - 2.0 * dy_latin_15).abs() < 1.0e-9, msg="scales linearly with size")
  // CJK ink_mid = ascent - 0.38*size = 15.7 - 5.7 = 10.0 for ascent=15.7, line_h=20.0 -> dy = 0.0
  let dy_cjk = optical_shift_y("保存", 15.0, 15.7, 20.0)
  assert_true(dy_cjk.abs() < 1.0e-9, msg="CJK dy=\{dy_cjk} expected ~0")
  // Same metrics (ascent=16.0, line_h=20.0): CJK shift is smaller in magnitude than Latin shift
  let dy_cjk_same = optical_shift_y("保存", 15.0, 16.0, 20.0)
  assert_true(dy_cjk_same.abs() < dy_latin_15.abs(), msg="CJK shift \{dy_cjk_same} smaller than Latin \{dy_latin_15}")
  // Clamping at [-0.18 * size, 0.18 * size]
  let clamp_hi = optical_shift_y("Hi", 20.0, 2.0, 40.0)
  assert_true((clamp_hi - 0.18 * 20.0).abs() < 1.0e-9, msg="clamped high to +0.18*size")
  let clamp_lo = optical_shift_y("Hi", 20.0, 38.0, 40.0)
  assert_true((clamp_lo + 0.18 * 20.0).abs() < 1.0e-9, msg="clamped low to -0.18*size")
  // Degenerate zero size/line_h
  assert_eq(optical_shift_y("Hi", 0.0, 10.0, 20.0), 0.0)
  assert_eq(optical_shift_y("Hi", 15.0, 10.0, 0.0), 0.0)
}

///|
test "View::words_optical shifts single-line glyph y by optical_shift_y, leaves false bit-identical, and dynamic By triggers Paint only" {
  let one_line : @view.WordsLook = { ..@view.words_plain, size: 15.0, line: 20.0, wrap: false }
  let opt = @signals.signal(false, same=fn(a, b) { a == b })
  let t = Tester::tree(
    fn(root) {
      root.box(fn(b) {
        b.words(Is("Button"), look=one_line) |> ignore
      })
      |> ignore
      root.box(fn(b) {
        b.words(Is("Button"), look=one_line).words_optical(By(fn() { opt.get() })) |> ignore
      })
      |> ignore
      root.box(fn(b) {
        b.words_runs(Is([@view.words_run("Runs")]), look=one_line).words_optical(By(fn() { opt.get() })) |> ignore
      })
      |> ignore
    },
    w=300.0,
    h=120.0,
  )
  t.draw()
  let off_ys = glyph_colors_and_ys(g()).map(fn(p) { p.1 })
  // Node 0 ("Button", default) and Node 1 ("Button", words_optical=false) have identical glyph offsets within their 20pt rows
  assert_eq(off_ys.length(), 16, msg="6 + 6 + 4 glyphs")
  for i in 0..<6 {
    assert_eq(off_ys[i + 6] - off_ys[i], 20.0, msg="words_optical(false) bit-identical to default at glyph \{i}")
  }
  let tl = layout_words("Button", 15.0, 400, 1.0e9, false, balance=false, line=20.0, style=view_words_style(), spacing=0.0, max_lines=0)
  let expected_dy = optical_shift_y("Button", 15.0, tl.ascent, tl.line_h)
  assert_true(expected_dy.abs() > 0.05, msg="non-trivial optical shift \{expected_dy} for single-line Latin")
  let laid_before = view_app.val.unwrap().work().laid
  let inst_before = view_app.val.unwrap().work().instances
  opt.set(true)
  t.frames_owed()
  assert_eq(view_app.val.unwrap().work().laid, laid_before, msg="words_optical By toggle triggers Paint only, no Layout")
  assert_true(view_app.val.unwrap().work().instances > inst_before, msg="words_optical By toggle repaints")
  let on_ys = glyph_colors_and_ys(g()).map(fn(p) { p.1 })
  // Node 0 unchanged; Node 1 and Node 2 shifted by expected_dy (glyph y is snapped to host pixels in view_blit)
  for i in 0..<6 {
    assert_eq(on_ys[i], off_ys[i], msg="control node unchanged")
    let delta = on_ys[i + 6] - off_ys[i + 6]
    assert_true((delta - expected_dy).abs() <= 0.5 + 1.0e-6 && delta * expected_dy > 0.0, msg="words glyph \{i} delta=\{delta} vs expected_dy=\{expected_dy}")
  }
  for i in 12..<16 {
    let delta = on_ys[i] - off_ys[i]
    assert_true((delta - expected_dy).abs() <= 0.5 + 1.0e-6 && delta * expected_dy > 0.0, msg="words_runs glyph \{i} delta=\{delta} vs expected_dy=\{expected_dy}")
  }
}
