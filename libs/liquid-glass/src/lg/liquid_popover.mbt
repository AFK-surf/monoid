// Liquid Glass Popover and Tooltip components over `@headless.Popover` and `@headless.tooltip_bubble`.

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
    .points(Is(false))
    .max_width(Is(Some(ovl_tooltip_max_w)))
    .padding(Is((ovl_tooltip_px, ovl_tooltip_py, ovl_tooltip_px, ovl_tooltip_py)))
    .radius(Is(ovl_tooltip_radius))
    .shadow(Is(shadow_default))
    .shadow_outside(Is(true))
    .glass(
      By(fn() {
        let s = match solid {
          Some(f) => f()
          None => clear
        }
        Some(liquid_capsule_glass(solid=s))
      }),
    )
    .edge(By(fn() { if b.glass_solid() { liquid_overlay_solid_edge() } else { (0.0, clear) } }))
    |> ignore
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
