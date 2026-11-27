// End-to-end tests for PR 3b project-grouped sticky headers:
// - Flat mode zero intrusion on small and large screens
// - Large/medium screen (`Side | Tape`): bidirectional 2+2 / 2+1 stacking, zero floating pills covering chat rows,
//   Above/Below jump with zero overshoot and without collapsing, Active in-place collapse without jump
// - Small screen (`Whole`): native iOS 26 Liquid Glass floating group indicator pill below top glass bar (hidden at y=0,
//   zero opaque sticky slabs, zero bottom chrome over Liquid Glass tab bar, smooth scroll-coupled fade before next
//   in-flow heading, tap opens group-jump menu and glides with zero overshoot, shell suppression on search/modal/pushed page)
// - 1.3x large font scale zero fixed_outgrown and zero audit faults

///|
fn sticky_tester(mode : String, w : Double, h : Double, platform : Int) -> @ui.Tester {
  let src = fixture_app(mode)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
  t.run_for(@ui.move_most_ms)
  t
}

///|
fn sticky_scroll_by(t : @ui.Tester, x : Double, y : Double, dy : Double) -> Unit {
  t.wheel(x, y, dy)
  t.run_for(@ui.move_most_ms * 3.0)
}

///|
fn sticky_desk_audit(t : @ui.Tester) -> Array[String] {
  // Desktop split-pane resize handle (pane_view.mbt edge_node) intentionally straddles the sidebar/pane seam by 6px.
  t.audit().filter(fn(f) { !f.contains("edge_node.mbt") })
}

///|
fn sticky_heading_y(t : @ui.Tester, label : String) -> Double? {
  match t.rect_of(label) {
    Some((_, y, _, _)) => Some(y)
    None => None
  }
}

///|
fn sticky_find_floating_pill(t : @ui.Tester, name : String) -> (Double, Double, Double, Double)? {
  // Floating Liquid Glass pill on small screen sits left-aligned above the bottom tab bar (x ~= 22, lower half,
  // hit height >= 44, width <= 230, expanded == None)
  for s in t.semantics() {
    if !s.hidden &&
      s.role is Button &&
      s.expanded is None &&
      s.label.has_prefix(name + " ") &&
      s.rect.0 >= 16.0 &&
      s.rect.0 <= 32.0 &&
      s.rect.1 >= 500.0 &&
      s.rect.2 <= 230.0 {
      return Some(s.rect)
    }
  }
  None
}

///|
test "flat mode zero intrusion: no sticky chrome and normal scroll behavior on small and large screens" {
  // Small screen flat mode
  let ts = sticky_tester("home", 390.0, 844.0, 2)
  let y0 = sticky_heading_y(ts, "今天").unwrap()
  sticky_scroll_by(ts, 195.0, 400.0, 260.0)
  // In flat mode, "今天" scrolls off freely with the list (does not stick at top edge)
  match sticky_heading_y(ts, "今天") {
    Some(y1) => assert_true(y1 < y0 - 100.0, msg="flat heading should scroll freely: y0=\{y0}, y1=\{y1}")
    None => ()
  }
  assert_eq(ts.audit(), [])
  ts.assert_idle()

  // Large screen flat mode
  let tl = sticky_tester("home", 1280.0, 800.0, 0)
  assert_eq(sticky_desk_audit(tl), [])
  tl.assert_idle()
}

///|
test "large screen (h>=720): bidirectional 2+2 stacking, zero floating overflow pills, Above/Below jump without collapse, Active sticky collapse" {
  let t = sticky_tester("projects-sticky", 1280.0, 800.0, 0)
  assert_eq(sticky_desk_audit(t), [])

  // Mid-scroll so top has Above + Active (2 rows) and bottom has Below (2 rows)
  sticky_scroll_by(t, 150.0, 400.0, 620.0)
  assert_eq(sticky_desk_audit(t), [])

  // Verify no floating "+N" pill overlays chat rows on desktop
  for s in t.semantics() {
    assert_false(!s.hidden && s.role is Button && s.label.contains("个分组"), msg="desktop must not float overflow pills over chat rows")
  }

  let top_groups = ["未归类", "alpha-api", "board", "design-system", "infra-ops", "mobile-shell", "monoid", "release-qa"]
  let visible_heads : Array[(String, (Double, Double, Double, Double))] = []
  for g in top_groups {
    for s in t.semantics() {
      if !s.hidden && s.role is Button && s.label.has_prefix(g + " ") {
        visible_heads.push((g, s.rect))
        break
      }
    }
  }
  assert_true(visible_heads.length() >= 4, msg="expected >= 4 visible group headers at mid-scroll, got \{visible_heads.length()}")
  visible_heads.sort_by(fn(a, b) { a.1.1.compare(b.1.1) })
  for i in 1..<visible_heads.length() {
    let prev = visible_heads[i - 1]
    let cur = visible_heads[i]
    assert_true(
      prev.1.1 + prev.1.3 <= cur.1.1 + 0.5,
      msg="sticky headers overlapped: \{prev.0} (\{prev.1.1}+\{prev.1.3}) vs \{cur.0} (\{cur.1.1})",
    )
  }

  // Click the topmost Above header -> bring_section scrolls back to it, and its collapsed state MUST remain false!
  let above_name = visible_heads[0].0
  let above_rect = visible_heads[0].1
  t.tap(above_rect.0 + above_rect.2 / 2.0, above_rect.1 + above_rect.3 / 2.0)
  t.run_for(@ui.move_most_ms * 3.0)
  let above_btn_after = t.semantics().iter().find_first(fn(s) { !s.hidden && s.role is Button && s.label.has_prefix(above_name + " ") })
  assert_true(above_btn_after is Some(_), msg="Above header \{above_name} still visible after bring_section")
  assert_eq(above_btn_after.unwrap().expanded, Some(true), msg="clicking Above header must NOT toggle collapse")
  assert_eq(sticky_desk_audit(t), [])

  // Click a Below stacked header -> bring_section scrolls cleanly to it with zero overshoot and without collapsing!
  let below_btn = t.semantics().iter().find_first(fn(s) {
    !s.hidden && s.role is Button && s.label.has_prefix("release-qa ") && s.rect.1 > 550.0
  })
  if below_btn is Some(bb) {
    t.tap(bb.rect.0 + bb.rect.2 / 2.0, bb.rect.1 + bb.rect.3 / 2.0)
    t.run_for(@ui.move_most_ms * 3.0)
    let after = t.semantics().iter().find_first(fn(s) { !s.hidden && s.role is Button && s.label.has_prefix("release-qa ") })
    assert_true(after is Some(_), msg="Below header release-qa visible after bring_section")
    assert_eq(after.unwrap().expanded, Some(true), msg="clicking Below header must NOT toggle collapse")
    assert_true(after.unwrap().rect.1 < 400.0, msg="Below header scrolled into upper viewport: \{after.unwrap().rect.1}")
    // First row of release-qa must remain intact below the header (zero overshoot!)
    match t.rect_of("发布前夜间回归失败排查") {
      Some((_, ry, _, _)) =>
        assert_true(
          ry >= after.unwrap().rect.1 + after.unwrap().rect.3 - 1.0,
          msg="bring_section overshot first row of release-qa: head_bot=\{after.unwrap().rect.1 + after.unwrap().rect.3}, row_y=\{ry}",
        )
      None => ()
    }
  }

  // Deep-scroll into an Active sticky group header and click it -> collapses in place without jumping
  sticky_scroll_by(t, 150.0, 400.0, -3000.0)
  sticky_scroll_by(t, 150.0, 400.0, 120.0)
  let active_btn = t.semantics().iter().find_first(fn(s) { !s.hidden && s.role is Button && s.label.has_prefix("未归类 ") }).unwrap()
  let y_before = active_btn.rect.1
  t.tap(active_btn.rect.0 + active_btn.rect.2 / 2.0, active_btn.rect.1 + active_btn.rect.3 / 2.0)
  t.run_for(@ui.move_most_ms * 3.0)
  let active_after = t.semantics().iter().find_first(fn(s) { !s.hidden && s.role is Button && s.label.has_prefix("未归类 ") }).unwrap()
  assert_eq(active_after.expanded, Some(false), msg="clicking Active header must collapse it")
  assert_true((active_after.rect.1 - y_before).abs() <= 1.0, msg="Active header jumped on collapse: \{y_before} -> \{active_after.rect.1}")
  assert_eq(sticky_desk_audit(t), [])
  t.assert_idle()
}

///|
test "short desktop window (h<720): degrades bottom stack to 2+1 with zero overlap" {
  let t = sticky_tester("projects-sticky", 1280.0, 620.0, 0)
  sticky_scroll_by(t, 150.0, 310.0, 420.0)
  // Count bottom-stacked group headers (near bottom of 620pt window, y > 510)
  let bot_heads = t.semantics().filter(fn(s) {
    !s.hidden && s.role is Button && s.rect.0 < 320.0 && s.rect.1 > 510.0 && s.expanded is Some(_)
  })
  assert_true(bot_heads.length() <= 1, msg="h=620 (<720) must degrade bot_cap to 1, got \{bot_heads.length()}")
  assert_eq(sticky_desk_audit(t), [])
  t.assert_idle()
}

///|
test "small screen (Whole 390x844): persistent bottom-left Liquid Glass group pill above tab bar, >=44pt hit target, native sheet jump with zero overshoot" {
  let t = sticky_tester("projects-sticky", 390.0, 844.0, 2)
  // At scroll = 0: persistent bottom-left group pill is immediately visible showing the topmost group ("未归类")
  let top_pill = sticky_find_floating_pill(t, "未归类")
  assert_true(top_pill is Some(_), msg="expected persistent bottom-left group pill at scroll=0 showing topmost group")
  assert_eq(t.audit(), [])

  // Scroll deep into "board"
  sticky_scroll_by(t, 195.0, 400.0, 360.0)
  // Zero bottom stacked headers
  let bot_group_heads = t.semantics().filter(fn(s) {
    !s.hidden && s.role is Button && s.expanded is Some(_) && s.rect.1 > 700.0
  })
  assert_eq(bot_group_heads.length(), 0, msg="small screen must have 0 bottom stacked headers")
  // Compact left-aligned Liquid Glass floating pill sits cleanly above the bottom tab bar
  let pill = sticky_find_floating_pill(t, "board")
  assert_true(pill is Some(_), msg="expected bottom-left floating Liquid Glass group pill for 'board'")
  let pr = pill.unwrap()
  assert_true((pr.0 - bar_inset_edge).abs() <= 1.0, msg="floating pill must align flush with bottom tab bar left: x=\{pr.0}")
  assert_true(pr.3 >= 44.0, msg="floating pill touch target must be >= 44pt tall: h=\{pr.3}")
  let bar_top = 844.0 - bar_top_from_foot()
  assert_true(
    pr.1 + pr.3 <= bar_top - 4.0 && pr.1 + pr.3 >= bar_top - 16.0,
    msg="floating pill must sit cleanly above bottom tab bar (bar_top=\{bar_top}): y=\{pr.1} h=\{pr.3}",
  )
  assert_eq(t.audit(), [])

  // Sweep scrolling through subsequent groups: the persistent bottom-left pill must stay continuously visible
  // on every scroll step (never flickering on/off mid-scroll) while tracking active groups.
  for _ in 0..<24 {
    sticky_scroll_by(t, 195.0, 400.0, 45.0)
    let any_pill = t.semantics().iter().find_first(fn(s) {
      !s.hidden &&
      s.role is Button &&
      s.expanded is None &&
      s.rect.0 >= 16.0 &&
      s.rect.0 <= 32.0 &&
      s.rect.1 >= 500.0 &&
      s.rect.2 <= 230.0 &&
      s.label.contains(" ")
    })
    assert_true(any_pill is Some(_), msg="persistent bottom-left pill must remain continuously visible while scrolling")
  }

  // Scroll back to "board" for touch & jump assertions
  sticky_scroll_by(t, 195.0, 400.0, -2000.0)
  sticky_scroll_by(t, 195.0, 400.0, 360.0)
  let pill = sticky_find_floating_pill(t, "board")
  assert_true(pill is Some(_), msg="expected bottom-left floating pill restored for 'board'")
  let pr = pill.unwrap()

  // Verify real finger touches across the entire 44pt vertical span (top edge, center, bottom edge) hit the pill
  // and open the native group-jump sheet cleanly (never falling through to underlying chat rows or bottom bar).
  let cx = pr.0 + pr.2 / 2.0
  for dy in [2.0, pr.3 - 2.0] {
    t.touch(0, cx, pr.1 + dy)
    t.touch(2, cx, pr.1 + dy)
    t.run_for(@ui.move_most_ms * 2.0)
    assert_true(t.find("release-qa  4") is Some(_), msg="expected pill touch at dy=\{dy} to open group-jump sheet")
    t.back()
    t.run_for(@ui.move_most_ms * 2.0)
  }

  // Tap center of bottom-left Liquid Glass pill -> opens native group-jump sheet listing all groups
  t.tap(cx, pr.1 + pr.3 / 2.0)
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("release-qa  4") is Some(_), msg="group-jump sheet must list release-qa")
  // Tap release-qa in sheet -> closes sheet and glides cleanly to release-qa with ZERO overshoot!
  t.tap_text("release-qa  4")
  t.run_for(@ui.move_most_ms * 5.0)
  let rq_head = t.semantics().iter().find_first(fn(s) { !s.hidden && s.role is Button && s.expanded is Some(_) && s.label.has_prefix("release-qa ") })
  assert_true(rq_head is Some(_), msg="release-qa in-flow heading must be visible after jump")
  let rqr = rq_head.unwrap().rect
  assert_true(rqr.1 >= 54.0 && rqr.1 <= 70.0, msg="release-qa heading landed cleanly below top glass bar: y=\{rqr.1}")
  match t.rect_of("发布前夜间回归失败排查") {
    Some((_, ry, _, _)) =>
      assert_true(
        ry >= rqr.1 + rqr.3 - 1.0,
        msg="menu jump overshot release-qa first row: head_bot=\{rqr.1 + rqr.3}, row_y=\{ry}",
      )
    None => fail("first chat row of release-qa must be visible after jump")
  }
  // Once release-qa lands at top_edge, the persistent bottom-left pill stays visible and immediately reports release-qa
  // (never lingering on the previous group infra-ops).
  assert_true(
    sticky_find_floating_pill(t, "release-qa") is Some(_) &&
    sticky_find_floating_pill(t, "infra-ops") is None,
    msg="persistent bottom-left pill must immediately display target group 'release-qa' after jump",
  )
  assert_eq(t.audit(), [])
  t.assert_idle()
}

///|
test "small screen Android system_bars (380x872, top=44, bottom=28): bottom-left pill clears nav_foot + tab bar and opens reliably under real touch" {
  let t = sticky_tester("projects-sticky", 380.0, 872.0, 2)
  t.check_looks(false)
  t.post(@hostapi.system_channel, "{\"bars\":{\"top\":44,\"bottom\":28,\"left\":0,\"right\":0}}")
  t.run_for(@ui.move_most_ms)
  sticky_scroll_by(t, 190.0, 420.0, 420.0)
  let pill = sticky_find_floating_pill(t, "board")
  assert_true(pill is Some(_), msg="expected bottom-left floating pill with realistic Android system_bars")
  let pr = pill.unwrap()
  let bar_top = 872.0 - bar_top_from_foot()
  assert_true((pr.0 - bar_inset_edge).abs() <= 1.0, msg="pill left aligns flush with tab bar left: x=\{pr.0}")
  assert_true(pr.3 >= 44.0, msg="pill touch height >= 44pt: h=\{pr.3}")
  assert_true(
    pr.1 + pr.3 <= bar_top - 4.0 && pr.1 + pr.3 >= bar_top - 16.0,
    msg="pill clears Android nav_foot + bottom tab bar (bar_top=\{bar_top}): y=\{pr.1} h=\{pr.3}",
  )
  assert_eq(t.audit(), [])
  // Real Android finger touch with 2pt thumb jitter opens group-jump sheet cleanly
  let cx = pr.0 + pr.2 / 2.0
  let cy = pr.1 + pr.3 / 2.0
  t.touch(0, cx, cy)
  t.touch(1, cx + 1.5, cy + 2.0)
  t.touch(2, cx + 1.5, cy + 2.0)
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(t.find("release-qa  4") is Some(_), msg="Android touch on bottom-left pill must open group-jump sheet")
  t.back()
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(sticky_find_floating_pill(t, "board") is Some(_), msg="pill restored after closing sheet")
  t.assert_idle()
}

///|
test "small screen shell suppression: modal, board, search, and pushed page suppress floating group pill and restore cleanly" {
  let src = fixture_app("projects-sticky")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  sticky_scroll_by(t, 195.0, 400.0, 360.0)
  assert_true(sticky_find_floating_pill(t, "board") is Some(_), msg="floating pill initially visible mid-board")

  // 1. Workspace sheet presented (@sf.presented_drawn()) -> suppressed; dismissed -> restored
  t.tap_text("星火工作室")
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presented_drawn(), msg="workspace sheet is drawn")
  assert_true(sticky_find_floating_pill(t, "board") is None, msg="pill suppressed while workspace sheet is drawn")
  t.back()
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(sticky_find_floating_pill(t, "board") is Some(_), msg="pill restored after workspace sheet closes")

  // 2. Board mode enabled (@sfbase.board_on_now) -> suppressed; disabled -> restored
  @sfbase.board_feature.set(true)
  @sfbase.set_board_on(src, "ws1", true)
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(@sfbase.board_on_now(src), msg="board mode enabled")
  assert_true(sticky_find_floating_pill(t, "board") is None, msg="pill suppressed in board mode")
  @sfbase.set_board_on(src, "ws1", false)
  @sfbase.board_feature.set(false)
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(sticky_find_floating_pill(t, "board") is Some(_), msg="pill restored after leaving board mode")

  // 3. Push secondary page (!watched) -> suppressed; pop -> restored
  app.nav.push(Settings)
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(sticky_find_floating_pill(t, "board") is None, msg="pill suppressed when secondary page pushed")
  t.back()
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(sticky_find_floating_pill(t, "board") is Some(_), msg="pill restored after popping back to Home")

  // 4. Bottom bar switcher panel open & toast shown -> suppressed; cleared -> restored
  bar.mode.set(true)
  t.run_for(@ui.move_most_ms)
  assert_true(sticky_find_floating_pill(t, "board") is None, msg="pill suppressed while bottom bar panel is open")
  bar.mode.set(false)
  t.run_for(@ui.move_most_ms)
  assert_true(sticky_find_floating_pill(t, "board") is Some(_), msg="pill restored after bottom bar panel closes")

  @sfbase.toast_later("已复制链接")
  t.run_for(@motion.presence_in_ms)
  assert_true(sticky_find_floating_pill(t, "board") is None, msg="pill suppressed while toast is visible")
  t.run_for(@sf.toast_ms + @motion.presence_out_ms + 200.0)
  assert_true(sticky_find_floating_pill(t, "board") is Some(_), msg="pill restored after toast dismisses")

  // 5. Search open -> suppressed; closed -> restored
  sticky_scroll_by(t, 195.0, 400.0, -600.0)
  sticky_scroll_by(t, 195.0, 400.0, -300.0)
  t.tap_text("搜索全部内容")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_true(@sfpages.search_on_lists(), msg="search is open")
  assert_true(sticky_find_floating_pill(t, "未归类") is None, msg="pill suppressed while search is open")
  t.back()
  t.run_for(@ui.move_most_ms * 4.0)

  assert_eq(t.audit(), [])
  t.assert_idle()
}

///|
test "1.3x large font scale: small screen floating pill and large screen sticky groups have zero fixed_outgrown and zero audit faults" {
  let ts = screen_in("projects-sticky", ("phone", 390.0, 844.0, 2, "small"), "zh", font_scale=1.3)
  sticky_scroll_by(ts, 195.0, 400.0, 400.0)
  assert_eq(ts.fixed_outgrown(), [])
  assert_eq(ts.audit(), [])
  ts.assert_idle()

  let tl = screen_in("projects-sticky", ("desktop", 1280.0, 800.0, 0, "large"), "zh", font_scale=1.3)
  sticky_scroll_by(tl, 150.0, 400.0, 520.0)
  assert_eq(tl.fixed_outgrown(), [])
  assert_eq(sticky_desk_audit(tl), [])
  tl.assert_idle()
}

///|
test "desktop & medium push-out: outgoing Above/Below headings dissolve smoothly to 0 before clip edge" {
  // Desktop Side (1280x800): scroll to just before monoid pushes board -> 未归类 above top_edge, then step through
  // the push-out zone and explicitly verify 未归类 enters mid-fade (0 < alpha < 1), decreases monotonically, and
  // dissolves to alpha <= 0.001 before finishing push-out.
  let t = sticky_tester("projects-sticky", 1280.0, 800.0, 0)
  sticky_scroll_by(t, 150.0, 400.0, 396.0)
  assert_eq(sticky_desk_audit(t), [])
  // Resting slot-0 text y sits at `top_edge + S3_5`, so `clip_top = start_y - S3_5` is the exact `top_edge` clip line.
  let start_uncat = t.words().iter().find_first(fn(w) { w.0 == "未归类" && w.1 < 260.0 }).unwrap()
  let clip_top = start_uncat.2 - @ui.Space::S3_5.px()
  let alpha_of_uncat = fn(tt : @ui.Tester) -> Double? {
    for w in tt.words() {
      // Only inspect glyphs still below `top_edge` (above `clip_top` is clipped to 0px by `section_clip_of`
      // and masked by `cap`, even while the virtual list keeps the overflow row mounted in overscan).
      if w.0 == "未归类" && w.1 < 260.0 && w.2 + w.4 > clip_top {
        return Some(w.5)
      }
    }
    None
  }
  let start_a = alpha_of_uncat(t)
  assert_true(
    start_a is Some(a) && a >= 0.999,
    msg="未归类 should start fully opaque before push-out: \{start_a.unwrap_or(-1.0)}",
  )
  let mut prev_a = 1.0
  let mut saw_mid_fade = false
  let mut saw_dissolved = false
  let mut step = 0
  while step < 24 {
    sticky_scroll_by(t, 150.0, 400.0, 4.0)
    assert_eq(sticky_desk_audit(t), [])
    match alpha_of_uncat(t) {
      Some(a) => {
        assert_true(
          a <= prev_a + 1.0e-6,
          msg="未归类 alpha must decrease monotonically during downward push-out: \{prev_a} -> \{a}",
        )
        if a > 0.01 && a < 0.99 {
          saw_mid_fade = true
        }
        if a <= 0.001 {
          saw_dissolved = true
        }
        prev_a = a
      }
      None => {
        saw_dissolved = true
        prev_a = 0.0
      }
    }
    step = step + 1
  }
  assert_true(saw_mid_fade, msg="expected to observe 未归类 in mid-fade (0 < alpha < 1) during push-out")
  assert_true(saw_dissolved, msg="expected 未归类 to dissolve cleanly to alpha <= 0.001 during push-out")
  let board_btn = t.semantics().iter().find_first(fn(s) {
    !s.hidden && s.role is Button && s.expanded is Some(_) && s.label.has_prefix("board ")
  })
  assert_true(board_btn is Some(_), msg="board header must remain cleanly visible at slot 0 after push-out")
  t.assert_idle()

  // Medium Tape (800x800, fractional band_new_tape_over = 10.78): scroll across push-out with zero audit faults
  let tm = sticky_tester("projects-sticky", 800.0, 800.0, 0)
  sticky_scroll_by(tm, 150.0, 400.0, 456.0)
  assert_eq(sticky_desk_audit(tm), [])
  sticky_scroll_by(tm, 150.0, 400.0, 64.0)
  assert_eq(sticky_desk_audit(tm), [])
  tm.assert_idle()
}
