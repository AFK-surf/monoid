// Apple iOS 26 `TabBarMinimizeBehavior` scroll-collapsing floating liquid glass bottom tab bar:
// - Expanded (`minimized = false`): full floating liquid glass tab capsule (`@headless.radio_group` with active pill
//   indicator) paired with a detached circular Search/Action liquid glass orb (`10pt` gap, `merge = 0.0`).
// - Minimized (`minimized = true`): the tab capsule smoothly collapses via closed-form `@motion.NodeWay` spring into a
//   compact `64 × 64` circular glass orb on the left showing only the active tab icon, while the right Action orb
//   remains independent and crisp. Tapping the collapsed orb calls `on_expand`.
//
// Strict two-layer architecture: preceding outside-only shadow layer -> glass shell siblings (zero children) ->
// foreground interactive content (`View::show`-gated so hidden controls never intercept clicks).

///|
let ctab_h : Double = 64.0

///|
let ctab_r : Double = 32.0

///|
let ctab_gap : Double = 10.0

///|
let ctab_pad : Double = 4.0

///|
/// Smoothstep helper for cross-fading expanded tabs and minimized compact orb.
fn ctab_smoothstep(lo : Double, hi : Double, x : Double) -> Double {
  if hi <= lo {
    return if x >= hi { 1.0 } else { 0.0 }
  }
  let u = clamp((x - lo) / (hi - lo), 0.0, 1.0)
  u * u * (3.0 - 2.0 * u)
}

///|
/// Accessible active tab ink (Apple HIG high-contrast systemBlue: > 5.0:1 on both Light and Dark glass/solid).
fn ctab_active_ink() -> Int64 {
  if is_dark() {
    0x40A9FFFFL
  } else {
    0x0066CCFFL
  }
}

///|
/// Default compact glyph for a tab when `compact_icons` is omitted: its uppercase first character.
fn ctab_initial(name : String) -> String {
  for ch in name {
    return ch.to_string()
  }
  "•"
}

///|
/// iOS 26 collapsible floating bottom tab bar + detached circular Search/Action glass orb.
#callsite(autofill(loc))
pub fn liquid_collapsible_tabs_node(
  parent : @view.View,
  tabs : Array[String],
  chosen : () -> Int,
  choose : (Int) -> Unit,
  minimized : () -> Bool,
  on_expand : () -> Unit,
  on_action : () -> Unit,
  action_label? : () -> String = fn() { "Search" },
  action_icon? : (@view.View, () -> Int64) -> Unit,
  faces? : Array[(@view.View, () -> Int64) -> Unit],
  compact_icons? : Array[(@view.View, () -> Int64) -> Unit],
  label? : String = "Navigation",
  expanded_width? : Double = 320.0,
  loc~ : SourceLoc,
) -> @view.View {
  let n = tabs.length()
  let bar_w = if expanded_width < ctab_h * 2.0 { ctab_h * 2.0 } else { expanded_width }
  let total_w = bar_w + ctab_gap + ctab_h
  let min_way = @motion.NodeWay::new(if @signals.untracked(minimized) { 1.0 } else { 0.0 })
  let action_press = @motion.NodeWay::new(0.0)
  let compact_press = @motion.NodeWay::new(0.0)
  parent.box(made_for=loc, fn(wrap) {
    wrap.reacts(at_start=false, minimized, fn(m) {
      min_way.go(wrap, if m { 1.0 } else { 0.0 }, @motion.snappy_damped)
    })
    wrap.width(Is(Some(total_w))).height(Is(Some(ctab_h))).shrink(Is(0.0)) |> ignore
    let capsule_shape = fn(node : @view.View) -> @view.GroundShape {
      let t = clamp(min_way.shown(node), 0.0, 1.0)
      let vw = lerp(bar_w, ctab_h, t)
      let dw = vw - bar_w
      if dw.abs() < 0.01 {
        @view.ground_as_laid
      } else {
        { dx: 0.0, dy: 0.0, dw, dh: 0.0, corners: Some((ctab_r, ctab_r, ctab_r, ctab_r)) }
      }
    }
    // 1. Preceding outside-only shadow layer (never paints dark shadow under glass interior)
    wrap.box(fn(shadows) {
      shadows.over(Is(true)).points(Is(false)) |> ignore
      shadows.box(fn(tab_sh) {
        tab_sh
        .over(Is(true))
        .width(Is(Some(bar_w)))
        .height(Is(Some(ctab_h)))
        .radius(Is(ctab_r))
        .shadow(Is(shadow_default))
        .shadow_outside(Is(true))
        .ground_drawn(By(fn() { capsule_shape(tab_sh) }))
        |> ignore
      })
      |> ignore
      shadows.box(fn(act_sh) {
        act_sh
        .over(Is(true))
        .width(Is(Some(ctab_h)))
        .height(Is(Some(ctab_h)))
        .offset(Is((bar_w + ctab_gap, 0.0)))
        .radius(Is(ctab_r))
        .shadow(Is(shadow_default))
        .shadow_outside(Is(true))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // 2. Strictly adjacent non-overlapping liquid glass shells (10pt resting gap, merge == 0.0)
    wrap.box(fn(tab_glass) {
      tab_glass
      .over(Is(true))
      .points(Is(false))
      .width(Is(Some(bar_w)))
      .height(Is(Some(ctab_h)))
      .radius(Is(ctab_r))
      .glass(By(fn() { Some(tabs_glass()) }))
      .ground_drawn(By(fn() { capsule_shape(tab_glass) }))
      |> ignore
    })
    |> ignore
    wrap.box(fn(act_glass) {
      act_glass
      .over(Is(true))
      .points(Is(false))
      .width(Is(Some(ctab_h)))
      .height(Is(Some(ctab_h)))
      .offset(Is((bar_w + ctab_gap, 0.0)))
      .radius(Is(ctab_r))
      .glass(By(fn() { Some(tabs_glass()) }))
      .scale(By(fn() { 1.0 - 0.05 * clamp(action_press.shown(act_glass), 0.0, 1.0) }))
      |> ignore
    })
    |> ignore
    // 3. Foreground interactive content layer (strictly zero glass-on-glass)
    wrap.box(fn(fg) {
      fg.over(Is(true)) |> ignore
      // 3A. Expanded full tab capsule (`@headless.radio_group`, `show`-gated so hidden tabs never catch clicks or stay in a11y)
      let tab_indices = Array::makei(n, fn(i) { i })
      fg.show(
        fn() { !minimized() },
        fn(exp_host) {
          exp_host
          .over(Is(true))
          .width(Is(Some(bar_w)))
          .height(Is(Some(ctab_h)))
          .padding(Is((ctab_pad, ctab_pad, ctab_pad, ctab_pad)))
          .points(By(fn() { !minimized() }))
          .alpha(By(fn() { 1.0 - ctab_smoothstep(0.0, 0.45, min_way.shown(exp_host)) }))
          |> ignore
          @headless.radio_group(
            exp_host,
            fn() { label },
            chosen,
            choose,
            kind=Tab,
            fn(g, rg) {
              g.row(Is(true)).grow(Is(1.0)).fills_across(Is(true)) |> ignore
              g.each_of(fn() { tab_indices }, at_once=true, fn(row_box, i) {
                row_box.grow(Is(1.0)).basis(Is(Some(0.0))).fills_across(Is(true)) |> ignore
                let name = tabs[i]
                let face = match faces {
                  Some(fs) if i < fs.length() => Some(fs[i])
                  _ => None
                }
                rg.item(row_box, fn() { i }, fn() { name }, fn(t, it) {
                  let pill_r = (ctab_h - ctab_pad * 2.0) / 2.0
                  t
                  .grow(Is(1.0))
                  .fills_across(Is(true))
                  .radius(Is(pill_r))
                  .lines_up(Is(Some(Middle)))
                  .lies_along(Is(Middle))
                  .ground(By(fn() { if it.chosen() { colors().lens_idle } else { clear } }))
                  |> ignore
                  ovl_attach_row_ground(
                    t,
                    fn() { !it.chosen() && (it.hovered() || it.focus_shown()) },
                    fn() { !it.chosen() && it.pressed() },
                  )
                  let ink = fn() {
                    if it.chosen() {
                      ctab_active_ink()
                    } else {
                      colors().content
                    }
                  }
                  match face {
                    Some(draw) => draw(t, ink)
                    None =>
                      t.box(fn(w) {
                        w.words(Is(name), look=words_at(type_tab, weight=weight_medium)).ink(By(ink)) |> ignore
                      })
                      |> ignore
                  }
                  t.show(fn() { it.focus_shown() }, fn(ring) {
                    ring
                    .over(Is(true))
                    .points(Is(false))
                    .radius(Is(pill_r))
                    .edge(By(fn() { (2.0, colors().accent) }))
                    |> ignore
                  })
                })
                |> ignore
              })
            },
          )
          |> ignore
        },
        leave=220.0,
      )
      // 3B. Minimized compact orb on the left (shows active tab icon; tap expands full bar)
      fg.show(
        fn() { minimized() },
        fn(min_host) {
          min_host
          .over(Is(true))
          .width(Is(Some(ctab_h)))
          .height(Is(Some(ctab_h)))
          .points(By(fn() { minimized() }))
          .alpha(By(fn() { ctab_smoothstep(0.45, 0.9, min_way.shown(min_host)) }))
          |> ignore
          @headless.button(
            min_host,
            fn() {
              let idx = clamp_int(chosen(), 0, if n > 0 { n - 1 } else { 0 })
              let active = if idx < n { tabs[idx] } else { label }
              "Expand \{active}"
            },
            fn(_) { on_expand() },
            fn(b, btn) {
              b.reacts(at_start=false, fn() { btn.pressed() }, fn(p) {
                compact_press.go(b, if p { 1.0 } else { 0.0 }, @motion.snappy_damped)
              })
              b
              .width(Is(Some(ctab_h)))
              .height(Is(Some(ctab_h)))
              .radius(Is(ctab_r))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              .scale(By(fn() { 1.0 - 0.06 * clamp(compact_press.shown(b), 0.0, 1.0) }))
              |> ignore
              let active_ink = fn() { ctab_active_ink() }
              b.pick(fn() { clamp_int(chosen(), 0, if n > 0 { n - 1 } else { 0 }) }, at_once=true, fn(slot, idx) {
                slot.lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
                match compact_icons {
                  Some(icons) if idx < icons.length() => icons[idx](slot, active_ink)
                  _ =>
                    slot.box(fn(w) {
                      let glyph = if idx < n { ctab_initial(tabs[idx]) } else { "•" }
                      w.words(Is(glyph), look=words_at(18.0, weight=weight_medium)).ink(By(active_ink)) |> ignore
                    })
                    |> ignore
                }
              })
              b.show(fn() { btn.focus_shown() }, fn(ring) {
                ring
                .over(Is(true))
                .points(Is(false))
                .radius(Is(ctab_r))
                .edge(By(fn() { (2.0, colors().accent) }))
                |> ignore
              })
            },
          )
          |> ignore
        },
        leave=220.0,
      )
      // 3C. Right detached circular Search / Action glass orb button
      fg.box(fn(act_host) {
        act_host
        .over(Is(true))
        .width(Is(Some(ctab_h)))
        .height(Is(Some(ctab_h)))
        .offset(Is((bar_w + ctab_gap, 0.0)))
        |> ignore
        @headless.button(
          act_host,
          action_label,
          fn(_) { on_action() },
          fn(b, btn) {
            b.reacts(at_start=false, fn() { btn.pressed() }, fn(p) {
              action_press.go(b, if p { 1.0 } else { 0.0 }, @motion.snappy_damped)
            })
            b
            .width(Is(Some(ctab_h)))
            .height(Is(Some(ctab_h)))
            .radius(Is(ctab_r))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .scale(By(fn() { 1.0 - 0.05 * clamp(action_press.shown(b), 0.0, 1.0) }))
            |> ignore
            let ink = fn() { colors().content }
            match action_icon {
              Some(draw) => draw(b, ink)
              None =>
                b.box(fn(ic) {
                  ic
                  .width(Is(Some(20.0)))
                  .height(Is(Some(20.0)))
                  .shrink(Is(0.0))
                  .shapes(By(fn() { ctrl_search_shapes(20.0, ink()) }))
                  |> ignore
                })
                |> ignore
            }
            b.show(fn() { btn.focus_shown() }, fn(ring) {
              ring
              .over(Is(true))
              .points(Is(false))
              .radius(Is(ctab_r))
              .edge(By(fn() { (2.0, colors().accent) }))
              |> ignore
            })
          },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}

///|
fn clamp_int(v : Int, lo : Int, hi : Int) -> Int {
  if v < lo { lo } else if v > hi { hi } else { v }
}
