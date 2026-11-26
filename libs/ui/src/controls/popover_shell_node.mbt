// Unified anchored popover shell and placement-side helper for overlays anchored beside a trigger
// (`menu_node`, `panel_node`, `pick_node`, `hover_panel_node`): single-layer iOS 27 liquid glass (`glass_menu()`),
// automatic solid fallback (`panel_ground()` + 1 pt `panel_edge()`) when `MBUI_GLASS=solid`, outside-only
// `glass_overlay_shadow()` (`shadow_outside(Is(true))` so outer shadows never bleed inside glass), `r_menu` corner
// radius, clipping, `FromBeside` pop motion, and `ground_node` input boundary.
//
// Popovers (`menu_node`) anchored to a button inside a liquid glass `bar_pill_group_node` (`@glass.liquid_pill_trigger_lent`)
// execute the 1:1 CADisplayLink-calibrated iOS 27.0 `LiquidMorphPhysics` engine (`@glass` `liquid_morph_physics.mbt`):
// - Open (`420ms` linear phase clock driving critically damped `omega0=26.0, zeta=1.0` spring): luminous crystal
//   droplet (`0x4E`, `blur=1.6`) blooms from the contracting trigger capsule with scaled blurred content (`content_lens`)
//   and settles with zero `kind == 8` overhead at rest;
// - Close (`610ms` linear phase clock): `0..~285ms` teardrop contraction + gap-gated Blob A emergence & SDF neck
//   fusion + parallel `-9.5pt` peak upward trigger recoil (`t ≈ 213ms`) and impact scale (`~0.965`), handing off
//   cleanly at `raw <= 0.045` to the real trigger pill for `285..610ms` recoil return and `+1.6%` horizontal splash.
// Non-pill buttons and `1×1` point anchors keep the original `FromBeside` (`0.97..1.0`) pop motion.

///|
/// Shared pill-morph state lent from `anchored_popover_bridge` to `anchored_popover_shell` and `popover_content_motion`.
priv struct PillMorphState {
  side : @ui.Side
  along : @ui.Along
  direction : @glass.PillDirection
  pill_layer : Int
  aw : Double
  ah : Double
  pill_pad : Double
  pill_x : Double
  pill_y : Double
  pill_w : Double
  pill_h : Double
  tx_win : Double
  ty_win : Double
  rest_glass : () -> @paint.Glass
  has_press_scale : Bool
  is_closing : @signals.Signal[Bool]
  superseded : @signals.Signal[Bool]
  t_way : @motion.NodeWay
  shell_ref : Ref[@view.View?]
  last_shell_bounds : Ref[(Double, Double, Double, Double)?]
  close_start : Ref[Double]
}

///|
let pill_morph_lent : @view.Lent[PillMorphState] = @view.Lent::new()

///|
fn pill_morph_eval(
  pm : PillMorphState,
  px_win : Double,
  py_win : Double,
  menu_w : Double,
  menu_h : Double,
  closing : Bool,
  t : Double,
) -> @glass.LiquidMorphFrame {
  let horizontal_side = pm.side is (Left | Right)
  let vertical = pm.direction == Vertical
  let along_val = match pm.along {
    Start => -1.0
    End => 1.0
    Middle => 0.0
  }
  let align_x = if horizontal_side { 0.0 } else { along_val }
  let align_y = if horizontal_side { along_val } else { 0.0 }
  @glass.lm_eval_pill_morph(
    pm.pill_x,
    pm.pill_y,
    pm.pill_w,
    pm.pill_h,
    pm.tx_win,
    px_win,
    py_win,
    menu_w,
    menu_h,
    r_menu,
    align_x,
    closing,
    t,
    vertical~,
    ty_win=pm.ty_win,
    align_y~,
    horizontal_side~,
    close_start=pm.close_start.val,
  )
}

///|
fn pill_morph_shell_bounds(pm : PillMorphState) -> (Double, Double, Double, Double) {
  match pm.shell_ref.val {
    Some(shell) if shell.alive() => {
      let (px, py, w, h) = shell.placed_window_now()
      if w > 0.0 && h > 0.0 {
        pm.last_shell_bounds.val = Some((px, py, w, h))
        return (px, py, w, h)
      }
    }
    _ => ()
  }
  match pm.last_shell_bounds.val {
    Some(b) => b
    None => (pm.pill_x, pm.pill_y, dmax(pm.pill_w, 180.0), 220.0)
  }
}

///|
/// Content opacity for popover bodies (`menu_node`, `panel_node`, `pick_node`): when GPU `content_lens` is active
/// (`content_opacity > 0.01 && content_blur > 0.05`), returns `1.0` so `content_lens` owns linear opacity + blur
/// without double-multiplying alpha.
fn popover_content_alpha(p : @view.View, node : @view.View, fallback : () -> Double) -> Double {
  match p.lent(pill_morph_lent) {
    Some(pm) => {
      if pm.superseded.get() {
        return 0.0
      }
      let t = pm.t_way.shown(node)
      let closing = pm.is_closing.get()
      let (px_win, py_win, w, h) = p.placed_window_now()
      let f = pill_morph_eval(pm, px_win, py_win, dmax(w, 1.0), dmax(h, 1.0), closing, t)
      let lens_on = !p.glass_solid() && f.content_opacity > 0.01 && f.content_blur > 0.05
      if f.content_opacity <= 0.01 {
        0.0
      } else if lens_on {
        1.0
      } else {
        f.content_opacity
      }
    }
    None => fallback()
  }
}

///|
/// Scaled + droplet-centered content reveal for pill-anchored popovers (`contentScale = clamp(cur_w / menu_w, 0.20, 1.0)`,
/// centered inside `(mx, my, cur_w, cur_h)` so rows scale smoothly with the morphing capsule without clipping or colliding).
fn popover_content_motion(p : @view.View, node : @view.View, fallback : () -> Double) -> Unit {
  node.alpha(By(fn() { popover_content_alpha(p, node, fallback) })) |> ignore
  match p.lent(pill_morph_lent) {
    Some(pm) => {
      node.scale(
        By(fn() {
          let t = pm.t_way.shown(node)
          let closing = pm.is_closing.get()
          if !closing && t >= @glass.lm_open_duration_ms / 1000.0 - 0.001 {
            1.0
          } else {
            let (px_win, py_win, w, h) = p.placed_window_now()
            if w <= 0.0 || h <= 0.0 {
              1.0
            } else {
              let f = pill_morph_eval(pm, px_win, py_win, w, h, closing, t)
              dclamp(dmin(f.cur_w / w, f.cur_h / h), 0.20, 1.0)
            }
          }
        }),
        about=At(0.5, 0.5),
      )
      |> ignore
      node.offset(
        By(fn() {
          let t = pm.t_way.shown(node)
          let closing = pm.is_closing.get()
          if !closing && t >= @glass.lm_open_duration_ms / 1000.0 - 0.001 {
            (0.0, 0.0)
          } else {
            let (px_win, py_win, w, h) = p.placed_window_now()
            if w <= 0.0 || h <= 0.0 {
              (0.0, 0.0)
            } else {
              let f = pill_morph_eval(pm, px_win, py_win, w, h, closing, t)
              (f.mx + f.cur_w * 0.5 - w * 0.5, f.my + f.cur_h * 0.5 - h * 0.5)
            }
          }
        }),
      )
      |> ignore
    }
    _ => ()
  }
}

///|
/// Configures anchored popover liquid morphing on `layer` immediately before the popover shell (`menu_node`):
/// - Branch A (liquid glass `bar_pill_group_node` trigger): lends `pill_morph_lent` driving 1:1 iOS 27.0
///   `LiquidMorphPhysics` (trigger pill recoil, impact compression, horizontal splash, Blob A/B SDF fusion, and
///   `holds_leaving=true` sentinel through `610ms` close settle; 0 new cold-start bindings).
/// - Non-pill buttons, `1×1` point anchors, and `MBUI_GLASS=solid`: no-op, preserving original `FromBeside` (`0.97..1.0`).
#callsite(autofill(loc))
pub fn anchored_popover_bridge(
  layer : @view.View,
  anchor : @view.View,
  look : () -> @ui.Look,
  side? : @ui.Side = Bottom,
  along? : @ui.Along = Start,
  offset? : Double = panel_offset,
  start_open? : (() -> Unit) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  ignore(look)
  ignore(offset)
  let (ax, ay, aw, ah) = anchor.placed_window_now()
  // (whatever the glass is made of, and motion reduced or not: the material changes how it looks, reduced motion only
  // brings each motion to its end at once (its ways', @motion.Way); never where it opens nor what it does)
  if aw < 16.0 || ah < 16.0 {
    return
  }
  match anchor.lent(@glass.liquid_pill_trigger_lent) {
    Some(trig) => {
      match trig.morph_cancel {
        Some(cancel_prev) => cancel_prev()
        None => ()
      }
      trig.morph_owner += 1
      let my_owner = trig.morph_owner
      let superseded = @signals.signal(false)
      let layer_leave_end = Ref(0.0)
      let cancel_restore : Ref[(() -> Unit)?] = Ref(None)
      let cancel_close_delay : Ref[(() -> Unit)?] = Ref(None)
      trig.morph_cancel = Some(fn() {
        superseded.set(true)
        match cancel_close_delay.val {
          Some(c) => {
            cancel_close_delay.val = None
            c()
          }
          None => ()
        }
        match cancel_restore.val {
          Some(c) => {
            cancel_restore.val = None
            c()
          }
          None => ()
        }
      })
      let pill_h = trig.height
      let pill_pad = trig.pad
      let pill_layer = trig.pill.id().at + 100
      let (pill_x, pill_y, pill_w_raw, pill_h_raw) = trig.pill.placed_window_now()
      let pill_h_eff = if pill_h_raw > 0.0 { pill_h_raw } else if pill_h > 0.0 { pill_h } else { ah }
      let pill_w = if pill_w_raw > 0.0 { pill_w_raw } else if pill_h > 0.0 { pill_h } else { aw }
      let core = dmin(pill_w, pill_h_eff)
      let tx_win = ax + aw * 0.5
      let ty_win = ay + ah * 0.5
      let tx_mid = dclamp(tx_win - pill_x, core * 0.5, dmax(core * 0.5, pill_w - core * 0.5))
      let ty_mid = dclamp(ty_win - pill_y, core * 0.5, dmax(core * 0.5, pill_h_eff - core * 0.5))
      let is_closing = @signals.signal(false)
      let t_way = @motion.NodeWay::new(0.0)
      let shell_ref : Ref[@view.View?] = Ref(None)
      let last_shell_bounds : Ref[(Double, Double, Double, Double)?] = Ref(None)
      let horizontal_side = side is (Left | Right)
      let pm : PillMorphState = {
        side,
        along,
        direction: trig.direction,
        pill_layer,
        aw,
        ah,
        pill_pad,
        pill_x,
        pill_y,
        pill_w,
        pill_h: pill_h_eff,
        tx_win,
        ty_win,
        rest_glass: trig.rest_glass,
        has_press_scale: trig.has_press_scale,
        is_closing,
        superseded,
        t_way,
        shell_ref,
        last_shell_bounds,
        close_start: Ref(1.0),
      }
      let eval_trig = fn() -> (Double, Bool, @glass.LiquidMorphFrame) {
        let t = t_way.shown(trig.pill)
        let closing = is_closing.get()
        let (px_win, py_win, mw, mh) = pill_morph_shell_bounds(pm)
        (t, closing, pill_morph_eval(pm, px_win, py_win, mw, mh, closing, t))
      }
      // Attach trigger pill live morph glass/shadow callbacks & private SDF layer (0 cold-start bindings).
      trig.morph_glass.val = Some(fn() {
        let (t, closing, f) = eval_trig()
        if !closing {
          if f.open_anchor_scale <= 0.15 {
            None
          } else {
            let stage = 0.5 * @glass.lm_smoothstep(0.0, 0.06, t)
            Some(glass_menu_morph(stage, layer=pill_layer, break_gap=32.0))
          }
        } else if f.platter_active {
          if f.blob_a_emerge <= 0.001 {
            None
          } else {
            let stage = 0.5 * @glass.lm_smoothstep(0.0, 0.12, f.raw_value)
            Some(glass_menu_morph(stage, layer=pill_layer, break_gap=24.0))
          }
        } else {
          Some((pm.rest_glass)())
        }
      })
      trig.morph_shadow.val = Some(fn() {
        let (_, closing, f) = eval_trig()
        if closing && !f.platter_active {
          glass_control_shadow()
        } else {
          (0.0, 0.0, 0L)
        }
      })
      let (sp0, _) = trig.fx.get()
      trig.fx.set((sp0, pill_layer))
      let prev_owner = @signals.set_owner(None)
      trig.pill.offset(
        By(fn() {
          let (_, closing, f) = eval_trig()
          if closing {
            (f.push_dx, f.push_dy)
          } else {
            (0.0, 0.0)
          }
        }),
      )
      |> ignore
      trig.pill.scale(
        By(fn() {
          let (t, closing, f) = eval_trig()
          if closing {
            let travel = if horizontal_side { f.final_dx.abs() } else { f.final_dy.abs() }
            @glass.lm_impact_scale(t, travel)
          } else if pm.has_press_scale {
            1.0 + 0.05 * trig.press_way.shown(trig.pill)
          } else {
            1.0
          }
        }),
        about=At(0.5, 0.5),
      )
      |> ignore
      trig.pill.ground_drawn(
        By(fn() {
          let (t, closing, f) = eval_trig()
          match trig.direction {
            Horizontal =>
              if !closing {
                let wp = @glass.lm_open_trigger_width(t)
                let cw = @glass.lm_lerp(core, pill_w, wp)
                let cx = @glass.lm_lerp(tx_mid, pill_w * 0.5, wp)
                let r = dmin(cw, pill_h_eff) * 0.5
                { dx: cx - cw * 0.5, dy: 0.0, dw: cw - pill_w, dh: 0.0, corners: Some((r, r, r, r)) }
              } else if f.platter_active {
                let wp = @glass.lm_delayed_close_width(t)
                let cw = @glass.lm_lerp(core, pill_w, wp)
                let cx = @glass.lm_lerp(tx_mid, pill_w * 0.5, dclamp(wp, 0.0, 1.0))
                let r = dmin(cw, pill_h_eff) * 0.5
                {
                  dx: cx - cw * 0.5,
                  dy: 0.0,
                  dw: cw - pill_w,
                  dh: 0.0,
                  corners: Some((r, r, r, r)),
                }
              } else {
                let raw_scale = @glass.lm_lerp(core, pill_w, @glass.lm_close_trigger_width(t)) / pill_w
                let cw = pill_w * dclamp(raw_scale, 0.90, 1.04)
                let r = pill_h_eff * 0.5
                { dx: (pill_w - cw) * 0.5, dy: 0.0, dw: cw - pill_w, dh: 0.0, corners: Some((r, r, r, r)) }
              }
            Vertical =>
              if !closing {
                let wp = @glass.lm_open_trigger_width(t)
                let ch = @glass.lm_lerp(core, pill_h_eff, wp)
                let cy = @glass.lm_lerp(ty_mid, pill_h_eff * 0.5, wp)
                let r = dmin(pill_w, ch) * 0.5
                { dx: 0.0, dy: cy - ch * 0.5, dw: 0.0, dh: ch - pill_h_eff, corners: Some((r, r, r, r)) }
              } else if f.platter_active {
                let wp = @glass.lm_delayed_close_width(t)
                let ch = @glass.lm_lerp(core, pill_h_eff, wp)
                let cy = @glass.lm_lerp(ty_mid, pill_h_eff * 0.5, dclamp(wp, 0.0, 1.0))
                let r = dmin(pill_w, ch) * 0.5
                {
                  dx: 0.0,
                  dy: cy - ch * 0.5,
                  dw: 0.0,
                  dh: ch - pill_h_eff,
                  corners: Some((r, r, r, r)),
                }
              } else {
                let raw_scale = @glass.lm_lerp(core, pill_h_eff, @glass.lm_close_trigger_width(t)) / pill_h_eff
                let ch = pill_h_eff * dclamp(raw_scale, 0.90, 1.04)
                let r = pill_w * 0.5
                { dx: 0.0, dy: (pill_h_eff - ch) * 0.5, dw: 0.0, dh: ch - pill_h_eff, corners: Some((r, r, r, r)) }
              }
          }
        }),
      )
      |> ignore
      trig.pill.alpha(
        By(fn() {
          let (_, closing, f) = eval_trig()
          if !closing {
            if f.open_anchor_scale <= 0.15 { 0.0 } else { 1.0 }
          } else if f.platter_active {
            if f.blob_a_emerge <= 0.001 { 0.0 } else { 1.0 }
          } else {
            1.0
          }
        }),
      )
      |> ignore
      let bound_children = if !trig.children.is_empty() {
        trig.children.copy()
      } else if anchor.id() != trig.pill.id() {
        [anchor]
      } else {
        []
      }
      for child in bound_children {
        let (cx0, cy0, cw0, ch0) = child.placed_window_now()
        let child_cx_local = cx0 + cw0 * 0.5 - pill_x
        let child_cx_off = child_cx_local - pill_w * 0.5
        let child_to_tx = tx_mid - child_cx_local
        let child_cy_local = cy0 + ch0 * 0.5 - pill_y
        let child_cy_off = child_cy_local - pill_h_eff * 0.5
        let child_to_ty = ty_mid - child_cy_local
        child.alpha(
          By(fn() {
            let t = t_way.shown(child)
            if is_closing.get() {
              if t < 0.19 { 0.0 } else { @glass.lm_smoothstep(0.19, 0.275, t) }
            } else {
              1.0 - @glass.lm_smoothstep(0.0, 0.032, t)
            }
          }),
        )
        |> ignore
        child.offset(
          By(fn() {
            let t = t_way.shown(child)
            match trig.direction {
              Horizontal =>
                if !is_closing.get() {
                  let wp = @glass.lm_open_trigger_width(t)
                  (child_to_tx * (1.0 - wp) * 0.45, 0.0)
                } else {
                  let w_prog = dclamp(@glass.lm_delayed_close_width(t), 0.0, 1.0)
                  let blob_a_w = @glass.lm_lerp(core, pill_w, w_prog)
                  (-child_cx_off * (1.0 - dclamp(blob_a_w / pill_w, 0.5, 1.0)), 0.0)
                }
              Vertical =>
                if !is_closing.get() {
                  let wp = @glass.lm_open_trigger_width(t)
                  (0.0, child_to_ty * (1.0 - wp) * 0.45)
                } else {
                  let h_prog = dclamp(@glass.lm_delayed_close_width(t), 0.0, 1.0)
                  let blob_a_h = @glass.lm_lerp(core, pill_h_eff, h_prog)
                  (0.0, -child_cy_off * (1.0 - dclamp(blob_a_h / pill_h_eff, 0.5, 1.0)))
                }
            }
          }),
        )
        |> ignore
      }
      @signals.set_owner(prev_owner) |> ignore
      let restored = Ref(false)
      let restore_trig = fn() {
        if restored.val || trig.morph_owner != my_owner {
          return
        }
        restored.val = true
        trig.morph_cancel = None
        match cancel_close_delay.val {
          Some(c) => {
            cancel_close_delay.val = None
            c()
          }
          None => ()
        }
        match cancel_restore.val {
          Some(c) => {
            cancel_restore.val = None
            c()
          }
          None => ()
        }
        let (sp, ly) = trig.fx.get()
        if ly == pill_layer || ly < 0 {
          trig.morph_glass.val = None
          trig.morph_shadow.val = None
          trig.fx.set((sp, 0))
        }
        if trig.pill.alive() {
          if pm.has_press_scale {
            let prev = @signals.set_owner(None)
            trig.pill.scale(By(fn() { 1.0 + 0.05 * trig.press_way.shown(trig.pill) }), about=At(0.5, 0.5)) |> ignore
            @signals.set_owner(prev) |> ignore
          } else {
            trig.pill.scale(Is(1.0), about=At(0.5, 0.5)) |> ignore
          }
          trig.pill.offset(Is((0.0, 0.0))) |> ignore
          trig.pill.ground_drawn(Is(@view.ground_as_laid)) |> ignore
          trig.pill.alpha(Is(1.0)) |> ignore
        }
        for child in bound_children {
          if child.alive() {
            child.alpha(Is(1.0)) |> ignore
            child.offset(Is((0.0, 0.0))) |> ignore
          }
        }
      }
      layer.owns(fn() {
        if !is_closing.untracked() || superseded.untracked() || !trig.pill.alive() {
          restore_trig()
        }
      })
      |> ignore
      let open_go = fn() {
        if trig.morph_owner != my_owner || superseded.untracked() || layer.leaving() {
          return
        }
        t_way.go_from(
          layer,
          0.0,
          @glass.lm_open_duration_ms / 1000.0,
          @motion.tween(@glass.lm_open_duration_ms, ease=@ui.Ease::Linear),
        )
      }
      let start_close = fn(at_ms : Double) {
        if trig.morph_owner != my_owner || superseded.untracked() {
          return
        }
        let t_open_now = t_way.value_at(at_ms)
        let (_, _, mw, _) = pill_morph_shell_bounds(pm)
        pm.close_start.val = if t_open_now >= @glass.lm_open_duration_ms / 1000.0 - 0.001 {
          1.0
        } else {
          let u_open = @glass.lm_open_progress(t_open_now)
          let open_w = @glass.lm_lerp(core, mw, @dmath.pow(dclamp(u_open, 0.0, 1.0), 0.72))
          let target_w_ratio = if mw > 0.0 { dclamp(open_w / mw, 0.20, 1.0) } else { u_open }
          let target_s = @dmath.pow(target_w_ratio, 1.0 / 0.92)
          dclamp((target_s - 0.20) / 0.80, 0.05, 1.0)
        }
        is_closing.set(true)
        if trig.pill.alive() {
          let (sp, _) = trig.fx.get()
          trig.fx.set((sp, pill_layer))
          t_way.go_from(
            trig.pill,
            0.0,
            @glass.lm_close_duration_ms / 1000.0,
            @motion.tween(@glass.lm_close_duration_ms, ease=@ui.Ease::Linear),
            at=at_ms,
          )
          // (with motion reduced the close is over as it starts: the pill put back then, not a moment after)
          let close_ms = @motion.motion_ms(@glass.lm_close_duration_ms + 1.0)
          if close_ms <= 0.0 {
            restore_trig()
          } else {
            cancel_restore.val = Some(trig.pill.at_moment(at_ms + close_ms, fn() { restore_trig() }))
          }
        } else {
          t_way.go_from(
            layer,
            0.0,
            @glass.lm_close_duration_ms / 1000.0,
            @motion.tween(@glass.lm_close_duration_ms, ease=@ui.Ease::Linear),
            at=at_ms,
          )
        }
      }
      layer.reacts(fn() { layer.leaving() }, fn(leaving) {
        if trig.morph_owner != my_owner || superseded.untracked() {
          return
        }
        if leaving {
          let cause = layer.cause_at()
          let t_open = t_way.value_at(cause)
          let settle_delay_ms = @motion.motion_ms(if t_open < 0.23 { dmin(180.0, (0.23 - t_open) * 1000.0) } else { 0.0 })
          layer_leave_end.val = cause + settle_delay_ms + @motion.motion_ms(300.0)
          if settle_delay_ms <= 0.0 {
            start_close(cause)
          } else {
            let start_at = cause + settle_delay_ms
            let timer_host = if trig.pill.alive() { trig.pill } else { layer }
            cancel_close_delay.val = Some(
              timer_host.at_moment(start_at, fn() {
                cancel_close_delay.val = None
                start_close(start_at)
              }),
            )
          }
        } else {
          match start_open {
            Some(f) => f(open_go)
            None => open_go()
          }
        }
      })
      layer.lends(pill_morph_lent, pm) |> ignore
      // Dynamic leave-hold sentinel: holds layer only through settle_delay + 300ms (after platter_active ends at ~285ms),
      // while trig.pill continues the 300..610ms recoil return and splash independently before restore_trig().
      layer.box(made_for=loc, fn(hold) {
        hold
        .over(Is(true))
        .points(Is(false))
        .width(Is(Some(0.0)))
        .height(Is(Some(0.0)))
        .moved_by(
          fn(_, _, _) { (0.0, 0.0) },
          fn(_, _) {
            if superseded.get() {
              0.0
            } else if layer_leave_end.val > 0.0 {
              layer_leave_end.val
            } else {
              t_way.ends_at()
            }
          },
          holds_leaving=true,
        )
        |> ignore
      })
      |> ignore
    }
    None => ()
  }
}

///|
/// Configures `p` as the shared visual shell for an anchored popover beside `anchor_id`:
/// single-layer liquid glass (`glass_menu()`), solid hairline fallback when `p.glass_solid()` is true,
/// outside-only `glass_overlay_shadow()`, `r_menu` corner radius, clipping, `FromBeside` alpha/scale motion from `look`
/// (or full 1:1 iOS 27.0 `LiquidMorphPhysics` when `menu_node` is anchored to `bar_pill_group_node`), and
/// `ground_node` press boundary.
/// - `holds_side`: keeps the chosen side while it still fits (default `true`; pass `false` for `menu_node`).
/// - `concentric_inset`: when `>= 0.0`, registers `corner_card_node(p, fn() { r_menu }, inset=fn() { concentric_inset })`.
pub fn anchored_popover_shell(
  p : @view.View,
  anchor_id : @view.NodeId,
  look : () -> @ui.Look,
  side? : @ui.Side = Bottom,
  along? : @ui.Along = Start,
  offset? : Double = panel_offset,
  holds_side? : Bool = true,
  concentric_inset? : Double = -1.0,
) -> @view.View {
  anchored_popover_shell_by(p, anchor_id, look, side~, along~, offset~, holds_side~, concentric_inset~)
}

///|
fn anchored_popover_shell_by(
  p : @view.View,
  anchor_id : @view.NodeId,
  look : () -> @ui.Look,
  side? : @ui.Side = Bottom,
  along? : @ui.Along = Start,
  offset? : Double = panel_offset,
  holds_side? : Bool = true,
  lock_side? : () -> Bool,
  concentric_inset? : Double = -1.0,
  host? : @view.NodeId,
) -> @view.View {
  floating_host_lend(p)
  let (eff_offset, eff_along_offset) = match p.lent(pill_morph_lent) {
    Some(pm) => {
      pm.shell_ref.val = Some(p)
      let off = match side {
        Bottom | Top => -(pm.ah + pm.pill_pad)
        Left | Right => -(pm.aw + pm.pill_pad)
      }
      let aoff = match along {
        End => pm.pill_pad
        Start => -pm.pill_pad
        Middle => 0.0
      }
      (off, aoff)
    }
    _ => (offset, 0.0)
  }
  let eff_host = if p.lent(pill_morph_lent) is Some(_) { None } else { host }
  p
  .beside(
    anchor_id,
    side~,
    along=view_along(along),
    offset=eff_offset,
    along_offset=eff_along_offset,
    padding=floating_viewport_pad,
    holds_side~,
    host?=eff_host,
  )
  |> ignore
  match lock_side {
    Some(f) => p.beside_lock_side(f) |> ignore
    None => ()
  }
  match p.lent(pill_morph_lent) {
    Some(pm) =>
      @glass.liquid_popover_surface_decorate(
        p,
        radius=r_menu,
        solid=panel_ground,
        shadow=glass_overlay_shadow,
        solid_edge=fn() { (1.0, panel_edge()) },
        alpha=fn() { look().alpha },
        scale=fn() { look().sx },
        scale_about=FromBeside,
        max_shift=pop_max_shift,
        morph=fn() {
          if pm.superseded.get() {
            return Some(
              (
                0.0,
                true,
                1.0,
                1.0,
                {
                  mx: 0.0,
                  my: 0.0,
                  cur_w: 1.0,
                  cur_h: 1.0,
                  radius: 0.0,
                  raw_value: 0.0,
                  push_dx: 0.0,
                  push_dy: 0.0,
                  platter_active: false,
                  content_opacity: 0.0,
                  content_blur: 0.0,
                  final_dx: 0.0,
                  final_dy: 0.0,
                  open_anchor_scale: 0.0,
                  blob_a_emerge: 0.0,
                },
              ),
            )
          }
          let t = pm.t_way.shown(p)
          let closing = pm.is_closing.get()
          let (px_win, py_win, w, h) = p.placed_window_now()
          let f = pill_morph_eval(pm, px_win, py_win, dmax(w, 1.0), dmax(h, 1.0), closing, t)
          Some((t, closing, w, h, f))
        },
        layer=pm.pill_layer,
        break_gap=32.0,
        close_break_gap=24.0,
      )
      |> ignore
    _ =>
      @glass.liquid_popover_surface_decorate(
        p,
        radius=r_menu,
        solid=panel_ground,
        shadow=glass_overlay_shadow,
        solid_edge=fn() { (1.0, panel_edge()) },
        alpha=fn() { look().alpha },
        scale=fn() { look().sx },
        scale_about=FromBeside,
        max_shift=pop_max_shift,
      )
      |> ignore
  }
  if concentric_inset >= 0.0 {
    corner_card_node(p, fn() { r_menu }, inset=fn() { concentric_inset })
  }
  ground_node(p)
}

///|
/// Preferred side (`Top` or `Bottom`) for an anchored popover beside `anchor`: opens upward when space below `anchor`
/// is smaller than `need` and there is more room above than below.
pub fn beside_side_for(anchor : @view.View, need? : Double = 360.0) -> @ui.Side {
  let (_, y, _, h) = anchor.placed_window_now()
  let under = anchor.window_h() - (y + h)
  if under < need && y > under {
    Top
  } else {
    Bottom
  }
}
