// Scroll-to-collapse bottom bar tests (iOS 26 style): scrolling down collapses the left capsule into a 50x50 circular
// orb holding only the centered active tab icon while the middle gap passes touches through to the list; tapping the
// orb, scrolling up >= 24pt, returning near top (y <= 24pt), switching tabs, or opening the panel expands it again.

///|
let collapse_settle_ms : Double = @ui.move_most_ms * 2.0

///|
let collapse_sample_ms : Double = 1000.0 / 50.0

///|
fn bar_collapse_capsule_w(t : @ui.Tester) -> Double {
  t.drawn_glass().fold(init=0.0, fn(a, g) {
    if (g.0 - 22.0).abs() < 1.0 && (g.3 - bar_track).abs() < 1.0 {
      dmax(a, g.2)
    } else {
      a
    }
  })
}

///|
test "bar scroll-to-collapse: downward scroll collapses to 50pt orb with centered active icon, middle gap passes through, tapping orb expands" {
  new_run()
  let src = fixture("home-pins")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  let full_w = bar_capsule_w(390.0 - 44.0, 1.0)
  assert_false(bar.collapsed)
  assert_true((bar_collapse_capsule_w(t) - full_w).abs() < 0.5, msg="expanded w=\{bar_collapse_capsule_w(t)} expected=\{full_w}")

  // Small downward scroll (y <= 48pt) must NOT collapse
  let t0 = t.time()
  bar_scroll_note("ws1:chats", 0.0, 600.0, t0)
  bar_scroll_note("ws1:chats", 40.0, 600.0, t0 + 16.0)
  assert_false(bar.collapsed)

  // Scrolling further past y > 48pt with accumulated downward delta >= 36pt triggers collapse
  bar_scroll_note("ws1:chats", 96.0, 600.0, t0 + 32.0)
  assert_true(bar.collapsed)
  t.run_for(collapse_settle_ms)
  let orb_w = bar_collapse_capsule_w(t)
  assert_true((orb_w - bar_track).abs() < 0.5, msg="collapsed orb w=\{orb_w} expected=\{bar_track}")
  assert_eq(bar_merge_at(t.time()), 0.0)

  // Active tab ("chats") icon sits centered in the 56x56 orb (22 + 28 = 50pt in window),
  // while inactive tabs fade out to alpha 0.0
  let (ax, _, aw, _) = said_at(t, place_label("chats")).unwrap()
  let active_cx = ax + aw / 2.0
  assert_true((active_cx - (22.0 + bar_track / 2.0)).abs() < 1.0, msg="active_cx=\{active_cx}")
  let tree = @ui.view_tree().unwrap()
  let inactive_visible = tree.drawn().iter().any(fn(d) {
    d.words == place_label("files") && d.alpha > 0.01
  })
  assert_false(inactive_visible)

  // Middle empty gap (x = 180pt, y = 794pt) must NOT be intercepted by the bar's glass
  let bar_y = 844.0 - 22.0 - bar_track / 2.0
  let mid_hit = tree.target_at(180.0, bar_y)
  let orb_hit = tree.target_at(22.0 + bar_track / 2.0, bar_y)
  assert_true(mid_hit != orb_hit, msg="middle gap must pass through and not hit the collapsed bar")

  // Tapping the left 56x56 orb expands the bar without switching away from "chats"
  t.touch(0, 22.0 + bar_track / 2.0, bar_y)
  t.touch(2, 22.0 + bar_track / 2.0, bar_y)
  assert_false(bar.collapsed)
  t.run_for(collapse_settle_ms)
  assert_true((bar_collapse_capsule_w(t) - full_w).abs() < 0.5, msg="re-expanded w=\{bar_collapse_capsule_w(t)}")
  assert_eq(place_of(app.nav.top()), Some("chats"))
}

///|
test "bar scroll-to-collapse: upward scroll >= 24pt, top return <= 24pt, rubber-band ignore, and forced expand on tab/panel" {
  new_run()
  let src = fixture("home-pins")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  let t0 = t.time()

  // Rubber-band overscroll (y < 0 or y > most) is ignored
  bar_scroll_note("ws1:chats", 0.0, 500.0, t0)
  bar_scroll_note("ws1:chats", -30.0, 500.0, t0 + 10.0)
  bar_scroll_note("ws1:chats", 540.0, 500.0, t0 + 20.0)
  assert_false(bar.collapsed)

  // Collapse on downward scroll
  bar_scroll_note("ws1:chats", 120.0, 500.0, t0 + 30.0)
  assert_true(bar.collapsed)

  // Small upward scroll (< 24pt) stays collapsed
  bar_scroll_note("ws1:chats", 105.0, 500.0, t0 + 40.0)
  assert_true(bar.collapsed)

  // Additional upward scroll reaching >= 24pt total expands
  bar_scroll_note("ws1:chats", 90.0, 500.0, t0 + 50.0)
  assert_false(bar.collapsed)

  // Re-collapse, then jump near top (y <= 24pt) -> expands immediately
  bar_scroll_note("ws1:chats", 180.0, 500.0, t0 + 60.0)
  assert_true(bar.collapsed)
  bar_scroll_note("ws1:chats", 20.0, 500.0, t0 + 70.0)
  assert_false(bar.collapsed)

  // Re-collapse, then opening the panel forces expand
  bar_scroll_note("ws1:chats", 180.0, 500.0, t0 + 80.0)
  assert_true(bar.collapsed)
  bar.open_panel(true, at=t0 + 90.0)
  assert_false(bar.collapsed)
  assert_eq(bar.collapse_at(t0 + 150.0), 0.0)
}

///|
test "bar scroll-to-collapse: closed-form spring is FPS-invariant across 60/120/24/7 fps" {
  let samples : Array[(Double, Double)] = []
  for fps in [60.0, 120.0, 24.0, 7.0] {
    new_run()
    let src = fixture("home-pins")
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
    t.set_frame_period(1000.0 / fps)
    t.run_for(@ui.move_most_ms)
    let at = t.time()
    bar_set_collapsed(true, at)
    let mid_c = bar.collapse_at(at + 100.0)
    let end_c = bar.collapse_at(at + 450.0)
    assert_true(mid_c > 0.2 && mid_c < 0.99, msg="fps=\{fps} mid_c=\{mid_c}")
    assert_true((end_c - 1.0).abs() < 0.01, msg="fps=\{fps} end_c=\{end_c}")
    samples.push((mid_c, end_c))
  }
  let (ref_mid, ref_end) = samples[0]
  for s in samples {
    assert_true((s.0 - ref_mid).abs() < 1.0e-9, msg="mid mismatch: \{s.0} vs \{ref_mid}")
    assert_true((s.1 - ref_end).abs() < 1.0e-9, msg="end mismatch: \{s.1} vs \{ref_end}")
  }
}

///|
test "bar scroll-to-collapse: real touch drag on Home list triggers collapse and tapping left orb expands" {
  new_run()
  let src = fixture("home-pins")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=1)
  t.run_for(@ui.move_most_ms)
  assert_false(bar.collapsed)
  // Finger swipe up on the list (scrolls list downward > 48pt with >= 36pt delta)
  t.drag(195.0, 580.0, 195.0, 260.0, steps=12)
  t.run_for(collapse_settle_ms)
  assert_true(bar.collapsed, msg="expected bar to collapse after real downward scroll drag")
  let orb_w = bar_collapse_capsule_w(t)
  assert_true((orb_w - bar_track).abs() < 0.5, msg="collapsed orb w=\{orb_w}")
  // Tap the left 50x50 orb to expand
  let bar_y = 844.0 - 22.0 - bar_track / 2.0
  t.touch(0, 22.0 + bar_track / 2.0, bar_y)
  t.touch(2, 22.0 + bar_track / 2.0, bar_y)
  t.run_for(collapse_settle_ms)
  assert_false(bar.collapsed)
}

///|
fn assert_bar_icons_inside_capsule(t : @ui.Tester, phase : String) -> Unit raise {
  let cap = t.drawn_glass().iter().find_first(fn(g) {
    (g.0 - 22.0).abs() < 1.0 && (g.3 - bar_track).abs() < 1.0
  })
  assert_true(cap is Some(_), msg="\{phase}: missing bar capsule glass")
  let g = cap.unwrap()
  let (gx, gy, gw, gh) = (g.0, g.1, g.2, g.3)
  let act_left = 22.0 + (390.0 - 44.0) - act_size - 1.0
  // Check every visible drawn tab icon shape in the bar band (excluding the right `+` action disc)
  for s in t.drawn_shapes() {
    let alpha_byte = s.5 & 0xFFL
    let cy = s.1 + s.3 / 2.0
    if alpha_byte > 5L && cy >= gy - 1.0 && cy <= gy + gh + 1.0 && s.0 + s.2 < act_left {
      assert_true(
        s.0 >= gx - 0.5 && s.0 + s.2 <= gx + gw + 0.5,
        msg="\{phase}: icon shape [\{s.0}, \{s.0 + s.2}] overflows capsule [\{gx}, \{gx + gw}] (c=\{bar.collapse_at(t.time())})",
      )
    }
  }
  // Also check every visible tab's logical 28pt icon bounds from tree.drawn()
  let tree = @ui.view_tree().unwrap()
  for key in ["chats", "files", "stations", "remote"] {
    let lbl = place_label(key)
    for d in tree.drawn() {
      if d.words == lbl && d.alpha > 0.02 {
        let cx = d.x + d.w / 2.0
        let half_icon = 14.0
        assert_true(
          cx - half_icon >= gx && cx + half_icon <= gx + gw,
          msg="\{phase}: tab \{key} icon [\{cx - half_icon}, \{cx + half_icon}] overflows capsule [\{gx}, \{gx + gw}] (alpha=\{d.alpha}, c=\{bar.collapse_at(t.time())})",
        )
      }
    }
  }
}

///|
test "bar scroll-to-collapse: every visible tab icon stays strictly inside capsule glass on every frame during collapse and expand" {
  new_run()
  let src = fixture("home-pins")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  assert_bar_icons_inside_capsule(t, "rest-expanded")

  // Trigger collapse and sample every 20ms across 0..360ms
  bar_set_collapsed(true, t.time())
  for i in 0..<=18 {
    t.run_for(collapse_sample_ms)
    assert_bar_icons_inside_capsule(t, "collapse-\{i * 20}ms")
  }
  assert_true(bar.collapsed)

  // Tap left 50x50 orb to expand and sample every 20ms across 0..360ms
  let bar_y = 844.0 - 22.0 - bar_track / 2.0
  t.touch(0, 22.0 + bar_track / 2.0, bar_y)
  t.touch(2, 22.0 + bar_track / 2.0, bar_y)
  assert_false(bar.collapsed)
  for i in 0..<=18 {
    t.run_for(collapse_sample_ms)
    assert_bar_icons_inside_capsule(t, "expand-\{i * 20}ms")
  }
}
