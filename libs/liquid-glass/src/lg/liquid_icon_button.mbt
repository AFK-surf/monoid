// Circular liquid glass icon button and unified floating capsule button group.
// Single-layer iOS 27 Glass::liquid on the outer capsule; inner group buttons use
// concentric translucent highlights (zero glass-on-glass).

///|
/// Size presets for liquid glass icon buttons and button groups (36 / 44 / 52 pt).
#derive(Eq, Debug)
pub(all) enum LiquidButtonSize {
  Small
  Regular
  Large
}

///|
fn ctrl_button_size_px(size : LiquidButtonSize) -> Double {
  match size {
    Small => ctrl_btn_sm
    Regular => ctrl_btn_md
    Large => ctrl_btn_lg
  }
}

///|
/// A circular floating liquid glass icon button in `parent`, read out as a button named `label`.
/// Supports jelly stretch and touch spotlight (`InteractiveHighlight`), active tinting,
/// disabled state and keyboard focus ring.
#callsite(autofill(loc))
pub fn liquid_icon_button_node(
  parent : @view.View,
  label : () -> String,
  icon : (@view.View, () -> Int64) -> Unit,
  press : () -> Unit,
  size? : LiquidButtonSize = Regular,
  tint? : Int64 = clear,
  surface? : Int64 = clear,
  active? : () -> Bool = fn() { false },
  disabled? : () -> Bool = fn() { false },
  interactive? : Bool = true,
  highlight? : InteractiveHighlight,
  loc~ : SourceLoc,
) -> @view.View {
  let side = ctrl_button_size_px(size)
  let r = side / 2.0
  @headless.button(made_for=loc, parent, label, fn(_) { press() }, disabled~, fn(b, btn) {
    let ih = match highlight {
      Some(l) => l
      None => InteractiveHighlight::new()
    }
    ih.attach(b)
    let hover_way = @motion.NodeWay::new(0.0)
    b.reacts(at_start=false, fn() { !btn.disabled() && btn.hovered() }, fn(on) {
      hover_way.go(b, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
    })
    let eff_tint = fn() {
      if tint != clear {
        tint
      } else if active() {
        ctrl_chip_selected_tint()
      } else {
        clear
      }
    }
    b
    .width(Is(Some(side)))
    .height(Is(Some(side)))
    .shrink(Is(0.0))
    .radius(Is(r))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .shadow(Is(shadow_default))
    .glass(By(fn() { Some(ctrl_surface_glass(eff_tint(), surface)) }))
    .ground_drawn(By(fn() {
      if !interactive {
        return @view.ground_as_laid
      }
      let (w, h) = ih.size.get()
      let (dx, dy, sx, sy) = ih.stretch(b)
      stretched(w, h, dx, dy, sx, sy)
    }))
    .alpha(By(fn() { if btn.disabled() { ctrl_disabled_alpha } else { 1.0 } }))
    |> ignore
    if interactive {
      b.gesture(
        @ui.touch_slop(),
        press=fn(d) {
          if !btn.disabled() {
            ih.down(d.x, d.y, d.w, d.h)
          }
        },
        tap=fn(_) {
          ih.up()
          if !btn.disabled() {
            btn.press()
          }
        },
        drag=fn(d) {
          if btn.disabled() {
            return
          }
          match d.kind {
            Down | Moved => ih.moved(d.x, d.y)
            Up => {
              ih.up()
              if d.x >= 0.0 && d.x <= d.w && d.y >= 0.0 && d.y <= d.h {
                btn.press()
              }
            }
            Off => ih.up()
          }
        },
      )
      |> ignore
      b.box(fn(ov) {
        ov
        .over(Is(true))
        .points(Is(false))
        .radius(Is(r))
        .ground(Is(white))
        .alpha(By(fn() { clamp(ih.pressed(ov), 0.0, 1.0) * ctrl_press_glow_alpha }))
        .ground_drawn(By(fn() {
          let (w, h) = ih.size.get()
          let (dx, dy, sx, sy) = ih.stretch(ov)
          stretched(w, h, dx, dy, sx, sy)
        }))
        |> ignore
      })
      |> ignore
    }
    b.box(fn(hov) {
      hov
      .over(Is(true))
      .points(Is(false))
      .radius(Is(r))
      .ground(By(ctrl_hover_ink))
      .alpha(By(fn() { clamp(hover_way.shown(hov), 0.0, 1.0) * ctrl_hover_alpha }))
      |> ignore
    })
    |> ignore
    b.box(fn(c) {
      c
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .offset(By(fn() {
        if interactive {
          let (dx, dy, _, _) = ih.stretch(b)
          (dx, dy)
        } else {
          (0.0, 0.0)
        }
      }))
      .scale(By(fn() {
        if interactive {
          let (_, _, sx, sy) = ih.stretch(b)
          (sx + sy) / 2.0
        } else {
          1.0
        }
      }))
      |> ignore
      icon(c, fn() { if eff_tint() != clear { white } else { colors().content } })
    })
    |> ignore
    b.show(fn() { btn.focus_shown() }, fn(ring) {
      ring
      .over(Is(true))
      .points(Is(false))
      .margin(Is((-ctrl_focus_outset, -ctrl_focus_outset, -ctrl_focus_outset, -ctrl_focus_outset)))
      .radius(Is(r + ctrl_focus_outset))
      .edge(By(fn() { (ctrl_focus_w, colors().accent) }))
      |> ignore
    })
  })
}

///|
/// One action inside a `liquid_button_group_node`.
pub(all) struct LiquidGroupAction {
  label : () -> String
  icon : (@view.View, () -> Int64) -> Unit
  press : () -> Unit
  active : () -> Bool
  disabled : () -> Bool
}

///|
/// Constructs a `LiquidGroupAction` with optional `active` and `disabled` signals.
pub fn LiquidGroupAction::new(
  label~ : () -> String,
  icon~ : (@view.View, () -> Int64) -> Unit,
  press~ : () -> Unit,
  active? : () -> Bool = fn() { false },
  disabled? : () -> Bool = fn() { false },
) -> LiquidGroupAction {
  { label, icon, press, active, disabled }
}

///|
/// A unified floating liquid glass capsule holding multiple icon actions separated by subtle
/// hairlines (no leading/trailing dividers, concentric inner hit pills, zero glass-on-glass).
#callsite(autofill(loc))
pub fn liquid_button_group_node(
  parent : @view.View,
  actions : () -> Array[LiquidGroupAction],
  size? : LiquidButtonSize = Regular,
  surface? : Int64 = clear,
  loc~ : SourceLoc,
) -> @view.View {
  let h = ctrl_button_size_px(size)
  let r_outer = h / 2.0
  let inner_h = h - 2.0 * ctrl_group_pad
  let r_inner = inner_h / 2.0
  let div_h = h * ctrl_divider_ratio
  parent.box(made_for=loc, fn(g) {
    g
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .height(Is(Some(h)))
    .shrink(Is(0.0))
    .padding(Is((ctrl_group_pad, ctrl_group_pad, ctrl_group_pad, ctrl_group_pad)))
    .radius(Is(r_outer))
    .shadow(Is(shadow_default))
    .glass(By(fn() { Some(ctrl_surface_glass(clear, surface)) }))
    .says(Is(Some(@view.said(Group, label="Action Group"))))
    |> ignore
    g.each(
      fn() {
        let n = actions().length()
        let ids : Array[Int] = []
        for i in 0..<n {
          ids.push(i)
        }
        ids
      },
      fn(i) { i },
      fn(slot, idx_sig) {
        let idx = @signals.untracked(fn() { idx_sig.get() })
        slot.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
        if idx > 0 {
          slot.box(fn(div) {
            div
            .width(Is(Some(ctrl_hairline_w)))
            .height(Is(Some(div_h)))
            .shrink(Is(0.0))
            .margin(Is((ctrl_group_item_gap, 0.0, ctrl_group_item_gap, 0.0)))
            .ground(By(ctrl_divider_ink))
            |> ignore
          })
          |> ignore
        }
        let get_action = fn() { actions().get(idx_sig.get()) }
        let item_label = fn() {
          match get_action() {
            Some(a) => (a.label)()
            None => ""
          }
        }
        let item_disabled = fn() {
          match get_action() {
            Some(a) => (a.disabled)()
            None => true
          }
        }
        let item_active = fn() {
          match get_action() {
            Some(a) => (a.active)()
            None => false
          }
        }
        let item_press = fn() {
          match get_action() {
            Some(a) => (a.press)()
            None => ()
          }
        }
        @headless.button(made_for=loc, slot, item_label, fn(_) { item_press() }, disabled=item_disabled, fn(b, btn) {
          let highlight_way = @motion.NodeWay::new(0.0)
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
            fn(to) { highlight_way.go(b, to, @motion.snappy_damped) },
          )
          b
          .width(Is(Some(inner_h)))
          .height(Is(Some(inner_h)))
          .shrink(Is(0.0))
          .radius(Is(r_inner))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          .alpha(By(fn() { if btn.disabled() { ctrl_disabled_alpha } else { 1.0 } }))
          |> ignore
          // Concentric inner active pill (no nested glass)
          b.box(fn(act) {
            act
            .over(Is(true))
            .points(Is(false))
            .radius(Is(r_inner))
            .ground(By(ctrl_chip_selected_tint))
            .alpha(By(fn() { if item_active() { 1.0 } else { 0.0 } }))
            |> ignore
          })
          |> ignore
          // Concentric inner hover/press highlight
          b.box(fn(hov) {
            hov
            .over(Is(true))
            .points(Is(false))
            .radius(Is(r_inner))
            .ground(By(ctrl_hover_ink))
            .alpha(By(fn() { clamp(highlight_way.shown(hov), 0.0, 1.0) * ctrl_press_glow_alpha }))
            |> ignore
          })
          |> ignore
          match @signals.untracked(actions).get(idx) {
            Some(a) =>
              (a.icon)(b, fn() { if item_active() { white } else { colors().content } })
            None => ()
          }
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
      },
      at_once=true,
    )
  })
}
