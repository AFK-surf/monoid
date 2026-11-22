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
/// Layout axis for `liquid_pill_group_node` (horizontal top-bar pill vs. vertical floating pill).
#derive(Eq, Debug)
pub(all) enum PillDirection {
  Horizontal
  Vertical
}

///|
/// Zero-signal view of the `(spot, layer)` signal's `spot` component for `PillPressScope`.
priv struct PillSpotView {
  fx : @signals.Signal[((Double, Double)?, Int)]
}

///|
// Read by whitebox tests (`kit_controls_wbtest.mbt`) to inspect active press spot without a second signal.
#warnings("-unused_value")
fn PillSpotView::untracked(self : PillSpotView) -> (Double, Double)? {
  self.fx.untracked().0
}

///|
/// Shared press-feedback scope lent by `liquid_pill_group_node` and `liquid_button_group_node` to
/// their interactive children (`bind_pill_press` / `bind_pill_press_by`).
// `spot` is read by whitebox tests (`kit_controls_wbtest.mbt`).
#warnings("-unused_field")
priv struct PillPressScope {
  pill : @view.View
  fx : @signals.Signal[((Double, Double)?, Int)]
  spot : PillSpotView
  press_way : @motion.NodeWay
  mut count : Int
}

///|
let pill_press_lent : @view.Lent[PillPressScope] = @view.Lent::new()

///|
/// Trigger scope lent by `liquid_pill_group_node` to its children (0 new signals, 0 new cold-start
/// bindings) so an anchored popover can briefly activate a private SDF fusion layer or in-place
/// morph override (`morph_glass` / `morph_shadow`) while keeping adjacent pills isolated.
pub(all) struct PillTriggerScope {
  pill : @view.View
  fx : @signals.Signal[((Double, Double)?, Int)]
  press_way : @motion.NodeWay
  morph_glass : Ref[(() -> @paint.Glass?)?]
  morph_shadow : Ref[(() -> (Double, Double, Int64))?]
  mut morph_owner : Int
  mut morph_cancel : (() -> Unit)?
  children : Array[@view.View]
  height : Double
  pad : Double
}

///|
pub let liquid_pill_trigger_lent : @view.Lent[PillTriggerScope] = @view.Lent::new()

///|
/// Theme-adaptive press overlay ink for controls inside a liquid glass pill group.
pub fn liquid_pill_press_ink() -> Int64 {
  liquid_press_ink()
}

///|
/// Connects an interactive child control inside `liquid_pill_group_node` (or `liquid_button_group_node`)
/// to its enclosing liquid glass pill's press response: moves the GPU `spot` specular highlight to
/// the child's center and springs the outer pill scale via `@motion.backdrop_press_spring`.
/// No-op outside a pill group.
pub fn bind_pill_press(child : @view.View) -> Unit {
  bind_pill_press_by(child, fn() { child.pressed() })
}

///|
/// Connects `child` inside a pill group to its enclosing pill's press response using a custom
/// `down` predicate (e.g. host-driven press state such as window snap/maximize), sharing the
/// pill's press count and `liquid_pill_trigger_lent` child list. No-op outside a pill group.
pub fn bind_pill_press_by(child : @view.View, down : () -> Bool) -> Unit {
  guard child.lent(pill_press_lent) is Some(scope) else { return }
  let trig_opt = child.lent(liquid_pill_trigger_lent)
  match trig_opt {
    Some(trig) => trig.children.push(child)
    None => ()
  }
  let active = Ref(false)
  let release = fn() {
    if active.val {
      active.val = false
      scope.count = if scope.count > 0 { scope.count - 1 } else { 0 }
      if scope.count == 0 {
        let (_, ly) = scope.fx.get()
        scope.fx.set((None, ly))
        scope.press_way.go(scope.pill, 0.0, @motion.backdrop_press_spring)
      }
    }
  }
  child.reacts(down, fn(is_down) {
    if is_down {
      if !active.val {
        active.val = true
        scope.count += 1
      }
      if !scope.pill.glass_solid() {
        let (gx, gy, _, _) = scope.pill.placed_window_now()
        let (cx, cy, cw, ch) = child.placed_window_now()
        let (_, ly) = scope.fx.get()
        scope.fx.set((Some((cx - gx + cw / 2.0, cy - gy + ch / 2.0)), ly))
      }
      if !@ui.reduced_motion() {
        scope.press_way.go(scope.pill, 1.0, @motion.backdrop_press_spring)
      }
    } else {
      release()
    }
  })
  child.owns(fn() {
    release()
    match trig_opt {
      Some(trig) => {
        let cid = child.id()
        let mut idx = -1
        for i in 0..<trig.children.length() {
          if trig.children[i].id() == cid {
            idx = i
            break
          }
        }
        if idx >= 0 {
          ignore(trig.children.remove(idx))
          if trig.children.is_empty() {
            trig.children.shrink_to_fit()
          }
        }
      }
      None => ()
    }
  })
  |> ignore
}

///|
/// A generic single-layer floating Liquid Glass pill container in `parent` for a group of bar or
/// floating controls built by `body`. Supports horizontal and vertical axes, optional custom tint
/// and floating recipe, custom shadow / solid hairline edge, and `liquid_pill_trigger_lent` for
/// private SDF layer fusion and in-place popover morphing.
#callsite(autofill(loc))
pub fn liquid_pill_group_node(
  parent : @view.View,
  body : (@view.View) -> Unit,
  height? : Double = 40.0,
  pad? : Double = 3.0,
  pad_y? : Double,
  gap? : Double = 2.0,
  direction? : PillDirection = Horizontal,
  sharing? : Bool = true,
  solid? : () -> Int64,
  tint? : () -> Int64,
  shadow? : () -> (Double, Double, Int64),
  solid_edge? : () -> (Double, Int64),
  floating? : Bool = false,
  adaptive? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(g) {
    let r = height / 2.0
    let py = match pad_y {
      Some(v) => v
      None => pad
    }
    let fx_sig : @signals.Signal[((Double, Double)?, Int)] = @signals.signal((None, 0))
    let morph_glass : Ref[(() -> @paint.Glass?)?] = Ref(None)
    let morph_shadow : Ref[(() -> (Double, Double, Int64))?] = Ref(None)
    let children : Array[@view.View] = []
    let press_way = @motion.NodeWay::new(0.0)
    let scope : PillPressScope = { pill: g, fx: fx_sig, spot: { fx: fx_sig }, press_way, count: 0 }
    let trig_scope : PillTriggerScope = {
      pill: g,
      fx: fx_sig,
      press_way,
      morph_glass,
      morph_shadow,
      morph_owner: 0,
      morph_cancel: None,
      children,
      height,
      pad,
    }
    let make_glass = fn(sp : (Double, Double)?, ly : Int) -> @paint.Glass {
      let eff_sharing = if ly > 0 { false } else { sharing }
      let sol = match solid {
        Some(f) => f()
        None => clear
      }
      let base = if floating {
        match tint {
          Some(tf) => {
            let c = tf()
            let base_sol = if sol != clear {
              sol
            } else if is_dark() {
              0x1E1F24FFL
            } else {
              0xFAFAFAFFL
            }
            liquid_floating_glass(
              tint=Some(c),
              solid=over(base_sol, alpha(c, 0.24)),
              spot=sp,
              sharing=eff_sharing,
            )
          }
          None => liquid_floating_glass(solid=sol, spot=sp, sharing=eff_sharing)
        }
      } else {
        match tint {
          Some(tf) => {
            let c = tf()
            let base_sol = if sol != clear {
              sol
            } else if is_dark() {
              0x1E1F24FFL
            } else {
              0xFAFAFAFFL
            }
            {
              ..liquid_bar_pill_glass(
                spot=sp,
                solid=over(base_sol, alpha(c, 0.24)),
                sharing=eff_sharing,
                adaptive~,
              ),
              tint: c,
            }
          }
          None => liquid_bar_pill_glass(spot=sp, solid=sol, sharing=eff_sharing, adaptive~)
        }
      }
      if ly > 0 {
        { ..base, layer: ly, break_gap: 12.0 }
      } else {
        base
      }
    }
    let rest_shadow = fn() {
      match shadow {
        Some(f) => f()
        None => shadow_default
      }
    }
    match direction {
      Horizontal => g.row(Is(true)).height(Is(Some(height))) |> ignore
      Vertical => g.width(Is(Some(height))) |> ignore
    }
    g
    .radius(Is(r))
    .padding(Is((pad, py, pad, py)))
    .gap(Is(gap))
    .lines_up(Is(Some(Middle)))
    .shrink(Is(0.0))
    .glass(By(fn() {
      let (sp, ly) = fx_sig.get()
      if ly != 0 {
        match morph_glass.val {
          Some(f) => f()
          None => if ly < 0 { None } else { Some(make_glass(sp, ly)) }
        }
      } else {
        Some(make_glass(sp, ly))
      }
    }))
    .scale(By(fn() { 1.0 + 0.05 * press_way.shown(g) }), about=At(0.5, 0.5))
    .edge(By(fn() {
      if g.glass_solid() {
        match solid_edge {
          Some(f) => f()
          None => liquid_solid_edge()
        }
      } else {
        (0.0, clear)
      }
    }))
    .shadow(By(fn() {
      let ly = fx_sig.get().1
      if ly != 0 {
        match morph_shadow.val {
          Some(f) => f()
          None => if ly < 0 { shadow_none } else { rest_shadow() }
        }
      } else {
        rest_shadow()
      }
    }))
    .shadow_outside(Is(true))
    .clips(Is(true))
    .lends(pill_press_lent, scope)
    .lends(liquid_pill_trigger_lent, trig_scope)
    |> ignore
    body(g)
  })
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
  side? : Double,
  tint? : Int64 = clear,
  surface? : Int64 = clear,
  active? : () -> Bool = fn() { false },
  disabled? : () -> Bool = fn() { false },
  interactive? : Bool = true,
  sharing? : Bool = false,
  highlight? : InteractiveHighlight,
  loc~ : SourceLoc,
) -> @view.View {
  let side = match side {
    Some(s) => s
    None => ctrl_button_size_px(size)
  }
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
    .shadow_outside(Is(true))
    .glass(By(fn() {
      let sp = if interactive && ih.pressed(b) > 0.001 {
        let (w, h) = ih.size.get()
        if w > 0.0 && h > 0.0 {
          Some(ih.spot(b, w, h))
        } else {
          None
        }
      } else {
        None
      }
      Some(liquid_control_glass(tint=eff_tint(), surface~, spot=sp, sharing~))
    }))
    .edge(By(fn() { if b.glass_solid() { liquid_solid_edge() } else { (0.0, clear) } }))
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
        .ground(By(liquid_press_ink))
        .alpha(By(fn() { clamp(ih.pressed(ov), 0.0, 1.0) }))
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
    let fx_sig : @signals.Signal[((Double, Double)?, Int)] = @signals.signal((None, 0))
    let press_way = @motion.NodeWay::new(0.0)
    let scope : PillPressScope = { pill: g, fx: fx_sig, spot: { fx: fx_sig }, press_way, count: 0 }
    g
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .height(Is(Some(h)))
    .shrink(Is(0.0))
    .padding(Is((ctrl_group_pad, ctrl_group_pad, ctrl_group_pad, ctrl_group_pad)))
    .radius(Is(r_outer))
    .shadow(Is(shadow_default))
    .shadow_outside(Is(true))
    .glass(By(fn() { Some(liquid_control_glass(tint=clear, surface~, spot=fx_sig.get().0)) }))
    .scale(By(fn() { 1.0 + 0.05 * press_way.shown(g) }), about=At(0.5, 0.5))
    .edge(By(fn() { if g.glass_solid() { liquid_solid_edge() } else { (0.0, clear) } }))
    .lends(pill_press_lent, scope)
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
          bind_pill_press(b)
          let highlight_way = @motion.NodeWay::new(0.0)
          let active_way = @motion.NodeWay::new(if @signals.untracked(item_active) { 1.0 } else { 0.0 })
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
            fn(to) { highlight_way.go(b, to, @motion.snappy_damped) },
          )
          b.reacts(at_start=false, item_active, fn(on) {
            active_way.go(b, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
          })
          b.reacts(at_start=false, fn() { !btn.disabled() && btn.pressed() }, fn(on) {
            press_way.go(b, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
          })
          b
          .width(Is(Some(inner_h)))
          .height(Is(Some(inner_h)))
          .shrink(Is(0.0))
          .radius(Is(r_inner))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          .scale(By(fn() { 1.0 - 0.07 * clamp(press_way.shown(b), 0.0, 1.0) }))
          .alpha(By(fn() { if btn.disabled() { ctrl_disabled_alpha } else { 1.0 } }))
          |> ignore
          // Concentric inner active pill (no nested glass; smooth spring fade & scale)
          b.box(fn(act) {
            act
            .over(Is(true))
            .points(Is(false))
            .radius(Is(r_inner))
            .ground(By(ctrl_chip_selected_tint))
            .scale(By(fn() { lerp(0.88, 1.0, clamp(active_way.shown(act), 0.0, 1.0)) }))
            .alpha(By(fn() { clamp(active_way.shown(act), 0.0, 1.0) }))
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
