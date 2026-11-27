// Unified floating Liquid Glass pill container (`liquid_pill_group_node`) and press-scope helpers.
// Single-layer iOS 27 Glass::liquid on the outer capsule; inner controls use concentric translucent highlights
// (zero glass-on-glass) and share `liquid_pill_trigger_lent` for private SDF fusion and in-place popover morphing.

///|
/// Layout axis for `liquid_pill_group_node` (horizontal top-bar pill vs. vertical floating pill).
#derive(Eq, Debug)
pub(all) enum PillDirection {
  Horizontal
  Vertical
}

///|
/// Shared press-feedback scope lent by `liquid_pill_group_node` to its interactive children
/// (`bind_pill_press` / `bind_pill_press_by`).
priv struct PillPressScope {
  pill : @view.View
  fx : @signals.Signal[((Double, Double)?, Int)]
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
  direction : PillDirection
  has_press_scale : Bool
  rest_glass : () -> @paint.Glass
}

///|
pub let liquid_pill_trigger_lent : @view.Lent[PillTriggerScope] = @view.Lent::new()

///|
/// Whether `child` sits inside a `liquid_pill_group_node` (shared glass pill capsule).
pub fn in_liquid_pill(child : @view.View) -> Bool {
  child.lent(pill_press_lent) is Some(_)
}

///|
/// Theme-adaptive press overlay ink for controls inside a liquid glass pill group.
pub fn liquid_pill_press_ink(solid? : Bool = false) -> Int64 {
  liquid_press_ink(solid~)
}

///|
/// Connects an interactive child control inside `liquid_pill_group_node` to its enclosing liquid
/// glass pill's press response: moves the GPU `spot` specular highlight to the child's center and
/// springs the outer pill scale via `@motion.backdrop_press_spring`. No-op outside a pill group.
pub fn bind_pill_press(child : @view.View) -> Unit {
  // (pressed by a hand in the window: not as every control is told at once (Tree::lit_all, a Tester's measure of the
  // looks), as a control's own sink is not (@motion.press_feel))
  bind_pill_press_by(child, fn() { child.pressed() && child.window_held() })
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
      scope.press_way.go(scope.pill, 1.0, @motion.backdrop_press_spring)
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
    let scope : PillPressScope = { pill: g, fx: fx_sig, press_way, count: 0 }
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
      direction,
      has_press_scale: true,
      rest_glass: fn() { make_glass(None, 0) },
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
    .scale(By(fn() { 1.0 + 0.05 * press_way.shown(g) }), about=At(0.5, 0.5), moves_besides=false)
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
