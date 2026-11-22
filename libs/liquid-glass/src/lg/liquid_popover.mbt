// Liquid Glass Popover and Tooltip components over `@headless.Popover` and `@headless.tooltip_bubble`.

///|
/// Helper forwarding `alpha` so `liquid_popover_surface_decorate` can accept an `alpha?` parameter without shadowing.
fn popover_fade_ink(c : Int64, share : Double) -> Int64 {
  alpha(c, share)
}

///|
/// Decorates an existing anchored popover container node `p` in place (zero wrapper nodes) in either:
/// 1. Standard anchored overlay mode (when `morph` is `None` or `p.glass_solid()` is true):
///    binds `liquid_panel_glass(solid=...)`, `shadow`, `shadow_outside(Is(true))`, `MBUI_GLASS=solid` hairline
///    fallback, and optional `alpha` / `scale`.
/// 2. iOS 27.0 liquid-bridge morph mode (when `morph` is `Some(eval)` and `!p.glass_solid()`):
///    encapsulates three-anchor `liquid_menu_morph_glass` optical interpolation, capillary `merge`/`layer`/`break_gap`,
///    `content_lens` blur/refraction, `ground_drawn` animated silhouette, `alpha` gating (zero hidden glass when
///    inactive), and smooth shadow ramp. Returns `p` for chaining.
pub fn liquid_popover_surface_decorate(
  p : @view.View,
  radius? : Double,
  solid? : () -> Int64,
  shadow? : () -> (Double, Double, Int64) = fn() { shadow_default },
  solid_edge? : () -> (Double, Int64) = liquid_overlay_solid_edge,
  clips? : Bool = true,
  alpha? : () -> Double,
  scale? : () -> Double,
  scale_about? : @view.Pivot = FromBeside,
  max_shift? : Double = 0.0,
  morph? : () -> (Double, Bool, Double, Double, LiquidMorphFrame)?,
  layer? : Int = 0,
  break_gap? : Double = 32.0,
  close_break_gap? : Double = 48.0,
) -> @view.View {
  let resolve_solid = fn() -> Int64 {
    match solid {
      Some(f) => f()
      None => clear
    }
  }
  match radius {
    Some(r) => p.radius(Is(r)) |> ignore
    None => ()
  }
  if clips {
    p.clips(Is(true)) |> ignore
  }
  p
  .edge(By(fn() { if p.glass_solid() { solid_edge() } else { (0.0, clear) } }))
  .shadow_outside(Is(true))
  |> ignore
  match morph {
    Some(eval_morph) if !p.glass_solid() =>
      p
      .alpha(
        By(fn() {
          match eval_morph() {
            Some((_, closing, _, _, f)) =>
              if !closing {
                if f.raw_value <= 0.001 { 0.0 } else { 1.0 }
              } else if !f.platter_active {
                0.0
              } else {
                1.0
              }
            None =>
              match alpha {
                Some(af) => af()
                None => 1.0
              }
          }
        }),
      )
      .glass(
        By(fn() {
          let s = resolve_solid()
          match eval_morph() {
            Some((t, closing, _, _, f)) =>
              if !closing {
                if f.raw_value <= 0.001 {
                  None
                } else {
                  let stage = 0.5 + 0.5 * lm_smoothstep(0.08, 0.20, t)
                  if f.open_anchor_scale > 0.15 {
                    Some(
                      liquid_menu_morph_glass(
                        stage,
                        solid=s,
                        merge=14.0 * f.open_anchor_scale,
                        layer~,
                        break_gap~,
                      ),
                    )
                  } else {
                    Some(liquid_menu_morph_glass(stage, solid=s))
                  }
                }
              } else if !f.platter_active {
                None
              } else {
                let stage = 0.5 * lm_smoothstep(0.0, 0.12, f.raw_value) +
                  0.5 * lm_smoothstep(0.35, 0.95, f.raw_value)
                if f.blob_a_emerge > 0.001 {
                  Some(
                    liquid_menu_morph_glass(
                      stage,
                      solid=s,
                      merge=lm_close_blend(f.raw_value),
                      layer~,
                      break_gap=close_break_gap,
                    ),
                  )
                } else {
                  Some(liquid_menu_morph_glass(stage, solid=s))
                }
              }
            None => Some(liquid_panel_glass(solid=s))
          }
        }),
      )
      .content_lens(
        By(fn() {
          match eval_morph() {
            Some((_, _, _, _, f)) =>
              if f.content_opacity > 0.01 && f.content_blur > 0.05 {
                {
                  blur: f.content_blur,
                  refraction: 6.0 * clamp(f.content_blur / 8.0, 0.0, 1.0),
                  bezel: 24.0,
                  alpha: f.content_opacity,
                }
              } else {
                @paint.ContentLens::none()
              }
            None => @paint.ContentLens::none()
          }
        }),
      )
      .shadow(
        By(fn() {
          match eval_morph() {
            Some((_, closing, _, _, f)) =>
              if closing && !f.platter_active {
                shadow_none
              } else {
                let ga = lm_smoothstep(0.25, 0.78, clamp(f.raw_value, 0.0, 1.0))
                if ga <= 0.001 {
                  shadow_none
                } else {
                  let (s, dy, ink) = shadow()
                  (s, dy, popover_fade_ink(ink, ga))
                }
              }
            None => shadow()
          }
        }),
      )
      .ground_drawn(
        By(fn() {
          match eval_morph() {
            Some((t, closing, w, h, f)) =>
              if w <= 0.0 || h <= 0.0 || (!closing && t >= lm_open_duration_ms / 1000.0 - 0.001) {
                @view.ground_as_laid
              } else {
                let r = f.radius
                { dx: f.mx, dy: f.my, dw: f.cur_w - w, dh: f.cur_h - h, corners: Some((r, r, r, r)) }
              }
            None => @view.ground_as_laid
          }
        }),
      )
    _ => {
      p.glass(By(fn() { Some(liquid_panel_glass(solid=resolve_solid())) })).shadow(By(shadow)) |> ignore
      match alpha {
        Some(af) => p.alpha(By(af)) |> ignore
        None => ()
      }
      match scale {
        Some(sf) => p.scale(By(sf), about=scale_about, max_shift~) |> ignore
        None => ()
      }
      p
    }
  }
}

///|
/// Decorates an existing tooltip node `v` in place (zero wrapper nodes) with `points(Is(false))` click-through,
/// `active` gating (submits `None` glass, zero edge, and zero shadow when inactive), `shadow_outside(Is(true))`,
/// `MBUI_GLASS=solid` hairline fallback, and single-layer liquid glass (`liquid_capsule_glass` by default, or
/// `liquid_panel_glass` when `panel=true`). Returns `v` for chaining.
pub fn liquid_tooltip_surface_decorate(
  v : @view.View,
  radius? : Double,
  active? : () -> Bool = fn() { true },
  solid? : () -> Int64,
  shadow? : () -> (Double, Double, Int64) = fn() { shadow_default },
  solid_edge? : () -> (Double, Int64) = liquid_overlay_solid_edge,
  panel? : Bool = false,
) -> @view.View {
  match radius {
    Some(r) => v.radius(Is(r)) |> ignore
    None => ()
  }
  v
  .points(Is(false))
  .glass(
    By(fn() {
      if !active() {
        return None
      }
      let s = match solid {
        Some(f) => f()
        None => clear
      }
      if panel {
        Some(liquid_panel_glass(solid=s))
      } else {
        Some(liquid_capsule_glass(solid=s))
      }
    }),
  )
  .edge(
    By(fn() {
      if active() && v.glass_solid() {
        solid_edge()
      } else {
        (0.0, clear)
      }
    }),
  )
  .shadow(
    By(fn() {
      if active() {
        shadow()
      } else {
        shadow_none
      }
    }),
  )
  .shadow_outside(Is(true))
}

///|
/// A Liquid Glass popover: trigger in `parent`, floating glass card mounted in `host` beside
/// the trigger according to `placement`. Closes on Escape or outside press via `@headless.Popover`.
#callsite(autofill(loc))
pub fn liquid_popover_node(
  parent : @view.View,
  host : @view.View,
  open : () -> Bool,
  set_open : (Bool) -> Unit,
  trigger_label : () -> String,
  trigger_look : (@view.View, @headless.Disclosure) -> Unit,
  content_label : () -> String,
  content_look : (@view.View) -> Unit,
  placement? : @headless.Placement = BelowCenter,
  width? : Double = 280.0,
  anchor_size? : (Double, Double) = (40.0, 40.0),
  trigger_face? : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let shown_open = ovl_transitioned_bool(host, open)
  let set_open_tx = fn(v : Bool) { @view.transition(within=host, fn() { set_open(v) }) }
  let pop = @headless.Popover::new(shown_open, set_open_tx)
  let (side, along) = ovl_beside_of(placement)
  let trigger = pop.trigger(parent, trigger_label, trigger_look, made_for=loc)
  let handoff = ovl_setup_trigger_handoff(trigger, shown_open, side, anchor_size, trigger_face)
  pop.layer(
    host,
    content_label,
    leave=ovl_morph_leave_ms,
    made_for=loc,
    fn(v, opener) {
      match opener {
        Some(op) => v.beside(op.id(), side~, along~, offset=ovl_float_gap, padding=ovl_float_pad) |> ignore
        None => ()
      }
      v.width(Is(Some(width))) |> ignore
      ovl_attach_liquid_morph(v, v, side, along, ovl_popover_radius, handoff, fn(content_box) {
        content_box
        .padding(Is((ovl_popover_pad, ovl_popover_pad, ovl_popover_pad, ovl_popover_pad)))
        |> ignore
        content_look(content_box)
      })
      |> ignore
    },
  )
  trigger
}

///|
/// Reusable single-layer Liquid Glass tooltip capsule (`r=12pt`, `points(Is(false))`, `shadow_outside(Is(true))`,
/// `MBUI_GLASS=solid` 1pt edge fallback, optional concentric shortcut keycap badge) shared by `liquid_tooltip_node`
/// and external global tooltip layers.
#callsite(autofill(loc))
pub fn liquid_tooltip_bubble_node(
  parent : @view.View,
  text : () -> String,
  shortcut? : () -> String = fn() { "" },
  solid? : () -> Int64,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    b
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .gap(Is(8.0))
    .max_width(Is(Some(ovl_tooltip_max_w)))
    .padding(Is((ovl_tooltip_px, ovl_tooltip_py, ovl_tooltip_px, ovl_tooltip_py)))
    |> ignore
    liquid_tooltip_surface_decorate(b, radius=ovl_tooltip_radius, solid?) |> ignore
    b.box(fn(w) {
      w.shrink(Is(1.0)).words(By(text), look=words_at(ovl_type_sub, wrap=true)).ink(By(fn() { colors().content }))
      |> ignore
    })
    |> ignore
    b.show(fn() { shortcut() != "" }, fn(kbd) {
      kbd
      .shrink(Is(0.0))
      .padding(Is((6.0, 2.0, 6.0, 2.0)))
      .radius(Is(ovl_tooltip_radius - ovl_tooltip_py))
      .ground(By(ovl_close_ground))
      |> ignore
      kbd.box(fn(kw) {
        kw.words(By(shortcut), look=words_at(ovl_type_meta, weight=weight_medium)).ink(By(ovl_muted_ink)) |> ignore
      })
      |> ignore
    })
  })
}

///|
/// A Liquid Glass tooltip: wraps `trigger_look` in `parent` and floats a refractive capsule
/// (`r=12pt`, `points(Is(false))`, zero click occlusion, optional shortcut badge) in `host` on hover or keyboard focus.
#callsite(autofill(loc))
pub fn liquid_tooltip_node(
  parent : @view.View,
  host : @view.View,
  tip : () -> String,
  trigger_look : (@view.View) -> Unit,
  placement? : @headless.Placement = AboveCenter,
  shortcut? : () -> String = fn() { "" },
  loc~ : SourceLoc,
) -> @view.View {
  let shown : @signals.Signal[Int?] = @signals.signal(None)
  let group = @headless.TooltipGroup::new(fn() { shown.get() }, fn(v) { shown.set(v) })
  let (side, along) = ovl_beside_of(placement)
  let anchor_ref : Ref[@view.View?] = Ref(None)
  let trigger = parent.box(made_for=loc, fn(t) {
    anchor_ref.val = Some(t)
    t.points(Is(true)) |> ignore
    trigger_look(t)
    group.trigger(t, 0)
    // Also react when pointer or keyboard focus lands on a child control inside `trigger_look`.
    let pending : Ref[() -> Unit] = Ref(fn() {  })
    let cancel_pending = fn() {
      (pending.val)()
      pending.val = fn() {  }
    }
    t.reacts(
      fn() { (t.pointed_in(), t.pointed(), t.focus_shown()) },
      at_start=false,
      fn(st) {
        let (in_sub, direct, focused) = st
        cancel_pending()
        if focused {
          shown.set(Some(0))
        } else if in_sub && !direct {
          let at = t.cause_at()
          pending.val = t.at_moment(at + @headless.tooltip_delay_ms, fn() {
            pending.val = fn() {  }
            if @signals.untracked(fn() { t.pointed_in() }) {
              shown.set(Some(0))
            }
          })
        } else if !in_sub && !direct && !focused {
          if shown.untracked() == Some(0) {
            shown.set(None)
          }
        }
      },
    )
    t.owns(cancel_pending) |> ignore
  })
  let tip_open = ovl_transitioned_bool(host, fn() { group.is_open(0) && tip() != "" })
  host.show(
    tip_open,
    leave=@motion.tip_out_ms,
    fn(s) {
      @headless.tooltip_bubble(s, tip, made_for=loc, fn(b) {
        let (look, _) = @motion.overlay_presence(b, enter=@motion.tip_in, exit=@motion.tip_out)
        match anchor_ref.val {
          Some(op) => b.beside(op.id(), side~, along~, offset=ovl_float_gap, padding=ovl_float_pad) |> ignore
          None => ()
        }
        b
        .points(Is(false))
        .alpha(By(fn() { look().alpha }))
        .scale(By(fn() { look().sx }), about=FromBeside)
        |> ignore
        liquid_tooltip_bubble_node(b, tip, shortcut~, loc~) |> ignore
      })
      |> ignore
    },
  )
  trigger
}
