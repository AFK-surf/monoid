// Tests for declarative NavTransition protocol: layered push/pop parallax & scrim,
// modal rise depth (scale + scrim), root_progress continuity, and interruptible dual-ended replace_tab.

///|
fn layered_stack(
  transition : NavTransition,
) -> (Tester, Nav[String], Ref[Int], Array[String]) {
  let taps = Ref(0)
  let left : Array[String] = []
  let nav = Nav::new("tab0", on_leave=fn(p) { left.push(p) })
  let t = Tester::new(fn(_c) {  }, w=390.0, h=844.0, platform=1)
  t.check_looks(false)
  set_view_app(fn(root) {
    nav_view(
      root,
      nav,
      fn(c, p) { c.text(p, size=14.0) |> ignore },
      bg=fn() { 0xFFFFFFFFL },
      keeps_made=true,
      transition~,
      made=fn(p) {
        Some(
          (
            "p/" + p,
            fn(v, page, _under, _stint, _k) {
              v.box(fn(head) {
                head
                .height(Is(Some(60.0)))
                .words(By(fn() { "page:" + page() }), look={ ..@view.words_plain, size: 14.0 })
                .presses(Is(true))
                .on_press(fn() { taps.val += 1 })
                |> ignore
              })
              |> ignore
            },
          ),
        )
      },
    )
    |> ignore
  })
  t.draw()
  (t, nav, taps, left)
}

///|
fn black_scrim_alphas(t : Tester) -> Array[Int64] {
  t
  .drawn_rects()
  .filter(fn(r) { r.2 >= 380.0 && r.3 >= 800.0 && (r.4 >> 8) == 0L && (r.4 & 0xFFL) > 0L })
  .map(fn(r) { r.4 & 0xFFL })
}

///|
test "NavTransition::layered push/pop has under_parallax < 1, continuous scrim, and edge hairline" {
  let (t, nav, _, _) = layered_stack(NavTransition::layered())
  let dur = move_ms(390.0)
  view_event(fn() { nav.push("detail") })
  t.draw()
  t.run_for(dur * 0.4)
  let x_top = t.rect_of("page:detail").unwrap().0
  let x_under = t.rect_of("page:tab0").unwrap().0
  let moved_top = 390.0 - x_top
  assert_true(x_top > 0.0 && x_top < 390.0, msg="top x=\{x_top}")
  assert_true(x_under < 0.0, msg="under should parallax left: \{x_under}")
  // Covered page travels ~0.28x of foreground travel (well below 1:1 edge-to-edge)
  let ratio = -x_under / moved_top
  assert_true(ratio > 0.22 && ratio < 0.34, msg="parallax ratio=\{ratio}, x_top=\{x_top}, x_under=\{x_under}")
  // Covered page has non-zero black scrim during transition
  let scrims = black_scrim_alphas(t)
  assert_true(!scrims.is_empty(), msg="expected under scrim during push")
  // Foreground page has 1px leading-edge separation hairline
  let edges = t
    .drawn_rects()
    .filter(fn(r) { (r.2 - 1.0).abs() < 0.1 && r.3 >= 800.0 && (r.4 >> 8) == 0L && (r.4 & 0xFFL) > 0L })
  assert_true(!edges.is_empty(), msg="expected leading-edge hairline during push")
  // Settle: scrim and hairline vanish
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(black_scrim_alphas(t), [])
  assert_eq(t.rect_of("page:detail").unwrap().0, 0.0)
}

///|
test "NavTransition::layered rise applies full-bleed scrim & top hairline, and custom rise_under_scale scales covered page" {
  // Default layered(): rise_under_scale = 1.0 (full-bleed scrim, no background gap) + 1px top hairline on rising page
  let (t, nav, _, _) = layered_stack(NavTransition::layered())
  let dur = move_ms(844.0)
  let rest_w = t.rect_of("page:tab0").unwrap().2
  view_event(fn() { nav.rise("modal") })
  t.draw()
  t.run_for(dur * 0.5)
  let mid_y = t.rect_of("page:modal").unwrap().1
  assert_true(mid_y > 0.0 && mid_y < 844.0, msg="modal rising y=\{mid_y}")
  assert_true(!black_scrim_alphas(t).is_empty(), msg="expected rise scrim")
  assert_eq(t.rect_of("page:tab0").unwrap().2, rest_w)
  let top_lines = t
    .drawn_rects()
    .filter(fn(r) { r.2 >= 380.0 && (r.3 - 1.0).abs() < 0.1 && (r.4 >> 8) == 0L && (r.4 & 0xFFL) > 0L })
  assert_true(!top_lines.is_empty(), msg="expected 1px top hairline on rising modal")
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(black_scrim_alphas(t), [])
  // Custom rise_under_scale = 0.975: framework still scales covered page smoothly
  let (t2, nav2, _, _) = layered_stack({ ..NavTransition::layered(), rise_under_scale: 0.975 })
  let rest_w2 = t2.rect_of("page:tab0").unwrap().2
  view_event(fn() { nav2.rise("modal") })
  t2.draw()
  t2.run_for(dur * 0.5)
  let mid_w2 = t2.rect_of("page:tab0").unwrap().2
  assert_true(mid_w2 < rest_w2 && mid_w2 >= rest_w2 * 0.97, msg="rise scale width=\{mid_w2} rest=\{rest_w2}")
  t2.run_for(nav2.rest() - t2.time() + 16.0)
  assert_eq(black_scrim_alphas(t2), [])
}

///|
test "Nav::replace_tab runs dual-ended cross-transition, blocks outgoing taps, shelves on settle, and is interruptible" {
  let tr = NavTransition::layered()
  let tab_dur = tr.tab_ms
  let (t, nav, taps, _) = layered_stack(tr)
  let s0 = nav.top_stay().0
  view_event(fn() { nav.replace_tab("tab1", way=1, dur=tab_dur, kept=true) })
  t.draw()
  let s1 = nav.top_stay().0
  let t0 = t.time()
  // Curve invariant across 100 samples: zero words_over (min(out_alpha, in_alpha) < 0.12 everywhere)
  let mut max_overlap = 0.0
  for i in 0..<=100 {
    let at = t0 + tab_dur * (i.to_double() / 100.0)
    let (_, a_out) = nav.tab_body_motion(s0, fn() { at }, slide=tr.tab_slide)
    let (_, a_in) = nav.tab_body_motion(s1, fn() { at }, slide=tr.tab_slide)
    let ov = dmin(a_out, a_in)
    if ov > max_overlap {
      max_overlap = ov
    }
  }
  assert_true(max_overlap < 0.12, msg="tab cross-fade overlap=\{max_overlap} >= 0.12")
  // At t=20ms: outgoing tab0 is already crisply fading out & sliding left (no sticky linger), non-interactive
  t.frame_at(t0 + tab_dur * (20.0 / 260.0))
  assert_true(nav.shows(s0), msg="outgoing tab0 should remain shown at 20ms")
  assert_true(!nav.takes(s0), msg="outgoing tab0 must not take presses")
  let w0 = t.words().filter(fn(w) { w.0 == "page:tab0" })
  assert_true(!w0.is_empty() && w0[0].5 > 0.1 && w0[0].5 < 0.85, msg="tab0 crisply fading at 20ms: \{Repr(w0)}")
  assert_true(w0[0].1 < 0.0, msg="tab0 slides left when way=1: x=\{w0[0].1}")
  // At t=55ms: incoming tab1 is already visibly sliding in smoothly from right (no 92ms dead valley)
  t.frame_at(t0 + tab_dur * (55.0 / 260.0))
  let w1 = t.words().filter(fn(w) { w.0 == "page:tab1" })
  assert_true(!w1.is_empty() && w1[0].5 > 0.01 && w1[0].5 < 1.0, msg="tab1 already entering at 55ms: \{Repr(w1)}")
  assert_true(w1[0].1 > 0.0, msg="tab1 slides in from right when way=1: x=\{w1[0].1}")
  // Rapid interrupt to tab2 mid-flight: settles tab0 onto shelf immediately, starts tab1 -> tab2
  view_event(fn() { nav.replace_tab("tab2", way=1, dur=tab_dur, kept=true) })
  t.draw()
  assert_true(nav.shelved("tab0") is Some(_), msg="interrupted tab0 must be shelved")
  t.run_for(tab_dur + frame_period_default)
  assert_true(nav.shelved("tab1") is Some(_), msg="settled tab1 must be shelved")
  assert_true(t.find("page:tab2") is Some(_))
  assert_true(t.find("page:tab1") is None)
  let before_taps = taps.val
  t.tap(40.0, 20.0)
  assert_eq(taps.val, before_taps + 1)
}

///|
test "Nav::root_progress tracks push, deep stack, swipe-back gesture, and pop continuously" {
  let (t, nav, _, _) = layered_stack(NavTransition::layered())
  assert_eq(nav.root_progress(fn() { t.time() }), 1.0)
  let dur = move_ms(390.0)
  view_event(fn() { nav.push("d1") })
  t.draw()
  t.run_for(dur * 0.4)
  let mid_push = nav.root_progress(fn() { t.time() })
  assert_true(mid_push > 0.05 && mid_push < 0.95, msg="mid push root_progress=\{mid_push}")
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(nav.root_progress(fn() { t.time() }), 0.0)
  // Deep stack (depth 3): root stays 0.0 even while popping d2 -> d1
  view_event(fn() { nav.push("d2") })
  t.draw()
  t.run_for(nav.rest() - t.time() + 16.0)
  view_event(fn() { nav.pop() |> ignore })
  t.draw()
  t.run_for(dur * 0.4)
  assert_eq(nav.root_progress(fn() { t.time() }), 0.0)
  t.run_for(nav.rest() - t.time() + 16.0)
  // Interactive swipe-back from d1 to root: root_progress tracks finger 1:1
  t.hold_drag(4.0, 400.0, 199.0, 400.0)
  assert_true(nav.in_gesture())
  let swipe_p = nav.root_progress(fn() { t.time() })
  assert_true(swipe_p > 0.4 && swipe_p < 0.6, msg="swipe halfway root_progress=\{swipe_p}")
  t.release(199.0, 400.0)
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(nav.root_progress(fn() { t.time() }), 1.0)
}

///|
test "View::park syncs a11y on replace_tab settle and shared Scroll survives same-frame old-item unmount" {
  // 1. replace_tab settling tab0 onto shelf (View::park without adding a new sibling) must keep host a11y in sync
  let tr = NavTransition::layered()
  let tab_dur = tr.tab_ms
  let (t, nav, _, _) = layered_stack(tr)
  t.set_a11y(true)
  t.draw()
  view_event(fn() { nav.replace_tab("tab1", way=1, dur=tab_dur, kept=true) })
  t.draw()
  t.run_for(tab_dur + frame_period_default)
  assert_true(nav.shelved("tab0") is Some(_))
  // 2. When each replaces an unkept item with a new item sharing the same Scroll, the old item's owns() must not wipe
  //    the new item's scrolls_window fill/host.
  let shared_scroll = @view.Scroll::list()
  let which = @signals.signal(0)
  let t2 = Tester::new(fn(_c) {  }, w=390.0, h=400.0, platform=1)
  t2.check_looks(false)
  set_view_app(fn(root) {
    root.each(fn() { [which.get()] }, fn(k) { k }, fn(v, key) {
      let id = key.untracked()
      v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      v.scrolls_window(shared_scroll, fn() { [0, 1, 2] }, est=40.0, fn(row, i) {
        row
          .height(Is(Some(40.0)))
          .words(Is("item-\{id}-\{i}"), look={ ..@view.words_plain, size: 14.0 })
          |> ignore
      })
      |> ignore
    })
  })
  t2.draw()
  assert_true(t2.find("item-0-0") is Some(_))
  view_event(fn() { which.set(1) })
  t2.draw()
  assert_true(t2.find("item-1-0") is Some(_), msg="new list sharing Scroll must keep its rows after old item unmounts")
}

///|
test "NavTransition::layered clips occluded beside words and text_runs during horizontal push while keeping exposed parallax" {
  let nav = Nav::new("base")
  let t = Tester::new(fn(_c) {  }, w=390.0, h=844.0, platform=1)
  t.check_looks(false)
  set_view_app(fn(root) {
    nav_view(
      root,
      nav,
      fn(c, p) { c.text(p, size=14.0) |> ignore },
      bg=fn() { 0xFFFFFFFFL },
      transition=NavTransition::layered(),
      made=fn(p) {
        Some(
          (
            "clip/" + p,
            fn(v, page, _under, _stint, _k) {
              v.box(fn(row) {
                row.row(Is(true)).height(Is(Some(60.0))) |> ignore
                row.box(fn(left) {
                  left.width(Is(Some(80.0))).words(By(fn() { "left:" + page() }), look={ ..@view.words_plain, size: 14.0 })
                  |> ignore
                })
                |> ignore
                row.box(fn(spacer) { spacer.grow(Is(1.0)) |> ignore }) |> ignore
                row.box(fn(right) {
                  right.width(Is(Some(80.0))).words(By(fn() { "right:" + page() }), look={ ..@view.words_plain, size: 14.0 })
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            },
          ),
        )
      },
    )
    |> ignore
  })
  t.draw()
  let left_rest_x = t.rect_of("left:base").unwrap().0
  assert_true(t.words().iter().any(fn(w) { w.0 == "right:base" }))
  let dur = move_ms(390.0)
  view_event(fn() { nav.push("detail") })
  t.draw()
  t.run_for(dur * 0.5)
  // Mid-push: top page covers right half of screen; occluded right:base must be absent from words() and text_runs()
  let detail_x = t.rect_of("left:detail").unwrap().0
  assert_true(detail_x > 10.0 && detail_x < 300.0, msg="detail sliding in at x=\{detail_x}")
  assert_false(
    t.words().iter().any(fn(w) { w.0 == "right:base" }),
    msg="occluded right:base must be clipped out of words()",
  )
  assert_false(
    t.text_runs().iter().any(fn(r) { r.text == "right:base" }),
    msg="occluded right:base must be clipped out of text_runs()",
  )
  // Exposed left:base stays visible at accurate parallax x < left_rest_x
  let left_mid = t.words().filter(fn(w) { w.0 == "left:base" })
  assert_true(!left_mid.is_empty() && left_mid[0].1 < left_rest_x, msg="exposed left:base parallax: \{Repr(left_mid)}")
}
