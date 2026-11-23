// White-box tests for Stage 1 S1-3A optical & interaction alignment in `ui/glass`:
// 1. `liquid_segmented_node(glass_track=true)`:
//    - Clear refraction lens is mounted AFTER the label row (Z-order above text glyphs).
//    - Resting selected pill uses iOS 26 lifted fill (Light 0xFFFFFFFF, Dark 0x5A5A60FF) + outer shadow (2, 1, 0x0000001F).
//    - Held lens scales to 1.15x (`ctrl_seg_held_scale == 1.15`) with zero relayout (`laid == 0`).
// 2. `liquid_slider_node`:
//    - Track & active fill elastically thicken from 6pt at rest to 10pt while held/dragged in paint layer (`laid == 0`),
//      centered vertically and returning to 6pt on release.

///|
/// Declared hold and drag durations for liquid control white-box assertions (past press spring peak).
let glass_ctrl_hold_ms : Double = 300.0

///|
let glass_ctrl_drag_ms : Double = 250.0

///|
test "liquid_segmented_node(glass_track=true): lens Z-order above text, lifted idle pill, 1.15x scale, laid == 0" {
  for dark in [false, true] {
    let seg_idx = @signals.signal(0)
    let t = glass_case(dark, false, fn(page) {
      liquid_segmented_node(
        page,
        fn() { ["Day", "Week", "Month"] },
        fn() { seg_idx.get() },
        fn(i) { seg_idx.set(i) },
        width=360.0,
        height=44.0,
        glass_track=true,
      )
      |> ignore
    })
    t.run_for(glass_springs_out)
    // 1. Resting state: 1 liquid glass instance (track only), bright lifted idle pill with exact fill color.
    let expected_idle = if dark { 0x5A5A60FFL } else { 0xFFFFFFFFL }
    let idle_pills = t.drawn_rects().filter(fn(r) { r.4 == expected_idle && r.2 > 80.0 && r.3 > 30.0 })
    assert_eq(idle_pills.length(), 1, msg="dark=\{dark}: rest must draw 1 lifted idle pill with expected color")
    assert_eq(t.drawn_glass().length(), 1, msg="dark=\{dark}: rest must draw only the track glass (0 hidden lens)")
    assert_eq(t.audit(), [], msg="dark=\{dark}: rest audit must be empty")

    // 2. Press and drag to "Week" -> lens must be mounted AFTER text glyphs (Z-order above labels) and scaled ~1.15x.
    let r0 = t.get(Tab, label="Day").rect
    let r1 = t.get(Tab, label="Week").rect
    let cy = r0.1 + r0.3 / 2.0
    t.press_at(r0.0 + r0.2 / 2.0, cy)
    t.run_for(glass_ctrl_hold_ms)
    t.tree_frames_from_now()
    t.move_to(r1.0 + r1.2 / 2.0, cy)
    t.run_for(glass_ctrl_drag_ms)
    for f in t.tree_frames() {
      assert_eq(f.laid, 0, msg="dark=\{dark}: dragging liquid_segmented_node must not relayout: \{Repr(f)}")
    }
    let insts = t.drawn_instances()
    let mut last_glyph_idx = -1
    let mut lens_idx = -1
    let mut lens_h = 0.0
    for idx, inst in insts {
      // kind == 1 is text glyph; kind == 6 with blur == 0.0 (slot 14) is clear refraction lens.
      if inst[5] == 1.0 {
        last_glyph_idx = idx
      } else if inst[5] == 6.0 && inst[14] == 0.0 {
        lens_idx = idx
        lens_h = inst[3]
      }
    }
    assert_true(last_glyph_idx >= 0, msg="dark=\{dark}: must draw label glyphs")
    assert_true(lens_idx > last_glyph_idx, msg="dark=\{dark}: clear lens (idx=\{lens_idx}) must draw AFTER text glyphs (last=\{last_glyph_idx})")
    let inner_h = 44.0 - 2.0 * ctrl_seg_pad
    assert_true(
      lens_h >= inner_h * 1.12 && lens_h <= inner_h * 1.25,
      msg="dark=\{dark}: held lens height \{lens_h} must reflect 1.15x lift over inner_h=\{inner_h}",
    )
    assert_eq(t.audit(), [], msg="dark=\{dark}: held audit must be empty")

    // 3. Release and settle back to rest -> 1 glass (track only), selection switched to 1 ("Week").
    t.release(r1.0 + r1.2 / 2.0, cy)
    t.run_for(glass_springs_out)
    assert_eq(seg_idx.untracked(), 1, msg="dark=\{dark}: release on Week must select index 1")
    assert_eq(t.drawn_glass().length(), 1, msg="dark=\{dark}: settled must return to track glass only")
    assert_eq(t.audit(), [], msg="dark=\{dark}: settled audit must be empty")
  }
  set_dark(None)
}

///|
test "liquid_slider_node: elastic track thickening 6pt -> 10pt while held/dragged with laid == 0" {
  let slider_val = @signals.signal(40.0)
  let t = glass_case(false, false, fn(page) {
    page.box(fn(s) {
      s.width(Is(Some(320.0))) |> ignore
      liquid_slider_node(s, fn() { slider_val.get() }, fn(v) { slider_val.set(v) }, fn() { "Brightness" }) |> ignore
    })
    |> ignore
  })
  t.run_for(glass_springs_out)
  let track_col = colors().track
  let accent_col = colors().accent
  let track_rect = fn() raise {
    let rs = t.drawn_rects().filter(fn(r) { r.4 == track_col && r.2 > 200.0 })
    assert_eq(rs.length(), 1, msg="expected 1 slider background track rect")
    rs[0]
  }
  let fill_rect = fn() raise {
    let rs = t.drawn_rects().filter(fn(r) { r.4 == accent_col && r.2 > 20.0 })
    assert_eq(rs.length(), 1, msg="expected 1 slider active fill rect")
    rs[0]
  }
  // 1. At rest: track and fill are 6.0pt high.
  let rest_tr = track_rect()
  let rest_fl = fill_rect()
  assert_true((rest_tr.3 - 6.0).abs() < 0.05, msg="rest track height must be 6pt, got \{rest_tr.3}")
  assert_true((rest_fl.3 - 6.0).abs() < 0.05, msg="rest fill height must be 6pt, got \{rest_fl.3}")
  let rest_cy = rest_tr.1 + rest_tr.3 / 2.0

  // 2. Press and drag: track and fill thicken smoothly to ~10.0pt centered at rest_cy, with laid == 0.
  let sl_rect = t.get(Slider, label="Brightness").rect
  let y = sl_rect.1 + sl_rect.3 / 2.0
  let x0 = sl_rect.0 + sl_rect.2 * 0.4
  let x1 = sl_rect.0 + sl_rect.2 * 0.7
  t.press_at(x0, y)
  t.run_for(glass_ctrl_hold_ms)
  t.tree_frames_from_now()
  t.move_to(x1, y)
  t.run_for(glass_ctrl_drag_ms)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="liquid_slider_node drag must not trigger relayout: \{Repr(f)}")
  }
  let held_tr = track_rect()
  let held_fl = fill_rect()
  assert_true(held_tr.3 >= 9.5 && held_tr.3 <= 10.5, msg="held track height must thicken to ~10pt, got \{held_tr.3}")
  assert_true(held_fl.3 >= 9.5 && held_fl.3 <= 10.5, msg="held fill height must thicken to ~10pt, got \{held_fl.3}")
  let held_cy = held_tr.1 + held_tr.3 / 2.0
  assert_true((held_cy - rest_cy).abs() < 0.1, msg="thickened track must stay vertically centered (\{held_cy} vs \{rest_cy})")

  // 3. Release and settle: track and fill return to 6.0pt.
  t.release(x1, y)
  t.run_for(glass_springs_out)
  let done_tr = track_rect()
  let done_fl = fill_rect()
  assert_true((done_tr.3 - 6.0).abs() < 0.05, msg="settled track height must return to 6pt, got \{done_tr.3}")
  assert_true((done_fl.3 - 6.0).abs() < 0.05, msg="settled fill height must return to 6pt, got \{done_fl.3}")
  set_dark(None)
}
