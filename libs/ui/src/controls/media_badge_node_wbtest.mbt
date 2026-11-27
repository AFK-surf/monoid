// Media corner badges (`video_capsule_node`, `media_ring_node`):
// 24pt scrim capsule concentric in 26pt media cards (no glass), 12pt ring centered at left semicircle (x + h/2)
// across font scales 1.0x..2.0x, icon-only stays 24x24 circle statically and dynamically, round-capped progress
// arc easing smoothly, zero layout/audit faults.

///|
fn video_shade_u64() -> Int64 {
  match video_shade {
    Data(v) => v
    _ => @halt.saying("video_shade is a colour")
  }
}

///|
fn media_badge_tester(
  duration : Double,
  coming : (() -> Double?)?,
  dark? : Bool = false,
  scale? : Double = 1.0,
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=240.0, dark~)
  set_dark(Some(dark))
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.padding(Is((24.0, 24.0, 24.0, 24.0))) |> ignore
    root.box(fn(card) {
      card
      .width(Is(Some(240.0)))
      .height(Is(Some(160.0)))
      .radius(Is(message_file_corner))
      .ground(By(fn() { theme().p.card }))
      .clips(Is(true))
      |> ignore
      match coming {
        Some(f) => video_capsule_node(card, duration, corner=message_file_corner, coming=f)
        None => video_capsule_node(card, duration, corner=message_file_corner)
      }
    })
    |> ignore
  })
  t.set_font_scale(scale)
  t.draw()
  t
}

///|
test "video_capsule_node: 24pt scrim capsule, concentric ring across 1x..2x, icon-only 24x24 circle statically and dynamically" {
  let shade = video_shade_u64()
  for scale in [1.0, 1.3, 1.8, 2.0] {
    for dark in [false, true] {
      let part = @signals.signal(Some(0.37))
      let t = media_badge_tester(42000.0, Some(fn() { part.get() }), dark~, scale~)
      assert_true(t.find("37%") is Some(_), msg="scale=\{scale} dark=\{dark}: 37% shown")
      assert_eq(
        t.drawn_instances().filter(fn(a) { a.length() > 5 && a[5] == 6.0 }).length(),
        0,
        msg="scale=\{scale} dark=\{dark}: no glass on media badge",
      )
      let pills = t.drawn_rect_corners().filter(fn(r) { r.4 == shade })
      assert_eq(pills.length(), 1, msg="scale=\{scale} dark=\{dark}: 1 video_shade pill")
      let (px, py, _pw, ph, _, _) = pills[0]
      let expected_h = words_box_high(video_capsule_h, video_capsule_words, scale)
      assert_true((ph - expected_h).abs() <= 0.5, msg="scale=\{scale} dark=\{dark}: h=\{ph} vs \{expected_h}")
      let ring = t.get(ProgressBar)
      let rx = ring.rect.0 + ring.rect.2 / 2.0
      let ry = ring.rect.1 + ring.rect.3 / 2.0
      assert_true(
        (rx - (px + ph / 2.0)).abs() <= 0.5 && (ry - (py + ph / 2.0)).abs() <= 0.5,
        msg="scale=\{scale} dark=\{dark}: ring center (\{rx}, \{ry}) vs left arc (\{px + ph / 2.0}, \{py + ph / 2.0})",
      )
      let audit = t.audit()
      assert_eq(audit, [], msg="scale=\{scale} dark=\{dark}: audit=\{Repr(audit)}")
      assert_eq(t.fixed_outgrown(), [], msg="scale=\{scale} dark=\{dark}: fixed_outgrown")
      t.set_font_scale(1.0)
    }
  }
  // Idle duration mode (duration in milliseconds: 125000 ms -> 2:05)
  let t_idle = media_badge_tester(125000.0, None, dark=false)
  assert_true(t_idle.find("2:05") is Some(_))
  let idle_audit = t_idle.audit()
  assert_eq(idle_audit, [], msg="idle audit=\{Repr(idle_audit)}")
  // Static icon-only (duration == 0) stays a symmetric 24x24 circle across 1x..2x font scales
  for scale in [1.0, 1.3, 1.8, 2.0] {
    let t_icon = media_badge_tester(0.0, None, dark=false, scale~)
    let icon_pills = t_icon.drawn_rect_corners().filter(fn(r) { r.4 == shade })
    assert_eq(icon_pills.length(), 1, msg="icon scale=\{scale}")
    let (_, _, pw, ph, _, _) = icon_pills[0]
    assert_true(
      (pw - media_badge_h).abs() <= 0.5 && (ph - media_badge_h).abs() <= 0.5,
      msg="icon scale=\{scale}: expected 24x24 circle, got \{pw}x\{ph}",
    )
    let icon_audit = t_icon.audit()
    assert_eq(icon_audit, [], msg="icon scale=\{scale} audit=\{Repr(icon_audit)}")
    t_icon.set_font_scale(1.0)
  }
  // Dynamic coming Some(0.37) -> None with duration == 0 eases smoothly without a 5pt jump and settles to a 24x24 circle
  let dyn_part : @signals.Signal[Double?] = @signals.signal(Some(0.37))
  let t_dyn = media_badge_tester(0.0, Some(fn() { dyn_part.get() }), dark=false)
  assert_true(t_dyn.find("37%") is Some(_))
  let w_start = t_dyn.drawn_rect_corners().filter(fn(r) { r.4 == shade })[0].2
  dyn_part.set(None)
  t_dyn.draw()
  let w_immediate = t_dyn.drawn_rect_corners().filter(fn(r) { r.4 == shade })[0].2
  assert_true(
    (w_start - w_immediate).abs() <= 0.5,
    msg="duration=0 coming->None should not jump on frame 0: before=\{w_start}, immediate=\{w_immediate}",
  )
  t_dyn.run_for(@ui.move_most_ms)
  let dyn_pills = t_dyn.drawn_rect_corners().filter(fn(r) { r.4 == shade })
  assert_eq(dyn_pills.length(), 1)
  let (_, _, dpw, dph, _, _) = dyn_pills[0]
  assert_true(
    (dpw - media_badge_h).abs() <= 0.5 && (dph - media_badge_h).abs() <= 0.5,
    msg="dynamic icon-only after coming=None: expected 24x24 circle, got \{dpw}x\{dph}",
  )
  let dyn_audit = t_dyn.audit()
  assert_eq(dyn_audit, [], msg="dyn audit=\{Repr(dyn_audit)}")
  set_dark(None)
}

///|
test "media_ring_node: smooth SDF border track and round-capped arc line ease smoothly when progress advances" {
  let part = @signals.signal(0.0)
  let t = @ui.Tester::new(fn(_c) {  }, w=100.0, h=100.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.row(Is(true)).lines_up(Is(Some(Start))) |> ignore
    media_ring_node(root, fn() { part.get() }, label=fn() { "下载进度" }) |> ignore
  })
  t.draw()
  assert_eq(t.drawn_lines().length(), 0, msg="at 0%: no arc line yet (track is SDF border)")
  part.set(0.5)
  t.run_for(@motion.progress_ms)
  assert_true(t.drawn_lines().length() > 0, msg="at 50%: round-capped arc line drawn")
  let ring_audit = t.audit()
  assert_eq(ring_audit, [], msg="ring audit=\{Repr(ring_audit)}")
}
