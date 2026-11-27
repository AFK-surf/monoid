// Single-layer iOS 27 Liquid Glass capsule decorators, elastic press-glass decorator,
// and progressive flat-to-lifted glass shell decorator.

///|
/// Material tone preset for `liquid_capsule_decorate`, `liquid_capsule_node`, and
/// `liquid_press_glass_decorate`.
#derive(Eq, Debug)
pub(all) enum LiquidCapsuleTone {
  Floating
  BarPill
  ViewerClear
  ViewerDark
  Panel
  Prominent
}

///|
fn capsule_tone_glass(
  tone : LiquidCapsuleTone,
  spot : (Double, Double)?,
  sol : Int64,
  custom_tint : Int64?,
  sharing : Bool,
) -> @paint.Glass {
  match tone {
    Floating => liquid_floating_glass(tint=custom_tint, solid=sol, spot~, sharing~)
    BarPill => {
      let g = liquid_bar_pill_glass(spot~, solid=sol, sharing~)
      match custom_tint {
        Some(c) => { ..g, tint: c }
        None => g
      }
    }
    ViewerClear => {
      let g = liquid_viewer_clear_glass(spot~, solid=sol, sharing~)
      match custom_tint {
        Some(c) => { ..g, tint: c }
        None => g
      }
    }
    ViewerDark => {
      let g = liquid_viewer_dark_glass(spot~, solid=sol, sharing~)
      match custom_tint {
        Some(c) => { ..g, tint: c }
        None => g
      }
    }
    Panel => {
      let g = maybe_sharing(liquid_panel_glass(solid=sol), sharing)
      let g = match spot {
        Some(_) => { ..g, spot }
        None => g
      }
      match custom_tint {
        Some(c) => { ..g, tint: c }
        None => g
      }
    }
    Prominent =>
      liquid_prominent_glass(
        accent=custom_tint.unwrap_or(colors().accent),
        spot~,
        solid=sol,
        sharing~,
      )
  }
}

///|
/// Decorates an existing `@view.View` as a single-layer iOS 27 Liquid Glass capsule or card and
/// returns it. When `active` returns `false`, emits `glass=None` and zero shadow (zero hidden
/// glass). Never nest inside another `Glass::liquid` surface.
pub fn liquid_capsule_decorate(
  v : @view.View,
  tone? : LiquidCapsuleTone = Floating,
  min_height? : Double? = None,
  radius? : Double? = None,
  sharing? : Bool = true,
  interactive? : Bool = false,
  solid? : () -> Int64,
  tint? : () -> Int64?,
  glass? : ((Double, Double)?) -> @paint.Glass,
  extra_blur? : () -> Double,
  active? : () -> Bool,
  shadow? : () -> (Double, Double, Int64),
  solid_edge? : () -> (Double, Int64),
  with_edge? : Bool = true,
  with_shadow? : Bool = true,
  clips? : Bool = true,
  trigger? : Bool = false,
) -> @view.View {
  if min_height is Some(h) {
    v.min_height(Is(Some(h))) |> ignore
  }
  if radius is Some(r) {
    v.radius(Is(r)) |> ignore
  }
  let is_active = fn() {
    match active {
      Some(f) => f()
      None => true
    }
  }
  if with_shadow {
    v.shadow_outside(Is(true)) |> ignore
  }
  let resolve_base_glass = fn(spot : (Double, Double)?) -> @paint.Glass {
    let base = match glass {
      Some(gf) => gf(spot)
      None => {
        let sol = match solid {
          Some(f) => f()
          None => clear
        }
        let custom_tint = match tint {
          Some(f) => f()
          None => None
        }
        capsule_tone_glass(tone, spot, sol, custom_tint, sharing)
      }
    }
    match extra_blur {
      Some(bf) => {
        let db = bf()
        if db > 0.0 {
          { ..base, blur: base.blur + db }
        } else {
          base
        }
      }
      None => base
    }
  }
  let resolve_shadow = fn() {
    if with_shadow {
      match shadow {
        Some(f) => f()
        None => shadow_default
      }
    } else {
      shadow_none
    }
  }
  let trig_opt : PillTriggerScope? = if trigger {
    let fx_sig : @signals.Signal[((Double, Double)?, Int)] = @signals.signal((None, 0))
    let morph_glass : Ref[(() -> @paint.Glass?)?] = Ref(None)
    let morph_shadow : Ref[(() -> (Double, Double, Int64))?] = Ref(None)
    let press_way = @motion.NodeWay::new(0.0)
    let children : Array[@view.View] = []
    let trig_scope : PillTriggerScope = {
      pill: v,
      fx: fx_sig,
      press_way,
      morph_glass,
      morph_shadow,
      morph_owner: 0,
      morph_cancel: None,
      children,
      height: min_height.unwrap_or(0.0),
      pad: 0.0,
      direction: Horizontal,
      has_press_scale: false,
      rest_glass: fn() { resolve_base_glass(None) },
    }
    v.lends(liquid_pill_trigger_lent, trig_scope) |> ignore
    Some(trig_scope)
  } else {
    None
  }
  v
  .sets_together(
    fn() {
      if !is_active() {
        return (None, (0.0, clear), shadow_none)
      }
      match trig_opt {
        Some(trig) => {
          let (_, ly) = trig.fx.get()
          if ly != 0 {
            let g = match trig.morph_glass.val {
              Some(mg) => mg()
              None => if ly < 0 { None } else { Some(resolve_base_glass(None)) }
            }
            let s = if with_shadow {
              match trig.morph_shadow.val {
                Some(ms) => ms()
                None => if ly < 0 { shadow_none } else { resolve_shadow() }
              }
            } else {
              shadow_none
            }
            return (g, (0.0, clear), s)
          }
        }
        None => ()
      }
      let spot = if interactive && v.pressed() && !v.glass_solid() {
        let (_, _, w, h) = v.placed_window_now()
        if w > 0.0 && h > 0.0 {
          Some((w / 2.0, h / 2.0))
        } else {
          None
        }
      } else {
        None
      }
      let resolved = resolve_base_glass(spot)
      let edge_val = if with_edge && v.glass_solid() {
        match solid_edge {
          Some(f) => f()
          None => liquid_solid_edge()
        }
      } else {
        (0.0, clear)
      }
      (Some(resolved), edge_val, resolve_shadow())
    },
    fn(look) {
      let (g, e, s) = look
      v.glass(Is(g)) |> ignore
      if with_edge {
        v.edge(Is(e)) |> ignore
      }
      if with_shadow {
        v.shadow(Is(s)) |> ignore
      }
    },
  )
  |> ignore
  if clips {
    v.clips(Is(true)) |> ignore
  }
  v
}

///|
/// Creates a child box in `parent`, decorates it with `liquid_capsule_decorate`, and runs `body`.
#callsite(autofill(loc))
pub fn liquid_capsule_node(
  parent : @view.View,
  body : (@view.View) -> Unit,
  tone? : LiquidCapsuleTone = Floating,
  min_height? : Double? = None,
  radius? : Double? = None,
  sharing? : Bool = true,
  interactive? : Bool = false,
  solid? : () -> Int64,
  tint? : () -> Int64?,
  extra_blur? : () -> Double,
  active? : () -> Bool,
  shadow? : () -> (Double, Double, Int64),
  solid_edge? : () -> (Double, Int64),
  clips? : Bool = true,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(v) {
    liquid_capsule_decorate(
      v,
      tone~,
      min_height~,
      radius~,
      sharing~,
      interactive~,
      solid?,
      tint?,
      extra_blur?,
      active?,
      shadow?,
      solid_edge?,
      clips~,
    )
    |> ignore
    body(v)
  })
}

///|
/// Decorates an interactive control `b` with an `InteractiveHighlight`-driven elastic scale,
/// touch-tracked GPU `spot` liquid glass, outside-only shadow, and `MBUI_GLASS=solid` hairline
/// edge. Returns the attached `InteractiveHighlight` so the caller's gesture handler drives
/// `down`, `moved`, and `up`.
pub fn liquid_press_glass_decorate(
  b : @view.View,
  tone? : LiquidCapsuleTone = Floating,
  sharing? : Bool = true,
  solid? : () -> Int64,
  tint? : () -> Int64?,
  shadow? : () -> (Double, Double, Int64),
  solid_edge? : () -> (Double, Int64),
  clips? : Bool = true,
  with_scale? : Bool = true,
  highlight? : InteractiveHighlight,
) -> InteractiveHighlight {
  let ih = match highlight {
    Some(h) => h
    None => InteractiveHighlight::new()
  }
  ih.attach(b)
  if with_scale {
    b
    .scale(
      By(fn() {
        let (_, _, sx, sy) = ih.stretch(b)
        (sx + sy) / 2.0
      }),
      about=At(0.5, 0.5),
      moves_besides=false,
    )
    |> ignore
  }
  b
  .glass(By(fn() {
    let spot = if !b.glass_solid() && ih.pressed(b) > 0.001 {
      let (_, _, bw, bh) = b.placed_window_now()
      if bw > 0.0 && bh > 0.0 {
        Some(ih.spot(b, bw, bh))
      } else {
        let (sw, sh) = ih.size.get()
        if sw > 0.0 && sh > 0.0 {
          Some(ih.spot(b, sw, sh))
        } else {
          None
        }
      }
    } else {
      None
    }
    let sol = match solid {
      Some(f) => f()
      None => clear
    }
    let custom_tint = match tint {
      Some(f) => f()
      None => None
    }
    Some(capsule_tone_glass(tone, spot, sol, custom_tint, sharing))
  }))
  .edge(By(fn() {
    if b.glass_solid() {
      match solid_edge {
        Some(f) => f()
        None => liquid_solid_edge()
      }
    } else {
      (0.0, clear)
    }
  }))
  .shadow(By(fn() {
    match shadow {
      Some(f) => f()
      None => shadow_default
    }
  }))
  .shadow_outside(Is(true))
  |> ignore
  if clips {
    b.clips(Is(true)) |> ignore
  }
  ih
}

///|
/// Decorates container shell `v` to transition continuously between an optional flat surface
/// (`flat_ground`) and a lifted liquid glass surface (`glass`) as `lift()` moves across `[0, 1]`.
/// Emits `glass=None` and zero shadow at rest (`lift <= 0.001`) so idle shells have zero hidden glass.
#callsite(autofill(loc))
pub fn liquid_lift_shell_decorate(
  v : @view.View,
  lift : () -> Double,
  flat_ground? : (() -> Int64)? = None,
  glass? : () -> @paint.Glass = fn() { liquid_panel_glass() },
  solid? : () -> Int64,
  radius? : Double? = None,
  shadow? : () -> (Double, Double, Int64) = fn() { shadow_default },
  solid_edge? : () -> (Double, Int64),
  loc~ : SourceLoc,
) -> Unit {
  let t = fn() { clamp(lift(), 0.0, 1.0) }
  if radius is Some(r) {
    v.radius(Is(r), loc~) |> ignore
  }
  v
  .glass(
    By(fn() {
      let k = t()
      if k <= 0.001 {
        None
      } else {
        let base = glass()
        let resolved = match solid {
          Some(sf) => { ..base, solid: sf() }
          None => base
        }
        Some(resolved.at_strength(k))
      }
    }),
    loc~,
  )
  .shadow(
    By(fn() {
      let k = t()
      if k <= 0.001 {
        shadow_none
      } else {
        let (sigma, dy, color) = shadow()
        (sigma * k, dy * k, alpha(color, k))
      }
    }),
    loc~,
  )
  .shadow_outside(Is(true), loc~)
  |> ignore
  match solid_edge {
    Some(f) =>
      v
      .edge(
        By(fn() {
          let k = t()
          if k > 0.001 && v.glass_solid() {
            let (w, c) = f()
            (w, alpha(c, k))
          } else {
            (0.0, clear)
          }
        }),
        loc~,
      )
      |> ignore
    None => ()
  }
  match flat_ground {
    Some(fg) =>
      v
      .ground(
        By(fn() {
          let k = t()
          if k <= 0.001 {
            fg()
          } else {
            alpha(fg(), 1.0 - k)
          }
        }),
        loc~,
      )
      |> ignore
    None => ()
  }
}
