// Whitebox tests for Wave 21 Track C1 controls, capsules, and lenses:
// - `liquid_knob_glass`
// - `liquid_pill_group_node` (Horizontal & Vertical, custom tint, `bind_pill_press_by`,
//   `liquid_pill_trigger_lent` morph_glass / ly > 0 / ly < 0)
// - `liquid_capsule_decorate` / `liquid_capsule_node` (all 5 LiquidCapsuleTone variants,
//   interactive GPU spot, extra_blur, active=false zero hidden glass, MBUI_GLASS=solid)
// - `liquid_press_glass_decorate` and `liquid_lift_shell_decorate`
// - `liquid_lens_overlay_node` (lazy mount 0 nodes/glass at rest, release laid == 0 & 0 glass)
// - `liquid_loupe_node` (active follow, zoom, release -> 0 glass)
// All verified in Light & Dark themes with `t.audit() == []` and zero nested glass.

///|
/// Detects an active GPU `spot` on any `Glass::liquid` (`kind == 6`) instance, including adaptive
/// glass (`liquid_floating_glass`), where `a[14]` encodes `-(spot_v + 1.0)` (`< -1.0` when lit).
fn has_any_liquid_spot(t : @ui.Tester) -> Bool {
  t.drawn_instances().iter().any(fn(a) { a.length() > 14 && a[5] == 6.0 && (a[14] > 0.0 || a[14] < -1.0) })
}

///|
test "Wave 21 C1: liquid_knob_glass recipe matches clear refractive lens parameters" {
  let g_default = liquid_knob_glass()
  let g_custom = liquid_knob_glass(solid=0x223344FFL)
  assert_eq(
    (g_default.blur, g_default.tint, g_default.bezel, g_default.refraction, g_default.chroma, g_default.adaptive, g_custom.solid),
    (0.0, 0xFFFFFF00L, 7.0, 5.0, -0.06, false, 0x223344FFL),
  )
}

///|
test "Wave 21 C1: liquid_pill_group_node supports Horizontal & Vertical, tint, bind_pill_press_by, and liquid_pill_trigger_lent" {
  for dark in [false, true] {
    let host_down = @signals.signal(false)
    let h_pill_ref : Ref[@view.View?] = Ref(None)
    let v_pill_ref : Ref[@view.View?] = Ref(None)
    let t = lg_case(dark~, fn(p) {
      p.box(fn(row) {
        row.row(Is(true)).gap(Is(24.0)).lines_up(Is(Some(Start))) |> ignore
        let hp = liquid_pill_group_node(
          row,
          height=40.0,
          pad=3.0,
          gap=2.0,
          tint=fn() { 0x0066CC44L },
          fn(pg) {
            @headless.button(pg, fn() { "Snap" }, fn(_) {  }, fn(b, _) {
              b.width(Is(Some(34.0))).height(Is(Some(34.0))).radius(Is(17.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
              bind_pill_press_by(b, fn() { host_down.get() })
              flight_icon(b, 18.0, fn() { colors().content })
            })
            |> ignore
          },
        )
        h_pill_ref.val = Some(hp)
        let vp = liquid_pill_group_node(
          row,
          height=36.0,
          pad=2.0,
          pad_y=1.0,
          gap=0.0,
          direction=Vertical,
          floating=true,
          fn(pg) {
            @headless.button(pg, fn() { "Up" }, fn(_) {  }, fn(b, _) {
              b
              .width(Is(Some(32.0)))
              .height(Is(Some(32.0)))
              .radius(Is(16.0))
              .margin(Is((0.0, 1.0, 0.0, 1.0)))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              |> ignore
              bind_pill_press(b)
              flight_icon(b, 16.0, fn() { colors().content })
            })
            |> ignore
            @headless.button(pg, fn() { "Down" }, fn(_) {  }, fn(b, _) {
              b
              .width(Is(Some(32.0)))
              .height(Is(Some(32.0)))
              .radius(Is(16.0))
              .margin(Is((0.0, 1.0, 0.0, 1.0)))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              |> ignore
              bind_pill_press(b)
              flight_icon(b, 16.0, fn() { colors().content })
            })
            |> ignore
          },
        )
        v_pill_ref.val = Some(vp)
      })
      |> ignore
    })
    assert_no_nested_glass(t, "pill group horizontal + vertical")
    let hp = h_pill_ref.val.unwrap()
    let vp = v_pill_ref.val.unwrap()
    let (_, _, vw, vh) = vp.placed_window_now()
    let trig = hp.lent(liquid_pill_trigger_lent).unwrap()
    let child_tracked = trig.children.length() == 1
    // Host-driven press via bind_pill_press_by steers outer spot and scale
    host_down.set(true)
    t.run_for(held_ms)
    let by_pressed = (trig.fx.untracked().0 is Some(_), has_active_liquid_spot(t), hp.drawn_scale() > 1.01)
    host_down.set(false)
    t.run_for(springs_out)
    let by_released = (trig.fx.untracked().0 is None, (hp.drawn_scale() - 1.0).abs() < 0.002)
    // Trigger scope layer switching: ly > 0 sets private layer, ly < 0 hides glass, morph_glass overrides
    let rest_glass_count = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    trig.fx.set((None, -1))
    t.draw()
    let hidden_glass_count = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    trig.morph_glass.val = Some(fn() { Some(liquid_menu_morph_glass(0.5)) })
    trig.fx.set((None, 101))
    t.draw()
    let morph_glass_count = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    trig.morph_glass.val = None
    trig.fx.set((None, 0))
    t.draw()
    assert_eq(
      (
        dark,
        vw,
        vh > vw,
        child_tracked,
        by_pressed,
        by_released,
        rest_glass_count,
        hidden_glass_count,
        morph_glass_count,
        t.audit(),
      ),
      (dark, 36.0, true, true, (true, true, true), (true, true), 2, 1, 2, []),
    )
  }
}

///|
test "Wave 21 C1: liquid_capsule_node covers all 5 tones, interactive spot, extra_blur, active=false, and MBUI_GLASS=solid" {
  for dark in [false, true] {
    let active = @signals.signal(true)
    let extra = @signals.signal(0.0)
    let t = lg_case(dark~, fn(p) {
      p.box(fn(row) {
        row.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
        let tones : Array[(String, LiquidCapsuleTone)] = [
          ("Float", Floating),
          ("Bar", BarPill),
          ("Clear", ViewerClear),
          ("Dark", ViewerDark),
          ("Panel", Panel),
        ]
        for pair in tones {
          let (name, tone) = pair
          let ink_fn = fn() {
            match tone {
              ViewerDark => white
              _ => colors().content
            }
          }
          liquid_capsule_node(
            row,
            tone~,
            min_height=Some(36.0),
            radius=Some(18.0),
            extra_blur=fn() { extra.get() },
            fn(c) {
              c.padding(Is((12.0, 6.0, 12.0, 6.0))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
              c.box(fn(w) { w.words(Is(name), look=words_at(14.0)).ink(By(ink_fn)) |> ignore }) |> ignore
            },
          )
          |> ignore
        }
      })
      |> ignore
      p.box(fn(row2) {
        row2.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
        @headless.button(row2, fn() { "SpotCap" }, fn(_) {  }, fn(b, _) {
          liquid_capsule_decorate(b, tone=Floating, min_height=Some(36.0), radius=Some(18.0), interactive=true)
          |> ignore
          b.padding(Is((14.0, 6.0, 14.0, 6.0))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
          b.box(fn(w) { w.words(Is("SpotCap"), look=words_at(14.0)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
        })
        |> ignore
        liquid_capsule_node(
          row2,
          tone=Floating,
          min_height=Some(36.0),
          radius=Some(18.0),
          active=fn() { active.get() },
          fn(c) {
            c.padding(Is((12.0, 6.0, 12.0, 6.0))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
            c.box(fn(w) { w.words(Is("ToggleCap"), look=words_at(14.0)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
    assert_no_nested_glass(t, "liquid capsule tones")
    let count_on = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    // active=false removes glass completely (0 hidden glass)
    active.set(false)
    extra.set(4.0)
    t.draw()
    let count_off = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    // Interactive press illuminates GPU spot
    let (sx, sy) = middle(t, Button, "SpotCap")
    t.touch(0, sx, sy)
    t.run_for(a_frame)
    let spot_on = has_any_liquid_spot(t)
    t.touch(2, sx, sy)
    t.run_for(springs_out)
    let audits = t.audit()
    // MBUI_GLASS=solid degrades all capsules to 0 liquid glass instances
    @ui.set_glass_solid(Some(true))
    t.draw()
    let solid_liquid = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    @ui.set_glass_solid(None)
    assert_eq(
      (dark, count_on, count_off, spot_on, solid_liquid, audits),
      (dark, 7, 6, true, 0, []),
    )
  }
}

///|
test "Wave 21 C1: liquid_press_glass_decorate and liquid_lift_shell_decorate" {
  for dark in [false, true] {
    let lift = @signals.signal(0.0)
    let ih_ref : Ref[InteractiveHighlight?] = Ref(None)
    let t = lg_case(dark~, fn(p) {
      p.box(fn(row) {
        row.row(Is(true)).gap(Is(20.0)).lines_up(Is(Some(Middle))) |> ignore
        @headless.button(row, fn() { "FloatBtn" }, fn(_) {  }, fn(b, btn) {
          b
          .width(Is(Some(44.0)))
          .height(Is(Some(44.0)))
          .radius(Is(22.0))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          |> ignore
          let ih = liquid_press_glass_decorate(b, tone=Floating, sharing=true)
          ih_ref.val = Some(ih)
          b.gesture(
            @ui.touch_slop(),
            press=fn(d) { ih.down(d.x, d.y, d.w, d.h) },
            tap=fn(_) {
              ih.up()
              btn.press()
            },
            drag=fn(d) {
              match d.kind {
                Down | Moved => ih.moved(d.x, d.y)
                Up | Off => ih.up()
              }
            },
          )
          |> ignore
          flight_icon(b, 18.0, fn() { colors().content })
        })
        |> ignore
        row.box(fn(shell) {
          shell
          .width(Is(Some(140.0)))
          .height(Is(Some(44.0)))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          |> ignore
          liquid_lift_shell_decorate(
            shell,
            fn() { lift.get() },
            flat_ground=Some(fn() { if is_dark() { 0x242428FFL } else { 0xFFFFFFE6L } }),
            radius=Some(14.0),
          )
          shell.box(fn(w) { w.words(Is("Lift Card"), look=words_at(14.0)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    assert_no_nested_glass(t, "press glass + lift shell rest")
    // At rest: only FloatBtn draws glass (lift == 0 -> 0 hidden glass on Lift Card)
    let rest_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    // Press FloatBtn -> GPU spot active & press settled near 1.0
    let (bx, by) = middle(t, Button, "FloatBtn")
    t.touch(0, bx, by)
    t.run_for(springs_out)
    let ih = ih_ref.val.unwrap()
    let press_active = (ih.pressed(ih.node.val.unwrap()) > 0.99, has_any_liquid_spot(t))
    t.touch(2, bx, by)
    t.run_for(springs_out)
    // Lift shell to 1.0 -> Lift Card draws glass
    lift.set(1.0)
    t.draw()
    let lifted_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    assert_no_nested_glass(t, "press glass + lift shell lifted")
    lift.set(0.0)
    t.draw()
    let settled_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    assert_eq(
      (dark, rest_glass, press_active, lifted_glass, settled_glass, t.audit()),
      (dark, 1, (true, true), 2, 1, []),
    )
  }
}

///|
test "Wave 21 C1: liquid_lens_overlay_node lazy mounts, draws lens on press, and releases with laid == 0 and 0 glass" {
  for dark in [false, true] {
    let lens_p = @signals.signal(0.0)
    let tree_ref : Ref[@view.Tree?] = Ref(None)
    let t = lg_case(dark~, fn(p) {
      tree_ref.val = Some(p.tree)
      p.box(fn(strip) {
        strip.width(Is(Some(240.0))).height(Is(Some(36.0))).radius(Is(18.0)).ground(By(fn() { colors().track })) |> ignore
        liquid_lens_overlay_node(
          strip,
          fn() { lens_p.get() },
          fn() { 30.0 },
          rect=fn() { Some((3.0, 3.0, 80.0, 30.0)) },
          grow=0.14,
        )
      })
      |> ignore
    })
    let tree = tree_ref.val.unwrap()
    let rest_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    assert_no_nested_glass(t, "lens overlay rest")
    lens_p.set(1.0)
    t.draw()
    let held_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    // Release: stays mounted so laid == 0, and emits 0 hidden glass
    let before_laid = tree.work().laid
    lens_p.set(0.0)
    t.draw()
    let relayout_delta = tree.work().laid - before_laid
    let released_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    assert_eq(
      (dark, rest_glass, held_glass, relayout_delta, released_glass, t.audit()),
      (dark, 0, 1, 0, 0, []),
    )
  }
}

///|
test "Wave 21 C1: liquid_loupe_node follows target, magnifies at zoom, and clears glass on release" {
  for dark in [false, true] {
    let active = @signals.signal(false)
    let target : @signals.Signal[(Double, Double)?] = @signals.signal(None)
    let t = lg_case(dark~, fn(p) {
      p.box(fn(w) { w.words(Is("Magnify target text"), look=words_at(16.0)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
      liquid_loupe_node(
        p,
        fn() { active.get() },
        fn() { target.get() },
      )
    })
    let rest_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    active.set(true)
    target.set(Some((200.0, 220.0)))
    t.run_for(held_ms)
    let active_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    assert_no_nested_glass(t, "loupe active")
    target.set(Some((340.0, 220.0)))
    t.run_for(a_frame)
    let moved_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    active.set(false)
    target.set(None)
    t.run_for(springs_out)
    let released_glass = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    assert_eq(
      (dark, rest_glass, active_glass, moved_glass, released_glass, t.audit()),
      (dark, 0, 1, 1, 0, []),
    )
  }
}
