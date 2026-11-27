// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): catalog/components/LiquidToggle.kt. A track 64 × 28, a capsule
// going from the track's grey to green as its thumb goes across (Compose's lerp of colours: through Oklab); its thumb a
// white capsule 40 × 24, 2 in, dragged 20 from end to end. Held, the thumb turns to glass: its white and its blur (8)
// recede as its lens comes up (5 deep, bending by up to 10, the colours split), its Ambient highlight and its
// InnerShadow (4) with it, and it grows by half again (springs of 0.6 and 0.7 across and down), squeezed as it goes by
// how fast (DampedDragAnimation's velocity / 50). A tap turns it; a drag past half its way turns it there; Space and
// Enter, and a screen reader's Activate, turn it as mbui's headless switch does.
//
// The catalog's lens also sees the track itself scaled under it (a combined backdrop): mbui's glass sees what is drawn
// under it, the track as it is.

///|
/// The thumb's glass, held `p` (Native iOS 27.0 clear droplet loupe: zoom=1.0, chroma=0, concave moat pinch in shader).
fn toggle_glass(p : Double) -> @paint.Glass {
  let p = clamp(p, 0.0, 1.0)
  @paint.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=white,
    saturation=1.0,
    rim=1.0 * p,
    bezel=9.0 * p,
    refraction=9.0 * p,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
    zoom=1.0,
    droplet_role=2,
  )
}

///|
/// A LiquidToggle in `parent`, on while `on` says; turned (a tap, a drag past half its way, Space, Enter, Activate),
/// `turn` is told what it turns to. Read out a switch named `label`, on or off. The node.
#callsite(autofill(loc))
pub fn liquid_toggle_node(
  parent : @view.View,
  on : () -> Bool,
  turn : (Bool) -> Unit,
  label : () -> String,
  disabled? : () -> Bool = fn() { false },
  width? : Double = toggle_w,
  height? : Double = toggle_h,
  track_color? : () -> Int64,
  on_color? : () -> Int64,
  finger_only_lens? : Bool = false,
  controlled? : Bool = false,
  drag? : DampedDrag,
  loc~ : SourceLoc,
) -> @view.View {
  let pad = toggle_pad
  let th = dmax(4.0, height - 2.0 * pad)
  let tw = if width == toggle_w { thumb_w } else { width * thumb_w / toggle_w }
  let drag_dist = dmax(1.0, width - 2.0 * pad - tw)
  let was_on = @signals.untracked(on)
  let dd = match drag {
    Some(d) => d
    None =>
      DampedDrag::new(if was_on { 1.0 } else { 0.0 }, lo=0.0, hi=1.0, held_scale=thumb_held_scale)
  }
  // (fraction: where the hand has put it, 0 off to 1 on; did_drag: whether this hold moved it)
  let fraction = Ref(if was_on { 1.0 } else { 0.0 })
  let did_drag = Ref(false)
  // (where the hand went down across the window, and where it had it then: each move puts it where that point has
  // gone, so held past an end and brought back it leaves the end only as the hand reaches where it stopped)
  let from_x = Ref(0.0)
  let from_fraction = Ref(0.0)
  @headless.toggle(made_for=loc, parent, Switch, label, on, turn, disabled~, fn(v, sw) {
    dd.attach(v)
    let no_lens = fn() {
      v.glass_solid() || @ui.glass_material() != Liquid || (finger_only_lens && !(@ui.pointing() is Finger))
    }
    let lens = fn(n : @view.View) -> Double { if no_lens() { 0.0 } else { dd.pressed(n) } }
    v.width(Is(Some(width))).height(Is(Some(height))).shrink(Is(0.0)).alpha(By(fn() { if sw.disabled() { 0.5 } else { 1.0 } })) |> ignore
    // (turned by what is no hand: the keys, a screen reader, its caller; slides cleanly with 0 lens)
    v.reacts(at_start=false, on, fn(now) {
      let target = if now { 1.0 } else { 0.0 }
      if target != fraction.val {
        fraction.val = target
        dd.slide_to(target)
      }
    })
    // (the hand on it: mouse tap keeps 0 lens; mouse drag past slop or finger press lifts lens when !no_lens())
    let pressing_here = Ref(false)
    let cancel_to_authority = fn() {
      pressing_here.val = false
      did_drag.val = false
      let orig = if @signals.untracked(on) { 1.0 } else { 0.0 }
      fraction.val = orig
      from_fraction.val = orig
      if no_lens() {
        dd.drop_lens()
        dd.slide_to(orig)
      } else {
        dd.cancel_to(orig)
      }
    }
    let stopped = fn() {
      let prev = @signals.untracked(on)
      let had_lens = dd.pressing() || dd.has_pending_release()
      let requested = if did_drag.val { fraction.val >= 0.5 } else { !prev }
      did_drag.val = false
      if requested != prev {
        turn(requested)
      }
      if !v.alive() {
        return
      }
      let after = @signals.untracked(on)
      let settled = if after != prev || controlled { after } else { requested }
      let target = if settled { 1.0 } else { 0.0 }
      fraction.val = target
      if no_lens() {
        dd.drop_lens()
        dd.slide_to(target)
      } else if !had_lens {
        dd.slide_to(target)
      } else {
        dd.settle_to(target)
      }
    }
    v.gesture(
      @ui.touch_slop(),
      press=fn(d) {
        if sw.disabled() {
          return
        }
        pressing_here.val = true
        from_x.val = d.wx
        from_fraction.val = fraction.val
        did_drag.val = false
        if @ui.pointing() is Finger && !no_lens() {
          dd.press()
        }
      },
      tap=fn(_) {
        if !pressing_here.val {
          return
        }
        if sw.disabled() {
          cancel_to_authority()
          return
        }
        pressing_here.val = false
        stopped()
      },
      drag=fn(d) {
        if d.kind == Off {
          if pressing_here.val {
            cancel_to_authority()
          }
          return
        }
        if sw.disabled() {
          if pressing_here.val && d.kind == Up {
            cancel_to_authority()
          }
          return
        }
        match d.kind {
          // (from where it went down: the slop before a drag is the drag's too, as Compose's overSlop)
          Down | Moved => {
            if !pressing_here.val {
              return
            }
            let dx = d.wx - from_x.val
            if dx != 0.0 || d.kind == Down {
              did_drag.val = true
            }
            if !no_lens() && !dd.pressing() {
              dd.press()
            }
            fraction.val = clamp(from_fraction.val + dx / drag_dist, 0.0, 1.0)
            if no_lens() {
              dd.slide_to(fraction.val)
            } else {
              dd.update_value(fraction.val)
            }
          }
          Up =>
            if pressing_here.val {
              let dx = d.wx - from_x.val
              if !did_drag.val && dx.abs() <= @ui.touch_slop() {
                cancel_to_authority()
              } else {
                pressing_here.val = false
                if dx != 0.0 || did_drag.val {
                  did_drag.val = true
                  fraction.val = clamp(from_fraction.val + dx / drag_dist, 0.0, 1.0)
                }
                stopped()
              }
            }
          Off => ()
        }
      },
    )
    |> ignore
    v.box(fn(track) {
      track
      .over(Is(true))
      .radius(Is(height / 2.0))
      .ground(By(fn() {
        let off_c = match track_color {
          Some(f) => f()
          None => toggle_off_track()
        }
        let on_c = match on_color {
          Some(f) => f()
          None => colors().toggle_on
        }
        lerp_color(off_c, on_c, clamp(dd.value(track), 0.0, 1.0))
      }))
      |> ignore
    })
    |> ignore
    v.box(fn(thumb) {
      let thumb_shape = fn(n : @view.View) -> @view.GroundShape {
        let p = clamp(lens(n), 0.0, 1.0)
        let v = if no_lens() { 0.0 } else { (dd.velocity(n) / 50.0).abs() }
        let vel_sx = 1.0 / (1.0 - clamp(v * 0.75, 0.0, 0.2))
        let vel_sy = 1.0 - clamp(v * 0.25, 0.0, 0.2)
        let w = tw * lerp(1.0, thumb_held_scale, p) * vel_sx
        let h = th * lerp(1.0, thumb_held_scale, p) * vel_sy
        let x = lerp(pad, pad + drag_dist, dd.value(n))
        let r = h / 2.0
        {
          dx: x + (tw - w) / 2.0,
          dy: (height - h) / 2.0,
          dw: w - tw,
          dh: h - th,
          corners: Some((r, r, r, r)),
        }
      }
      thumb
      .over(Is(true))
      .width(Is(Some(tw)))
      .height(Is(Some(th)))
      .radius(Is(th / 2.0))
      .shadow(By(fn() { thumb_lift_shadow(clamp(lens(thumb), 0.0, 1.0)) }))
      .shadow_outside(Is(true))
      .ground_drawn(By(fn() { thumb_shape(thumb) }))
      |> ignore
      thumb.box(fn(solid) {
        solid
        .over(Is(true))
        .width(Is(Some(tw)))
        .height(Is(Some(th)))
        .radius(Is(th / 2.0))
        .ground(Is(white))
        .edge(By(fn() { (0.5, if is_dark() { 0xFFFFFF18L } else { 0x00000014L }) }))
        .alpha(By(fn() { clamp(1.0 - clamp(lens(solid), 0.0, 1.0) * 1.8, 0.0, 1.0) }))
        .ground_drawn(By(fn() { thumb_shape(solid) }))
        |> ignore
      })
      |> ignore
      // Lazy-mount the refraction loupe on first press so idle toggles allocate 0 extra nodes and
      // 0 hidden glass instances; keep mounted after release so settling triggers 0 Flex layouts.
      let lens_mounted : @signals.Signal[Bool] = @signals.signal(false)
      thumb.reacts(fn() { !no_lens() && (dd.pressing() || dd.pressed(thumb) > 0.001) }, fn(active) {
        if active && !lens_mounted.untracked() {
          lens_mounted.set(true)
        }
      })
      thumb.show(fn() { lens_mounted.get() }, at_once=true, fn(gl) {
        gl
        .over(Is(true))
        .points(Is(false))
        .width(Is(Some(tw)))
        .height(Is(Some(th)))
        .radius(Is(th / 2.0))
        .glass(By(fn() {
          let p = clamp(lens(gl), 0.0, 1.0)
          if p > 0.001 {
            Some(toggle_glass(p))
          } else {
            None
          }
        }))
        .alpha(By(fn() { clamp(lens(gl), 0.0, 1.0) }))
        .ground_drawn(By(fn() { thumb_shape(gl) }))
        |> ignore
      })
    })
    |> ignore
    // (the keyboard's focus on it: a ring round it in the accent)
    v.show(fn() { sw.focus_shown() }, fn(ring) {
      ring
      .over(Is(true))
      .margin(Is((-3.0, -3.0, -3.0, -3.0)))
      .radius(Is(height / 2.0 + 3.0))
      .edge(By(fn() { (2.0, colors().accent) }))
      |> ignore
    })
  })
}
