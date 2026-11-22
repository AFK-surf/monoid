// Selection and metadata controls in Liquid Glass: checkbox, radio group, stepper,
// filter/selection chip, semantic badge, and numeric count badge.

///|
/// Semantic tone for `liquid_badge_node` and `liquid_count_badge_node`.
#derive(Eq, Debug)
pub(all) enum LiquidTone {
  Neutral
  Accent
  Success
  Warning
  Danger
}

///|
/// A Liquid Glass checkbox (22×22pt, r=7pt) over `@headless.toggle(..., Checkbox, ...)`,
/// rendering a vector checkmark when checked and a dash when mixed, with first-line label alignment.
#callsite(autofill(loc))
pub fn liquid_checkbox_node(
  parent : @view.View,
  checked : () -> Bool,
  on_change : (Bool) -> Unit,
  label : () -> String,
  mixed? : () -> Bool = fn() { false },
  disabled? : () -> Bool = fn() { false },
  tint? : Int64 = clear,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.toggle(made_for=loc, parent, Checkbox, label, checked, on_change, disabled~, mixed~, fn(row, cb) {
    let hover_way = @motion.NodeWay::new(0.0)
    let press_way = @motion.NodeWay::new(0.0)
    let check_way = @motion.NodeWay::new(if @signals.untracked(checked) || @signals.untracked(mixed) { 1.0 } else { 0.0 })
    row.reacts(at_start=false, fn() { !cb.disabled() && (cb.hovered() || cb.pressed()) }, fn(on) {
      hover_way.go(row, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
    })
    row.reacts(at_start=false, fn() { !cb.disabled() && cb.pressed() }, fn(on) {
      press_way.go(row, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
    })
    row.reacts(at_start=false, fn() { cb.on() || cb.mixed() }, fn(on) {
      check_way.go(row, if on { 1.0 } else { 0.0 }, @motion.tactile_bounce)
    })
    row
    .row(Is(true))
    .lines_up(Is(Some(Start)))
    .gap(Is(ctrl_check_gap))
    .alpha(By(fn() { if cb.disabled() { ctrl_disabled_alpha } else { 1.0 } }))
    |> ignore
    row.box(fn(box) {
      let filled = fn() { cb.on() || cb.mixed() }
      box
      .width(Is(Some(ctrl_check_size)))
      .height(Is(Some(ctrl_check_size)))
      .shrink(Is(0.0))
      .radius(Is(ctrl_check_radius))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .ground(By(fn() { ctrl_check_bg(filled(), tint) }))
      .edge(By(fn() {
        if filled() {
          (0.0, clear)
        } else {
          (ctrl_hairline_w, ctrl_check_border_ink())
        }
      }))
      .scale(By(fn() { 1.0 - 0.10 * clamp(press_way.shown(box), 0.0, 1.0) }))
      |> ignore
      box.box(fn(hov) {
        hov
        .over(Is(true))
        .points(Is(false))
        .radius(Is(ctrl_check_radius))
        .ground(By(ctrl_hover_ink))
        .alpha(By(fn() { clamp(hover_way.shown(hov), 0.0, 1.0) * ctrl_hover_alpha }))
        |> ignore
      })
      |> ignore
      box.show(
        fn() { cb.on() && !cb.mixed() },
        fn(ic) {
          ic
          .width(Is(Some(ctrl_check_size)))
          .height(Is(Some(ctrl_check_size)))
          .scale(By(fn() { lerp(0.4, 1.0, check_way.shown(ic)) }))
          .alpha(By(fn() { clamp(check_way.shown(ic), 0.0, 1.0) }))
          .shapes(Is(ctrl_check_shapes(ctrl_check_size, white)))
          |> ignore
        },
        at_once=true,
      )
      box.show(
        fn() { cb.mixed() },
        fn(ic) {
          ic
          .width(Is(Some(ctrl_check_size)))
          .height(Is(Some(ctrl_check_size)))
          .scale(By(fn() { lerp(0.4, 1.0, check_way.shown(ic)) }))
          .alpha(By(fn() { clamp(check_way.shown(ic), 0.0, 1.0) }))
          .shapes(Is(ctrl_minus_shapes(ctrl_check_size, white)))
          |> ignore
        },
        at_once=true,
      )
      box.show(fn() { cb.focus_shown() }, fn(ring) {
        ring
        .over(Is(true))
        .points(Is(false))
        .margin(Is((-ctrl_focus_outset, -ctrl_focus_outset, -ctrl_focus_outset, -ctrl_focus_outset)))
        .radius(Is(ctrl_check_radius + ctrl_focus_outset))
        .edge(By(fn() { (ctrl_focus_w, colors().accent) }))
        |> ignore
      })
    })
    |> ignore
    row.box(fn(w) {
      w.words(By(label), look=words_at(ctrl_type_body, wrap=true)).ink(By(fn() { colors().content })) |> ignore
    })
    |> ignore
  })
}

///|
/// A Liquid Glass radio group over `@headless.radio_group(..., Radio, ...)`, with 22×22pt
/// circular glass indicators and inner selection dots.
#callsite(autofill(loc))
pub fn liquid_radio_group_node(
  parent : @view.View,
  labels : () -> Array[String],
  selected : () -> Int,
  on_select : (Int) -> Unit,
  horizontal? : Bool = false,
  disabled? : () -> Bool = fn() { false },
  tint? : Int64 = clear,
  loc~ : SourceLoc,
) -> @view.View {
  let r = ctrl_radio_size / 2.0
  @headless.radio_group(
    made_for=loc,
    parent,
    fn() { "Radio Group" },
    selected,
    on_select,
    kind=Radio,
    axis=if horizontal { Horizontal } else { Vertical },
    disabled~,
    fn(g, rg) {
      g
      .row(Is(horizontal))
      .gap(Is(if horizontal { ctrl_radio_row_gap } else { ctrl_radio_col_gap }))
      .lines_up(Is(Some(Start)))
      |> ignore
      g.each(
        fn() {
          let ls = labels()
          let out : Array[(Int, String)] = []
          for i, s in ls {
            out.push((i, s))
          }
          out
        },
        fn(p) { p.0 },
        fn(slot, item_sig) {
          rg.item(
            made_for=loc,
            slot,
            fn() { item_sig.get().0 },
            fn() { item_sig.get().1 },
            in_node=true,
            fn(row, it) {
              let hover_way = @motion.NodeWay::new(0.0)
              let press_way = @motion.NodeWay::new(0.0)
              let dot_way = @motion.NodeWay::new(if @signals.untracked(fn() { it.chosen() }) { 1.0 } else { 0.0 })
              row.reacts(at_start=false, fn() { !it.disabled() && (it.hovered() || it.pressed()) }, fn(on) {
                hover_way.go(row, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
              })
              row.reacts(at_start=false, fn() { !it.disabled() && it.pressed() }, fn(on) {
                press_way.go(row, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
              })
              row.reacts(at_start=false, fn() { it.chosen() }, fn(on) {
                dot_way.go(row, if on { 1.0 } else { 0.0 }, @motion.tactile_bounce)
              })
              row
              .row(Is(true))
              .lines_up(Is(Some(Start)))
              .gap(Is(ctrl_check_gap))
              .alpha(By(fn() { if it.disabled() { ctrl_disabled_alpha } else { 1.0 } }))
              |> ignore
              row.box(fn(circle) {
                circle
                .width(Is(Some(ctrl_radio_size)))
                .height(Is(Some(ctrl_radio_size)))
                .shrink(Is(0.0))
                .radius(Is(r))
                .lines_up(Is(Some(Middle)))
                .lies_along(Is(Middle))
                .ground(By(fn() { ctrl_check_bg(it.chosen(), tint) }))
                .edge(By(fn() {
                  if it.chosen() {
                    (0.0, clear)
                  } else {
                    (ctrl_hairline_w, ctrl_check_border_ink())
                  }
                }))
                .scale(By(fn() { 1.0 - 0.08 * clamp(press_way.shown(circle), 0.0, 1.0) }))
                |> ignore
                circle.box(fn(hov) {
                  hov
                  .over(Is(true))
                  .points(Is(false))
                  .radius(Is(r))
                  .ground(By(ctrl_hover_ink))
                  .alpha(By(fn() { clamp(hover_way.shown(hov), 0.0, 1.0) * ctrl_hover_alpha }))
                  |> ignore
                })
                |> ignore
                circle.show(
                  fn() { it.chosen() },
                  fn(dot) {
                    dot
                    .width(Is(Some(ctrl_radio_dot)))
                    .height(Is(Some(ctrl_radio_dot)))
                    .shrink(Is(0.0))
                    .radius(Is(ctrl_radio_dot / 2.0))
                    .ground(Is(white))
                    .scale(By(fn() { dot_way.shown(dot).max(0.0) }))
                    .alpha(By(fn() { clamp(dot_way.shown(dot), 0.0, 1.0) }))
                    |> ignore
                  },
                  at_once=true,
                )
                circle.show(fn() { it.focus_shown() }, fn(ring) {
                  ring
                  .over(Is(true))
                  .points(Is(false))
                  .margin(Is((-ctrl_focus_outset, -ctrl_focus_outset, -ctrl_focus_outset, -ctrl_focus_outset)))
                  .radius(Is(r + ctrl_focus_outset))
                  .edge(By(fn() { (ctrl_focus_w, colors().accent) }))
                  |> ignore
                })
              })
              |> ignore
              row.box(fn(w) {
                w
                .words(By(fn() { item_sig.get().1 }), look=words_at(ctrl_type_body, wrap=true))
                .ink(By(fn() { colors().content }))
                |> ignore
              })
              |> ignore
            },
          )
          |> ignore
        },
        at_once=true,
      )
    },
  )
}

///|
/// A classic `- | +` Liquid Glass stepper capsule with automatic boundary disabling,
/// hairline center divider, and optional tabular numeric readout.
#callsite(autofill(loc))
pub fn liquid_stepper_node(
  parent : @view.View,
  value : () -> Int,
  on_change : (Int) -> Unit,
  min? : Int = 0,
  max? : Int = 100,
  step? : Int = 1,
  label? : () -> String = fn() { "Stepper" },
  show_value? : Bool = true,
  format? : (Int) -> String,
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  let h = ctrl_stepper_h
  let r_outer = h / 2.0
  let inner_h = h - 2.0 * ctrl_group_pad
  let r_inner = inner_h / 2.0
  let div_h = h * ctrl_divider_ratio
  let step_amt = if step > 0 { step } else { 1 }
  parent.box(made_for=loc, fn(root) {
    root
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .gap(Is(ctrl_stepper_gap))
    .says(By(fn() { Some(@view.said(Group, label=label())) }))
    |> ignore
    if show_value {
      root.box(fn(v) {
        let pulse_way = @motion.NodeWay::new(0.0)
        v.reacts(at_start=false, value, fn(_) {
          pulse_way.put(1.0)
          pulse_way.go(v, 0.0, @motion.snappy_damped)
        })
        v
        .min_width(Is(Some(ctrl_stepper_val_min_w)))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .scale(By(fn() { 1.0 + 0.10 * clamp(pulse_way.shown(v), 0.0, 1.0) }))
        .words(
          By(fn() {
            let cur = value()
            match format {
              Some(f) => f(cur)
              None => "\{cur}"
            }
          }),
          look=words_at(ctrl_type_body, weight=weight_medium),
        )
        .words_centered(Is(true))
        .ink(By(fn() { colors().content }))
        |> ignore
      })
      |> ignore
    }
    root.box(fn(cap) {
      cap
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .height(Is(Some(h)))
      .shrink(Is(0.0))
      .padding(Is((ctrl_group_pad, ctrl_group_pad, ctrl_group_pad, ctrl_group_pad)))
      .radius(Is(r_outer))
      .shadow(Is(shadow_default))
      .shadow_outside(Is(true))
      .glass(By(fn() { Some(ctrl_surface_glass(clear, clear)) }))
      .alpha(By(fn() { if disabled() { ctrl_disabled_alpha } else { 1.0 } }))
      |> ignore
      let dec_disabled = fn() { disabled() || value() <= min }
      let inc_disabled = fn() { disabled() || value() >= max }
      let make_btn = fn(
        btn_label : () -> String,
        btn_disabled : () -> Bool,
        on_tap : () -> Unit,
        is_plus : Bool,
      ) {
        @headless.button(made_for=loc, cap, btn_label, fn(_) { on_tap() }, disabled=btn_disabled, fn(b, btn) {
          let hover_way = @motion.NodeWay::new(0.0)
          let press_way = @motion.NodeWay::new(0.0)
          b.reacts(
            at_start=false,
            fn() {
              if btn.disabled() {
                0.0
              } else if btn.pressed() {
                1.0
              } else if btn.hovered() {
                0.5
              } else {
                0.0
              }
            },
            fn(to) { hover_way.go(b, to, @motion.snappy_damped) },
          )
          b.reacts(at_start=false, fn() { !btn.disabled() && btn.pressed() }, fn(on) {
            press_way.go(b, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
          })
          b
          .width(Is(Some(ctrl_stepper_btn_w)))
          .height(Is(Some(inner_h)))
          .shrink(Is(0.0))
          .radius(Is(r_inner))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          .scale(By(fn() { 1.0 - 0.08 * clamp(press_way.shown(b), 0.0, 1.0) }))
          .alpha(By(fn() { if btn.disabled() { ctrl_disabled_alpha } else { 1.0 } }))
          |> ignore
          b.box(fn(hov) {
            hov
            .over(Is(true))
            .points(Is(false))
            .radius(Is(r_inner))
            .ground(By(ctrl_hover_ink))
            .alpha(By(fn() { clamp(hover_way.shown(hov), 0.0, 1.0) * ctrl_press_glow_alpha }))
            |> ignore
          })
          |> ignore
          b.box(fn(ic) {
            ic
            .width(Is(Some(ctrl_stepper_icon_size)))
            .height(Is(Some(ctrl_stepper_icon_size)))
            .shrink(Is(0.0))
            .shapes(By(fn() {
              if is_plus {
                ctrl_plus_shapes(ctrl_stepper_icon_size, colors().content)
              } else {
                ctrl_minus_shapes(ctrl_stepper_icon_size, colors().content)
              }
            }))
            |> ignore
          })
          |> ignore
          b.show(fn() { btn.focus_shown() }, fn(ring) {
            ring
            .over(Is(true))
            .points(Is(false))
            .radius(Is(r_inner))
            .edge(By(fn() { (ctrl_focus_w, colors().accent) }))
            |> ignore
          })
        })
        |> ignore
      }
      make_btn(
        fn() { "Decrease " + label() },
        dec_disabled,
        fn() {
          let next = value() - step_amt
          on_change(if next < min { min } else { next })
        },
        false,
      )
      cap.box(fn(div) {
        div
        .width(Is(Some(ctrl_hairline_w)))
        .height(Is(Some(div_h)))
        .shrink(Is(0.0))
        .margin(Is((ctrl_group_item_gap, 0.0, ctrl_group_item_gap, 0.0)))
        .ground(By(ctrl_divider_ink))
        |> ignore
      })
      |> ignore
      make_btn(
        fn() { "Increase " + label() },
        inc_disabled,
        fn() {
          let next = value() + step_amt
          on_change(if next > max { max } else { next })
        },
        true,
      )
    })
    |> ignore
  })
}

///|
/// A 32pt floating Liquid Glass filter/selection chip (`r = 16pt`).
/// Uses `@headless.toggle(..., Button, ...)` when `toggleable` is true, or `@headless.button`
/// otherwise, with optional leading icon slot and concentric trailing `×` remove button.
#callsite(autofill(loc))
pub fn liquid_chip_node(
  parent : @view.View,
  label : () -> String,
  on_press : () -> Unit,
  selected? : () -> Bool = fn() { false },
  toggleable? : Bool = true,
  lead? : (@view.View, () -> Int64) -> Unit,
  on_remove? : () -> Unit,
  remove_label? : () -> String = fn() { "Remove" },
  tint? : Int64 = clear,
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  let eff_tint = fn() {
    if selected() {
      if tint != clear {
        tint
      } else {
        ctrl_chip_selected_tint()
      }
    } else {
      clear
    }
  }
  let fg_ink = fn() { if selected() { white } else { colors().content } }
  let draw_body = fn(c : @view.View) {
    match lead {
      Some(draw_lead) =>
        c.box(fn(l) {
          l.shrink(Is(0.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
          draw_lead(l, fg_ink)
        })
        |> ignore
      None => ()
    }
    c.box(fn(w) {
      w.words(By(label), look=words_at(ctrl_type_chip, weight=weight_medium)).ink(By(fg_ink)) |> ignore
    })
    |> ignore
  }
  match on_remove {
    None => {
      let build_chip = fn(c : @view.View, is_disabled : () -> Bool, is_hovered : () -> Bool, is_pressed : () -> Bool, is_focus : () -> Bool) {
        let hover_way = @motion.NodeWay::new(0.0)
        let press_way = @motion.NodeWay::new(0.0)
        let sel_way = @motion.NodeWay::new(if @signals.untracked(selected) { 1.0 } else { 0.0 })
        c.reacts(
          at_start=false,
          fn() {
            if is_disabled() {
              0.0
            } else if is_pressed() {
              1.0
            } else if is_hovered() {
              0.5
            } else {
              0.0
            }
          },
          fn(to) { hover_way.go(c, to, @motion.snappy_damped) },
        )
        c.reacts(at_start=false, fn() { !is_disabled() && is_pressed() }, fn(on) {
          press_way.go(c, if on { 1.0 } else { 0.0 }, @motion.tactile_bounce)
        })
        c.reacts(at_start=false, selected, fn(on) {
          sel_way.go(c, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
        })
        c
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .height(Is(Some(ctrl_chip_h)))
        .shrink(Is(0.0))
        .padding(Is((ctrl_chip_px, 0.0, ctrl_chip_px, 0.0)))
        .gap(Is(ctrl_chip_gap))
        .radius(Is(ctrl_chip_r))
        .shadow(Is(shadow_thumb))
        .shadow_outside(Is(true))
        .glass(By(fn() { Some(ctrl_surface_glass(eff_tint(), clear, bezel=14.0, refraction=16.0)) }))
        .scale(By(fn() {
          let p = clamp(press_way.shown(c), 0.0, 1.0)
          let s = clamp(sel_way.shown(c), 0.0, 1.0)
          (1.0 - 0.05 * p) * (1.0 + 0.02 * s * (1.0 - s))
        }))
        .alpha(By(fn() { if is_disabled() { ctrl_disabled_alpha } else { 1.0 } }))
        |> ignore
        c.box(fn(hov) {
          hov
          .over(Is(true))
          .points(Is(false))
          .radius(Is(ctrl_chip_r))
          .ground(By(ctrl_hover_ink))
          .alpha(By(fn() { clamp(hover_way.shown(hov), 0.0, 1.0) * ctrl_press_glow_alpha }))
          |> ignore
        })
        |> ignore
        draw_body(c)
        c.show(is_focus, fn(ring) {
          ring
          .over(Is(true))
          .points(Is(false))
          .margin(Is((-ctrl_focus_outset, -ctrl_focus_outset, -ctrl_focus_outset, -ctrl_focus_outset)))
          .radius(Is(ctrl_chip_r + ctrl_focus_outset))
          .edge(By(fn() { (ctrl_focus_w, colors().accent) }))
          |> ignore
        })
      }
      if toggleable {
        @headless.toggle(made_for=loc, parent, Button, label, selected, fn(_) { on_press() }, disabled~, fn(c, tg) {
          build_chip(c, fn() { tg.disabled() }, fn() { tg.hovered() }, fn() { tg.pressed() }, fn() { tg.focus_shown() })
        })
      } else {
        @headless.button(made_for=loc, parent, label, fn(_) { on_press() }, disabled~, fn(c, btn) {
          build_chip(c, fn() { btn.disabled() }, fn() { btn.hovered() }, fn() { btn.pressed() }, fn() { btn.focus_shown() })
        })
      }
    }
    Some(rm) => {
      let inner_r = ctrl_chip_r - ctrl_chip_pad_rm
      parent.box(made_for=loc, fn(cap) {
        cap
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        .height(Is(Some(ctrl_chip_h)))
        .shrink(Is(0.0))
        .padding(Is((ctrl_chip_pad_rm, ctrl_chip_pad_rm, ctrl_chip_pad_rm, ctrl_chip_pad_rm)))
        .gap(Is(ctrl_group_item_gap))
        .radius(Is(ctrl_chip_r))
        .shadow(Is(shadow_thumb))
        .shadow_outside(Is(true))
        .glass(By(fn() { Some(ctrl_surface_glass(eff_tint(), clear, bezel=14.0, refraction=16.0)) }))
        .alpha(By(fn() { if disabled() { ctrl_disabled_alpha } else { 1.0 } }))
        |> ignore
        let build_main = fn(m : @view.View, is_disabled : () -> Bool, is_hovered : () -> Bool, is_pressed : () -> Bool, is_focus : () -> Bool) {
          let hover_way = @motion.NodeWay::new(0.0)
          m.reacts(
            at_start=false,
            fn() {
              if is_disabled() {
                0.0
              } else if is_pressed() {
                1.0
              } else if is_hovered() {
                0.5
              } else {
                0.0
              }
            },
            fn(to) { hover_way.go(m, to, @motion.snappy_damped) },
          )
          m
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .height(Is(Some(ctrl_chip_rm_size)))
          .padding(Is((ctrl_chip_gap, 0.0, ctrl_chip_gap, 0.0)))
          .gap(Is(ctrl_chip_gap))
          .radius(Is(inner_r))
          |> ignore
          m.box(fn(hov) {
            hov
            .over(Is(true))
            .points(Is(false))
            .radius(Is(inner_r))
            .ground(By(ctrl_hover_ink))
            .alpha(By(fn() { clamp(hover_way.shown(hov), 0.0, 1.0) * ctrl_press_glow_alpha }))
            |> ignore
          })
          |> ignore
          draw_body(m)
          m.show(is_focus, fn(ring) {
            ring
            .over(Is(true))
            .points(Is(false))
            .radius(Is(inner_r))
            .edge(By(fn() { (ctrl_focus_w, colors().accent) }))
            |> ignore
          })
        }
        if toggleable {
          @headless.toggle(made_for=loc, cap, Button, label, selected, fn(_) { on_press() }, disabled~, fn(m, tg) {
            build_main(m, fn() { tg.disabled() }, fn() { tg.hovered() }, fn() { tg.pressed() }, fn() { tg.focus_shown() })
          })
          |> ignore
        } else {
          @headless.button(made_for=loc, cap, label, fn(_) { on_press() }, disabled~, fn(m, btn) {
            build_main(m, fn() { btn.disabled() }, fn() { btn.hovered() }, fn() { btn.pressed() }, fn() { btn.focus_shown() })
          })
          |> ignore
        }
        @headless.button(made_for=loc, cap, remove_label, fn(_) { rm() }, disabled~, fn(rb, btn) {
          let hover_way = @motion.NodeWay::new(0.0)
          rb.reacts(at_start=false, fn() { !btn.disabled() && (btn.hovered() || btn.pressed()) }, fn(on) {
            hover_way.go(rb, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
          })
          rb
          .width(Is(Some(ctrl_chip_rm_size)))
          .height(Is(Some(ctrl_chip_rm_size)))
          .shrink(Is(0.0))
          .radius(Is(inner_r))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          |> ignore
          rb.box(fn(hov) {
            hov
            .over(Is(true))
            .points(Is(false))
            .radius(Is(inner_r))
            .ground(By(ctrl_hover_ink))
            .alpha(By(fn() { clamp(hover_way.shown(hov), 0.0, 1.0) * ctrl_press_glow_alpha }))
            |> ignore
          })
          |> ignore
          rb.box(fn(ic) {
            ic
            .width(Is(Some(ctrl_clear_icon_size)))
            .height(Is(Some(ctrl_clear_icon_size)))
            .shrink(Is(0.0))
            .shapes(By(fn() { ctrl_close_shapes(ctrl_clear_icon_size, fg_ink()) }))
            |> ignore
          })
          |> ignore
          rb.show(fn() { btn.focus_shown() }, fn(ring) {
            ring
            .over(Is(true))
            .points(Is(false))
            .radius(Is(inner_r))
            .edge(By(fn() { (ctrl_focus_w, colors().accent) }))
            |> ignore
          })
        })
        |> ignore
      })
    }
  }
}

///|
/// A 24pt semantic Liquid Glass badge capsule with optional leading status dot.
#callsite(autofill(loc))
pub fn liquid_badge_node(
  parent : @view.View,
  label : () -> String,
  tone? : LiquidTone = Neutral,
  dot? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    b
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .height(Is(Some(ctrl_badge_h)))
    .shrink(Is(0.0))
    .padding(Is((ctrl_badge_px, 0.0, ctrl_badge_px, 0.0)))
    .gap(Is(ctrl_badge_gap))
    .radius(Is(ctrl_badge_r))
    .ground(By(fn() { ctrl_badge_palette(tone).0 }))
    .edge(By(fn() { (ctrl_badge_edge_w, ctrl_badge_edge_ink()) }))
    .says(By(fn() { Some(@view.said(Status, label=label())) }))
    |> ignore
    if dot {
      b.box(fn(d) {
        d
        .width(Is(Some(ctrl_badge_dot)))
        .height(Is(Some(ctrl_badge_dot)))
        .shrink(Is(0.0))
        .radius(Is(ctrl_badge_dot / 2.0))
        .ground(By(fn() { ctrl_badge_palette(tone).3 }))
        |> ignore
      })
      |> ignore
    }
    b.box(fn(w) {
      w
      .words(By(label), look=words_at(ctrl_type_badge, weight=weight_medium))
      .ink(By(fn() { ctrl_badge_palette(tone).2 }))
      |> ignore
    })
    |> ignore
  })
}

///|
/// A 22pt tabular numeric Liquid Glass count badge. Hidden via `View::show` when `count() <= 0`,
/// and formatted as `"<max_count>+"` when `count() > max_count`.
#callsite(autofill(loc))
pub fn liquid_count_badge_node(
  parent : @view.View,
  count : () -> Int,
  max_count? : Int = 99,
  tone? : LiquidTone = Danger,
  loc~ : SourceLoc,
) -> @view.View {
  let shown_text = fn() {
    let c = count()
    if c > max_count {
      "\{max_count}+"
    } else {
      "\{c}"
    }
  }
  parent.box(made_for=loc, fn(host) {
    host.show(
      fn() { count() > 0 },
      fn(b) {
        b
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .min_width(Is(Some(ctrl_count_h)))
        .height(Is(Some(ctrl_count_h)))
        .shrink(Is(0.0))
        .padding(Is((ctrl_count_px, 0.0, ctrl_count_px, 0.0)))
        .radius(Is(ctrl_count_r))
        .ground(By(fn() { ctrl_count_palette(tone).1 }))
        .edge(By(fn() { (ctrl_badge_edge_w, ctrl_badge_edge_ink()) }))
        .says(By(fn() { Some(@view.said(Status, label=shown_text())) }))
        |> ignore
        b.box(fn(w) {
          w
          .words(By(shown_text), look=words_at(ctrl_type_count, weight=ctrl_weight_semibold))
          .words_centered(Is(true))
          .ink(By(fn() { ctrl_count_palette(tone).2 }))
          |> ignore
        })
        |> ignore
      },
      at_once=true,
    )
  })
}
