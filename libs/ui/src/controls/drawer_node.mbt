// Universal floating liquid-glass side drawer (`drawer_node`), iOS 26 style: a floating rounded liquid-glass island
// inset on all four sides (`DrawerSpec::inset`), anchored to the leading or trailing edge, backed by `@headless.dialog`
// for focus, Escape, system back, and outside-press dismissal, with 1:1 horizontal drag-to-dismiss, asymptotic
// rubber-band over-pull (max 16pt), and velocity-continuous `@motion.move_damped` springs.

///|
/// Which edge of the window a `drawer_node` slides in from.
#derive(Eq, Debug)
pub(all) enum DrawerSide {
  Leading
  Trailing
}

///|
/// Geometry and backdrop configuration for `drawer_node`.
#derive(Eq, Debug)
pub(all) struct DrawerSpec {
  side : DrawerSide
  width : Double
  inset : Double
  radius : Double
  scrim : Bool
}

///|
/// Default floating side drawer geometry (`Leading`, 300pt wide, 10pt inset, `pane_corner` radius, light scrim on).
pub fn DrawerSpec::default() -> DrawerSpec {
  { side: Leading, width: 300.0, inset: 10.0, radius: pane_corner, scrim: true }
}

///|
/// Scrim colour behind a floating side drawer at rest: black at ~18%.
let drawer_scrim : Int64 = 0x0000002EL

///|
/// Maximum asymptotic rubber-band over-pull (dp) when dragging past the open stop.
let drawer_rubber_max : Double = 16.0

///|
/// Fraction of drawer width dragged toward its edge that commits dismissal on release.
let drawer_close_share : Double = 0.32

///|
/// Closing fling velocity threshold (pt/ms) that commits dismissal on release.
let drawer_close_speed : Double = 0.45

///|
/// A universal floating liquid-glass side drawer in `parent`, open while `open()` holds.
///
/// Built once as nodes with `@headless.drawer` (focus management, Escape, `takes_back`, outside-press close,
/// 1:1 horizontal drag-to-dismiss, rubber-band over-pull, and reverse-fling guard), single-layer `glass_sheet()`
/// with `.shadow_outside(Is(true))` (degrading cleanly to `panel_ground()` + 1pt `panel_edge()` under
/// `MBUI_GLASS=solid`), continuous scrim fading, and velocity-continuous `@motion.move_damped` spring settle.
#callsite(autofill(loc))
pub fn drawer_node(
  parent : @view.View,
  open : () -> Bool,
  label : () -> String,
  on_close : () -> Unit,
  body : (@view.View) -> Unit,
  spec? : DrawerSpec = DrawerSpec::default(),
  loc~ : SourceLoc,
) -> Unit {
  let leave_ms = @ui.move_ms(spec.width + spec.inset)
  parent.show(open, leave=leave_ms, fn(layer) {
    let dir = match spec.side {
      Leading => -1.0
      Trailing => 1.0
    }
    let slide = @motion.NodeWay::new(1.0)
    let leave_speed : Ref[Double] = Ref(0.0)
    let drawer_ref : Ref[@headless.Drawer?] = Ref(None)
    let card_ref : Ref[@view.View?] = Ref(None)
    let eff_w = fn() { dmin(spec.width, dmax(0.0, layer.window_w() - 2.0 * spec.inset)) }
    let travel = fn() { dmax(1.0, eff_w() + spec.inset) }
    let progress = fn(n : @view.View) {
      match drawer_ref.val {
        Some(dr) if dr.dragging() => dclamp(dmin(dr.drag_offset(), travel()) / travel(), -1.0, 1.0)
        _ => slide.shown(n)
      }
    }
    let dismiss = fn() {
      if !layer.leaving() && @signals.untracked(open) {
        on_close()
      }
    }
    layer.reacts(fn() { layer.leaving() }, fn(going) {
      if going {
        let v = leave_speed.val
        leave_speed.val = 0.0
        slide.go(layer, 1.0, @motion.move_damped, velocity=v)
      } else {
        slide.go(layer, 0.0, @motion.move_damped)
      }
    })
    layer
    .over(Is(true))
    .row(Is(true))
    .ground(By(fn() {
      if !spec.scrim {
        0L
      } else {
        let vis = dclamp(1.0 - progress(layer), 0.0, 1.0)
        @ui.alpha(drawer_scrim, vis)
      }
    }))
    |> ignore
    if spec.side == Trailing {
      layer.box(fn(sp) { sp.grow(Is(1.0)) |> ignore }) |> ignore
    }
    @headless.drawer(
      made_for=loc,
      layer,
      label,
      fn() { !layer.leaving() && open() },
      dismiss,
      edge=if spec.side == Leading { Left } else { Right },
      modal=true,
      dismiss_threshold=drawer_close_share,
      velocity_threshold=drawer_close_speed * 1000.0,
      overpull_max=drawer_rubber_max,
      on_release=fn(off, vel_ps, will_close) {
        let tr = @signals.untracked(travel)
        let dx = dmin(off, tr)
        let vel_ratio = vel_ps / tr
        if will_close {
          slide.put(dclamp(dx / tr, 0.0, 1.0))
          leave_speed.val = dmax(0.0, vel_ratio)
        } else {
          slide.put(dx / tr)
          if card_ref.val is Some(card) {
            slide.go(card, 0.0, @motion.move_damped, velocity=vel_ratio)
          }
        }
      },
      fn(card, dr) {
        drawer_ref.val = Some(dr)
        card_ref.val = Some(card)
        corner_card_node(card, fn() { spec.radius }, inset=fn() { spec.inset })
        card
        .width(By(fn() { Some(eff_w()) }))
        .height(By(fn() { Some(dmax(0.0, layer.window_h() - 2.0 * spec.inset)) }))
        .margin(Is((spec.inset, spec.inset, spec.inset, spec.inset)))
        |> ignore
        @glass.liquid_drawer_surface_decorate(
          card,
          radius=spec.radius,
          solid=panel_ground,
          shadow=glass_overlay_shadow,
          solid_edge=fn() { (1.0, panel_edge()) },
          clips=true,
        )
        .offset(By(fn() {
          let dx = if dr.dragging() {
            dmin(dr.drag_offset(), travel())
          } else {
            slide.shown(card) * travel()
          }
          (dir * dx, 0.0)
        }))
        |> ignore
        card.box(fn(content) {
          content.grow(Is(1.0)).cursor(Is(Some(Arrow))).as_ground() |> ignore
          dr.handle(content, extent_by=eff_w)
          body(content)
        })
        |> ignore
      },
    )
    |> ignore
  })
}
