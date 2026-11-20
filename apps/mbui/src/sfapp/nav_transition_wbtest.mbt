// Narrow-shell layered navigation transitions, bottom-bar 1:1 swipe-back synchronization,
// and dual-ended root tab switching with steady decoupled top bar.

///|
fn nav_black_scrims(t : @ui.Tester) -> Array[Int64] {
  t
  .drawn_rects()
  .filter(fn(r) { r.2 >= 380.0 && r.3 >= 800.0 && (r.4 >> 8) == 0L && (r.4 & 0xFFL) > 0L })
  .map(fn(r) { r.4 & 0xFFL })
}

///|
fn nav_bar_glass_foot(t : @ui.Tester) -> Double? {
  // (the bar's capsule: as high as the bar's track, wider than the action's circle beside it)
  let gs = t.drawn_glass_corners().filter(fn(g) { (g.3 - bar_track).abs() < 1.0 && g.2 > 200.0 && g.2 < 360.0 })
  if gs.is_empty() {
    None
  } else {
    Some(gs.fold(init=0.0, fn(a, g) { dmax(a, g.1 + g.3) }))
  }
}

///|
test "narrow nav: Home -> Chat push has layered parallax & scrim, and swipe-back syncs bottom bar 1:1" {
  let t = tester("home")
  let bar_rest_foot = nav_bar_glass_foot(t).unwrap()
  let home_rest_x = t.rect_of("星火工作室").unwrap().0
  t.tap_text("夜里的构建又失败了")
  assert_eq(app.nav.depth(), 2)
  // Mid-push: Home moves by parallax (less than half of full width) and has a dark scrim
  t.run_for(@ui.move_ms(390.0) * 0.4)
  let home_mid_x = t.rect_of("星火工作室").unwrap().0
  let home_shift = home_rest_x - home_mid_x
  assert_true(home_shift > 5.0 && home_shift < 130.0, msg="home parallax shift=\{home_shift}")
  assert_true(!nav_black_scrims(t).is_empty(), msg="expected covered-page scrim on push")
  // Settle on Chat: bottom bar hidden
  t.run_for(@ui.move_most_ms)
  assert_true(bar.vis.at(t.time()).0 < 0.01)
  assert_true(nav_bar_glass_foot(t) is None, msg="bar should be hidden at rest on Chat")
  // Interactive predictive back gesture halfway: bottom bar rises smoothly in 1:1 sync with finger
  let g0 = t.time()
  t.back_raw(0, 0.0, g0)
  t.back_raw(1, 195.0, g0 + @ui.frame_period_default)
  t.frame_at(g0 + @ui.frame_period_default)
  assert_true(app.nav.in_gesture())
  let rp = app.nav.root_progress(fn() { t.time() })
  assert_true(rp > 0.35 && rp < 0.65, msg="root_progress halfway=\{rp}")
  guard nav_bar_glass_foot(t) is Some(swipe_foot) else { fail("bottom bar must appear during swipe-back") }
  // Halfway up: bar foot is below rest by ~(1 - rp) * bar_drop (so strictly between rest and rest + bar_drop)
  let drop_now = swipe_foot - bar_rest_foot
  assert_true(drop_now > 20.0 && drop_now < bar_drop - 20.0, msg="swipe bar drop=\{drop_now}")
  // Commit back gesture: smoothly finishes returning to Home & full bar visibility
  t.back_raw(2, 195.0, t.time() + 16.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(app.nav.depth(), 1)
  assert_true(bar.vis.at(t.time()).0 > 0.99)
  let final_foot = nav_bar_glass_foot(t).unwrap()
  assert_true((final_foot - bar_rest_foot).abs() < 1.0, msg="final_foot=\{final_foot} rest=\{bar_rest_foot}")
}

///|
test "narrow nav: Home -> NewChat rise applies full-bleed depth scrim and 1px top hairline without gap" {
  let t = tester("home")
  let (_, y) = bar_places_at()
  let rest_w = t.rect_of("整理发布清单").unwrap().2
  t.tap(bar_action_x, y)
  assert_true(app.nav.risen())
  t.run_for(@ui.move_ms(844.0) * 0.5)
  assert_true(!nav_black_scrims(t).is_empty(), msg="expected depth scrim during NewChat rise")
  assert_eq(t.rect_of("整理发布清单").unwrap().2, rest_w)
  let top_lines = t
    .drawn_rects()
    .filter(fn(r) { r.2 >= 380.0 && (r.3 - 1.0).abs() < 0.1 && (r.4 >> 8) == 0L && (r.4 & 0xFFL) > 0L })
  assert_true(!top_lines.is_empty(), msg="expected 1px top hairline on rising NewChat")
  t.run_for(@ui.move_most_ms)
  t.tap_text("取消")
  t.run_for(@ui.move_most_ms)
  assert_eq(app.nav.depth(), 1)
  assert_eq(nav_black_scrims(t), [])
}

///|
test "narrow nav: bottom-bar tab switches run dual-ended cross-transition while keeping settings gear stationary" {
  let t = tester("home")
  let gear_x0 = t.locate("icon:settings")[0].0
  let (xs, y) = bar_places_at()
  let home_serial = app.nav.top_stay().0
  // Switch 对话 -> 文件
  t.tap(xs[1], y)
  assert_true(app.nav.top() == Files)
  let files_serial = app.nav.top_stay().0
  let start = t.time()
  let tab_dur = @ui.NavTransition::layered().tab_ms
  // Verify zero words_over overlap across the entire spring handoff
  for i in 0..<=100 {
    let at = start + tab_dur * (i.to_double() / 100.0)
    let (_, a_out) = app.nav.tab_body_motion(home_serial, fn() { at }, slide=22.0)
    let (_, a_in) = app.nav.tab_body_motion(files_serial, fn() { at }, slide=22.0)
    assert_true(dmin(a_out, a_in) < 0.12, msg="overlap at i=\{i}: out=\{a_out} in=\{a_in}")
  }
  // At t=20ms: outgoing Home content is already crisply fading out (no sticky linger)
  t.frame_at(start + tab_dur * (20.0 / 260.0))
  let old_20 = t.words().filter(fn(w) { w.0 == "整理发布清单" && w.5 > 0.1 && w.5 < 0.85 })
  assert_true(!old_20.is_empty(), msg="old Home tab content should crisply fade out at 20ms")
  let mut max_gear_drift = 0.0
  for frac in [20.0 / 260.0, 55.0 / 260.0, 100.0 / 260.0, 160.0 / 260.0, 1.0] {
    t.frame_at(start + tab_dur * frac)
    let gears = t.locate("icon:settings")
    assert_true(!gears.is_empty(), msg="gear missing at frac=\{frac}")
    for g in gears {
      let drift = (g.0 - gear_x0).abs()
      if drift > max_gear_drift {
        max_gear_drift = drift
      }
    }
  }
  assert_true(max_gear_drift <= 0.5, msg="settings gear drifted by \{max_gear_drift}pt during tab switch")
  t.run_for(@ui.move_most_ms)
  // Switch 文件 -> 对话: verify incoming Home content is already visibly entering at t=55ms (no 92ms dead valley)
  t.tap(xs[0], y)
  assert_true(app.nav.top() == Home)
  let start2 = t.time()
  let mut saw_in_55 = false
  for frac in [20.0 / 260.0, 55.0 / 260.0, 130.0 / 260.0, 1.0] {
    t.frame_at(start2 + tab_dur * frac)
    if (frac - 55.0 / 260.0).abs() < 0.001 {
      let in_55 = t.words().filter(fn(w) { w.0 == "整理发布清单" && w.5 > 0.01 && w.5 < 1.0 })
      if !in_55.is_empty() {
        saw_in_55 = true
      }
    }
    for g in t.locate("icon:settings") {
      let drift = (g.0 - gear_x0).abs()
      assert_true(drift <= 0.5, msg="return switch gear drift=\{drift}pt at frac=\{frac}")
    }
  }
  assert_true(saw_in_55, msg="incoming Home tab content should already be visible and sliding in at 55ms")
  t.run_for(@ui.move_most_ms)
  to_bar_rest(t)
  t.assert_idle()
}
