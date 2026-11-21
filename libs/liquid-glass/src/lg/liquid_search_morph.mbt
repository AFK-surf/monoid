// Apple iOS 26 liquid glass Search Orb <-> Expanded Search Bar + Capillary-Budded Circular `×` Cancel Orb:
// - Collapsed (`expanded = false`): single `48 × 48` circular search liquid glass orb (`merge == 0.0`, zero hidden
//   second glass instance).
// - Expanding (`expanded = true`): the orb stretches smoothly into a full-width liquid glass search capsule while a
//   circular `×` cancel orb buds out of its right edge through a GPU `smin` capillary liquid bridge (`@motion.LiquidBond`),
//   snapping cleanly to `merge == 0.0` once past the capillary pinch-off threshold (`10pt` resting gap, zero attraction).
// - Collapsing (`expanded = false`): the cancel orb glides leftward with strictly `merge == 0.0` across the air gap,
//   blooming a capillary liquid bridge at the exact instant outer contours touch (`visual_gap <= 0.0`) and absorbing
//   seamlessly back into the single `48 × 48` search orb.
//
// Strict two-layer architecture: outside-only shadow siblings -> strictly adjacent glass siblings (bit-identical
// optical recipe for GPU `sd_group` smooth-min fusion) -> foreground interactive controls (`View::show`-gated).

///|
let smorph_h : Double = 48.0

///|
let smorph_r : Double = 24.0

///|
let smorph_gap : Double = 10.0

///|
let smorph_merge_max : Double = 28.0

///|
let smorph_break_gap : Double = 7.5

///|
/// Visual surface gap between the stretching search bar's right edge and the budding cancel orb's left edge at
/// progress `p` in `0..1` (0.0 == exact outer-contour tangency accounting for `merge_contact_gap = 1.5pt`).
fn smorph_visual_gap(p : Double) -> Double {
  let u = clamp(p, 0.0, 1.0)
  let raw_gap = lerp(-smorph_h * 0.55, smorph_gap, u)
  raw_gap - merge_contact_gap
}

///|
/// iOS 26 morphing liquid glass Search Orb <-> Expanded Search Bar + capillary-budded circular Cancel Orb.
#callsite(autofill(loc))
pub fn liquid_search_morph_node(
  parent : @view.View,
  field : @ui.Field,
  expanded : () -> Bool,
  set_expanded : (Bool) -> Unit,
  width? : Double = 360.0,
  placeholder? : String = "Search",
  label? : () -> String = fn() { "Search" },
  cancel_label? : () -> String = fn() { "Cancel Search" },
  submitted? : (String) -> Unit,
  edited? : (String) -> Unit,
  on_clear? : () -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let total_w = if width < smorph_h * 3.0 { smorph_h * 3.0 } else { width }
  let bar_w = total_w - smorph_h - smorph_gap
  let init_exp = @signals.untracked(expanded)
  let morph_way = @motion.Way::new(if init_exp { 1.0 } else { 0.0 })
  let bond = @motion.LiquidBond::new(
    merged=!init_exp,
    merge_max=smorph_merge_max,
    break_gap=smorph_break_gap,
    contact_gap=0.0,
    merge_spec=@motion.tween(40.0, ease=Out),
  )
  let scheduled : Ref[(() -> Unit)?] = Ref(None)
  let cancel_sched = fn() {
    match scheduled.val {
      Some(stop) => {
        scheduled.val = None
        stop()
      }
      None => ()
    }
  }
  let tf = @headless.TextField::new(label)
  let orb_press = @motion.NodeWay::new(0.0)
  let cancel_press = @motion.NodeWay::new(0.0)
  let cancel_x_at = fn(t : Double) -> Double {
    let p = clamp(morph_way.value_at(t), 0.0, 1.0)
    let cur_w = lerp(smorph_h, bar_w, p)
    let raw_gap = lerp(-smorph_h * 0.55, smorph_gap, p)
    cur_w + raw_gap
  }
  let cancel_move = fn(_ : Double, _ : Double, t : Double) {
    morph_way.said()
    (cancel_x_at(t), 0.0)
  }
  let cancel_end = fn(_ : Double, _ : Double) {
    morph_way.said()
    let me = morph_way.end()
    let be = bond.end()
    if me > be { me } else { be }
  }
  parent.box(made_for=loc, fn(stage) {
    stage.reacts(at_start=false, expanded, fn(exp) {
      cancel_sched()
      let at = stage.cause_at()
      let target = if exp { 1.0 } else { 0.0 }
      morph_way.go(target, @motion.liquid_toggle_spring, at~)
      let threshold = if exp { bond.break_gap() } else { bond.contact_gap() }
      let t_end = morph_way.end()
      let cross = @motion.liquid_bond_cross_time(
        at,
        if t_end > at { t_end } else { at },
        fn(t) { smorph_visual_gap(morph_way.value_at(t)) },
        exp,
        threshold,
      )
      match cross {
        Some(tc) =>
          if tc <= at {
            bond.update(threshold, at=tc) |> ignore
          } else {
            let stop = stage.at_moment(tc, fn() {
              scheduled.val = None
              bond.update(threshold, at=tc) |> ignore
            })
            scheduled.val = Some(stop)
          }
        None => ()
      }
    })
    stage.width(Is(Some(total_w))).height(Is(Some(smorph_h))).shrink(Is(0.0)) |> ignore
    let bar_shape = fn(node : @view.View) -> @view.GroundShape {
      let p = clamp(morph_way.shown_on(node), 0.0, 1.0)
      let vw = lerp(smorph_h, bar_w, p)
      let dw = vw - bar_w
      if dw.abs() < 0.01 {
        @view.ground_as_laid
      } else {
        { dx: 0.0, dy: 0.0, dw, dh: 0.0, corners: Some((smorph_r, smorph_r, smorph_r, smorph_r)) }
      }
    }
    // 1. Preceding outside-only shadow layer
    stage.box(fn(shadows) {
      shadows.over(Is(true)).points(Is(false)) |> ignore
      shadows.box(fn(bs) {
        bs
        .over(Is(true))
        .width(Is(Some(bar_w)))
        .height(Is(Some(smorph_h)))
        .radius(Is(smorph_r))
        .shadow(Is(shadow_default))
        .shadow_outside(Is(true))
        .ground_drawn(By(fn() { bar_shape(bs) }))
        |> ignore
      })
      |> ignore
      shadows.box(fn(cs) {
        cs
        .over(Is(true))
        .width(Is(Some(smorph_h)))
        .height(Is(Some(smorph_h)))
        .radius(Is(smorph_r))
        .shadow(Is(shadow_default))
        .shadow_outside(Is(true))
        .alpha(By(fn() {
          let p = clamp(morph_way.shown_on(cs), 0.0, 1.0)
          merge_smoothstep(0.0, smorph_break_gap, smorph_visual_gap(p))
        }))
        |> ignore
        cs.moved_by(cancel_move, cancel_end) |> ignore
      })
      |> ignore
    })
    |> ignore
    // 2. Strictly adjacent liquid glass siblings (zero children, bit-identical recipe for GPU `smin` bridge)
    stage.box(fn(bg) {
      bg
      .over(Is(true))
      .points(Is(false))
      .width(Is(Some(bar_w)))
      .height(Is(Some(smorph_h)))
      .radius(Is(smorph_r))
      .glass(By(fn() {
        let p = clamp(morph_way.shown_on(bg), 0.0, 1.0)
        let m = if p <= 0.02 { 0.0 } else { bond.merge_on(bg) }
        Some(merge_glass(m))
      }))
      .ground_drawn(By(fn() { bar_shape(bg) }))
      |> ignore
    })
    |> ignore
    stage.box(fn(cg) {
      cg
      .over(Is(true))
      .points(Is(false))
      .width(Is(Some(smorph_h)))
      .height(Is(Some(smorph_h)))
      .radius(Is(smorph_r))
      .glass(By(fn() {
        let p = clamp(morph_way.shown_on(cg), 0.0, 1.0)
        if p <= 0.02 {
          None
        } else {
          let m = bond.merge_on(cg)
          if m > 0.0 {
            Some(merge_glass(m))
          } else {
            Some(merge_glass(0.0).sharing())
          }
        }
      }))
      |> ignore
      cg.moved_by(cancel_move, cancel_end) |> ignore
    })
    |> ignore
    // 3. Foreground interactive controls (drawn after both glass boxes, zero glass-on-glass)
    stage.box(fn(fg) {
      fg.over(Is(true)) |> ignore
      // 3.0 Persistent magnifying glass glyph anchored at (24, 24): stays continuously visible across
      // collapsed orb, expanding bar, and collapsing bar (zero blank-bar mid-frames).
      fg.box(fn(lead_ic) {
        lead_ic
        .over(Is(true))
        .points(Is(false))
        .width(Is(Some(smorph_h)))
        .height(Is(Some(smorph_h)))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .scale(By(fn() {
          let p = clamp(morph_way.shown_on(lead_ic), 0.0, 1.0)
          lerp(1.0, 16.0 / 18.0, p) * (1.0 - 0.06 * clamp(orb_press.shown(lead_ic), 0.0, 1.0))
        }))
        |> ignore
        lead_ic.box(fn(ic) {
          ic
          .width(Is(Some(18.0)))
          .height(Is(Some(18.0)))
          .shrink(Is(0.0))
          .shapes(By(fn() {
            let p = clamp(morph_way.shown_on(ic), 0.0, 1.0)
            ctrl_search_shapes(18.0, lerp_color(colors().content, ovl_muted_ink(), p))
          }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // 3A. Collapsed `48 × 48` search orb button (interactive hit target + focus ring)
      fg.show(
        fn() { !expanded() },
        fn(col_host) {
          col_host
          .over(Is(true))
          .width(Is(Some(smorph_h)))
          .height(Is(Some(smorph_h)))
          .points(By(fn() { !expanded() }))
          .alpha(By(fn() { 1.0 - ctab_smoothstep(0.0, 0.35, morph_way.shown_on(col_host)) }))
          |> ignore
          @headless.button(
            col_host,
            label,
            fn(_) {
              set_expanded(true)
              field.focus()
            },
            fn(b, btn) {
              b.reacts(at_start=false, fn() { btn.pressed() }, fn(p) {
                orb_press.go(b, if p { 1.0 } else { 0.0 }, @motion.snappy_damped)
              })
              b
              .width(Is(Some(smorph_h)))
              .height(Is(Some(smorph_h)))
              .radius(Is(smorph_r))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              |> ignore
              b.show(fn() { btn.focus_shown() }, fn(ring) {
                ring
                .over(Is(true))
                .points(Is(false))
                .radius(Is(smorph_r))
                .edge(By(fn() { (2.0, colors().accent) }))
                |> ignore
              })
            },
          )
          |> ignore
        },
        leave=220.0,
      )
      // 3B. Expanded full-width search bar input + detached circular `×` cancel orb
      fg.show(
        fn() { expanded() },
        fn(exp_host) {
          exp_host
          .over(Is(true))
          .points(By(fn() { expanded() }))
          |> ignore
          exp_host.box(fn(bar_fg) {
            bar_fg
            .over(Is(true))
            .row(Is(true))
            .width(Is(Some(bar_w)))
            .height(Is(Some(smorph_h)))
            .padding(Is((42.0, 0.0, 12.0, 0.0)))
            .gap(Is(8.0))
            .lines_up(Is(Some(Middle)))
            .alpha(By(fn() { ctab_smoothstep(0.30, 0.78, morph_way.shown_on(bar_fg)) }))
            |> ignore
            let typed = @ui.field(
              bar_fg,
              field,
              placeholder~,
              font_size=type_body,
              max_lines=1,
              enter_sends=true,
              label=@signals.untracked(label),
              submitted?,
              edited?,
              colors_by=fn() { (colors().content, ovl_muted_ink(), colors().accent) },
            )
            typed.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).presses(Is(true)).focusable(Is(true), keys=0)
            |> ignore
            tf.control_node(typed)
            bar_fg.show(
              fn() { field.text() != "" },
              fn(cl) { ctrl_clear_button(loc~, cl, field, on_clear) },
              at_once=true,
            )
          })
          |> ignore
          exp_host.box(fn(cancel_host) {
            cancel_host
            .over(Is(true))
            .width(Is(Some(smorph_h)))
            .height(Is(Some(smorph_h)))
            .alpha(By(fn() { ctab_smoothstep(0.35, 0.85, morph_way.shown_on(cancel_host)) }))
            |> ignore
            cancel_host.moved_by(cancel_move, cancel_end) |> ignore
            @headless.button(
              cancel_host,
              cancel_label,
              fn(_) {
                field.set("")
                set_expanded(false)
              },
              fn(b, btn) {
                b.reacts(at_start=false, fn() { btn.pressed() }, fn(p) {
                  cancel_press.go(b, if p { 1.0 } else { 0.0 }, @motion.snappy_damped)
                })
                b
                .width(Is(Some(smorph_h)))
                .height(Is(Some(smorph_h)))
                .radius(Is(smorph_r))
                .lines_up(Is(Some(Middle)))
                .lies_along(Is(Middle))
                .scale(By(fn() { 1.0 - 0.06 * clamp(cancel_press.shown(b), 0.0, 1.0) }))
                |> ignore
                b.box(fn(ic) {
                  ic
                  .width(Is(Some(14.0)))
                  .height(Is(Some(14.0)))
                  .shrink(Is(0.0))
                  .shapes(By(fn() { ctrl_close_shapes(14.0, colors().content) }))
                  |> ignore
                })
                |> ignore
                b.show(fn() { btn.focus_shown() }, fn(ring) {
                  ring
                  .over(Is(true))
                  .points(Is(false))
                  .radius(Is(smorph_r))
                  .edge(By(fn() { (2.0, colors().accent) }))
                  |> ignore
                })
              },
            )
            |> ignore
          })
          |> ignore
        },
        leave=220.0,
      )
    })
    |> ignore
  })
}
