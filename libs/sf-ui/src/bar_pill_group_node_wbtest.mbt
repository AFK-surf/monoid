// Tests for `bar_pill_group_node`: single-layer iOS 26 / macOS 26 liquid glass (`kind == 6`, zero nested glass),
// tight outside-only `bar_pill_shadow()` (`shadow_outside == true`), exact concentric corners for both 34pt `round_key_node`
// (`height=40, pad=3`) and 32pt `icon_button_node` (`height=36, pad=2`), 40pt standalone circle (`height=40, pad=0`),
// `MBUI_GLASS=solid` degradation (`panel_ground()` + `control_edge_w` `panel_edge()`, 0 glass instances), and clean
// `Tester::audit()` in both Light and Dark themes.

///|
fn has_pill_solid_edge(t : @ui.Tester, edge_color : Int64) -> Bool {
  let ch = fn(v : Double) { (v * 255.0).round().to_int64() }
  t.drawn_instances().iter().any(fn(a) {
    if a.length() > 15 && a[5] == 0.0 && (a[6] - control_edge_w).abs() < 0.01 {
      let c = (ch(a[12]) << 24) | (ch(a[13]) << 16) | (ch(a[14]) << 8) | ch(a[15])
      c == edge_color
    } else {
      false
    }
  })
}

///|
fn pill_group_tester(kind : String, dark : Bool, solid : Bool) -> @ui.Tester {
  presenters_reset()
  set_words(fn(key, _) { key })
  let platform = if kind == "wide" { 0 } else { 2 }
  let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=160.0, dark~, platform~)
  set_dark(Some(dark))
  if solid {
    @ui.set_glass_solid(Some(true))
  } else {
    @ui.set_glass_solid(None)
  }
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(bar) {
      bar
      .row(Is(true))
      .grow(Is(1.0))
      .padding(Is((24.0, 24.0, 24.0, 24.0)))
      .lines_up(Is(Some(Middle)))
      .ground(By(fn() { theme().p.bg }))
      |> ignore
      if kind == "narrow" {
        bar_pill_group_node(bar, height=40.0, pad=3.0, gap=2.0, fn(g) {
          round_key_node(g, "bell", fn() { "Attention" }, fn() {  })
          round_key_node(g, "filter", fn() { "Filter" }, fn() {  }, icon_size=20.0)
        })
        |> ignore
      } else if kind == "back" {
        bar_pill_group_node(bar, height=40.0, pad=0.0, gap=0.0, fn(g) {
          round_key_node(g, "chevron-left", fn() { "Back" }, fn() {  }, side=40.0, icon_size=22.0)
        })
        |> ignore
      } else {
        bar_pill_group_node(bar, height=36.0, pad=2.0, gap=2.0, fn(g) {
          icon_button_node(g, "info", fn() { "Info" }, fn() {  }) |> ignore
          icon_button_node(g, "more", fn() { "More" }, fn() {  }) |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "bar_pill_group_node renders single-layer liquid glass with shadow_outside, zero corner faults, and clean solid fallback in light and dark" {
  for kind in ["narrow", "back", "wide"] {
    for dark in [false, true] {
      let t = pill_group_tester(kind, dark, false)
      let glass = t.drawn_glass()
      let liquid_count = glass.filter(fn(g) { g.4 == 6 }).length()
      let outside_shadow = has_outside_shadow(t)
      let corners = t.corner_faults()
      let audits = t.audit()
      assert_eq(
        (kind, dark, glass.length(), liquid_count, outside_shadow, corners, audits),
        (kind, dark, 1, 1, true, [], []),
      )

      let ts = pill_group_tester(kind, dark, true)
      let solid_glass = ts.drawn_glass().length()
      let expected_solid = panel_ground()
      let has_ground = ts.drawn_rects().iter().any(fn(r) { r.4 == expected_solid })
      let has_edge = has_pill_solid_edge(ts, panel_edge())
      let solid_corners = ts.corner_faults()
      let solid_audits = ts.audit()
      @ui.set_glass_solid(None)
      assert_eq(
        (kind, dark, solid_glass, has_ground, has_edge, solid_corners, solid_audits),
        (kind, dark, 0, true, true, [], []),
      )
    }
  }
}

///|
test "bar_pill_group_node interactive press drives GPU spot highlight, spring scale, theme-adaptive ink, and settles cleanly" {
  for dark in [false, true] {
    presenters_reset()
    set_words(fn(key, _) { key })
    let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=160.0, dark~, platform=2)
    set_dark(Some(dark))
    @ui.set_glass_solid(None)
    let pill_ref : Ref[@view.View?] = Ref(None)
    let key_ref : Ref[@view.View?] = Ref(None)
    let ws_ref : Ref[@view.View?] = Ref(None)
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(bar) {
        bar
        .row(Is(true))
        .grow(Is(1.0))
        .padding(Is((24.0, 24.0, 24.0, 24.0)))
        .lines_up(Is(Some(Middle)))
        .ground(By(fn() { theme().p.bg }))
        |> ignore
        let g = bar_pill_group_node(bar, height=40.0, pad=3.0, gap=2.0, fn(g) {
          g.box(fn(k) {
            key_ref.val = Some(k)
            round_key_node(k, "bell", fn() { "Attention" }, fn() {  })
          })
          |> ignore
          action_box_node(g, fn() { "Workspace" }, fn(_) {  }, fn(s) {
            ws_ref.val = Some(s)
            s
            .row(Is(true))
            .height(Is(Some(34.0)))
            .radius(Is(17.0))
            .padding(Is((8.0, 0.0, 8.0, 0.0)))
            .lines_up(Is(Some(Middle)))
            |> ignore
            bar_pill_key_press_node(s)
            words_node(s, fn() { "AFK AI" }, fn() { @ui.text_style(size=Ui, color=Fg) }) |> ignore
          })
          |> ignore
        })
        pill_ref.val = Some(g)
      })
      |> ignore
    })
    t.draw()
    // Dark mode press ink must be bright (non-black) so ripples/overlays are clearly visible over dark glass.
    let ink = bar_pill_press_ink()
    let rgb = (ink >> 8) & 0xFFFFFFL
    if dark {
      assert_true(rgb > 0x808080L, msg="dark press ink rgb should be bright, got \{ink}")
    } else {
      assert_true(rgb < 0x808080L, msg="light press ink rgb should be dark, got \{ink}")
    }
    let pill = pill_ref.val.unwrap()
    let scope = pill.lent(pill_press_lent).unwrap()
    assert_eq(scope.spot.untracked(), None)
    assert_true((pill.drawn_scale() - 1.0).abs() < 0.001)
    for target in [key_ref.val.unwrap(), ws_ref.val.unwrap()] {
      let (tx, ty, tw, th) = target.placed_window_now()
      let (cx, cy) = (tx + tw / 2.0, ty + th / 2.0)
      t.press_at(cx, cy)
      t.run_for(part_whole_ms)
      assert_true(scope.spot.untracked() is Some(_), msg="spot must be active while pressed (dark=\{dark})")
      assert_true(pill.drawn_scale() > 1.01, msg="pill must spring-scale > 1.01 while pressed, got \{pill.drawn_scale()}")
      t.release(cx, cy)
      t.run_for(@ui.move_most_ms)
      assert_eq(scope.spot.untracked(), None)
      assert_true((pill.drawn_scale() - 1.0).abs() < 0.002, msg="pill must settle back to 1.0, got \{pill.drawn_scale()}")
    }
    t.assert_idle()
  }
}
