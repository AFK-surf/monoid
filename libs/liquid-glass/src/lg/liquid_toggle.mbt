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
/// The thumb's glass, held `p` (iOS 27 clear loupe).
fn toggle_glass(p : Double) -> @paint.Glass {
  let p = clamp(p, 0.0, 1.0)
  @paint.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=white,
    saturation=1.0,
    rim=0.6 * p,
    bezel=8.0 * p,
    refraction=12.0 * p,
    chroma=-0.06 * p,
    merge=0.0,
    adaptive=false,
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
  drag? : DampedDrag,
  loc~ : SourceLoc,
) -> @view.View {
  let was_on = @signals.untracked(on)
  let dd = match drag {
    Some(d) => d
    None =>
      DampedDrag::new(if was_on { 1.0 } else { 0.0 }, lo=0.0, hi=1.0, held_scale=thumb_held_scale)
  }
  // (fraction: where the hand has put it, 0 off to 1 on; did_drag: whether this hold moved it)
  let fraction = Ref(if was_on { 1.0 } else { 0.0 })
  let did_drag = Ref(false)
  let last_x = Ref(0.0)
  @headless.toggle(made_for=loc, parent, Switch, label, on, turn, disabled~, fn(v, sw) {
    dd.attach(v)
    v.width(Is(Some(toggle_w))).height(Is(Some(toggle_h))).shrink(Is(0.0)).alpha(By(fn() { if sw.disabled() { 0.5 } else { 1.0 } })) |> ignore
    // (turned by what is no hand: the keys, a screen reader, its caller; sent there as by a hand pressed and let go)
    v.reacts(at_start=false, on, fn(now) {
      let target = if now { 1.0 } else { 0.0 }
      if target != fraction.val {
        fraction.val = target
        dd.animate_to(target)
      }
    })
    // (the hand on it: held as it goes down, let go as it comes up; a tap turns it, a drag moves it 20 a whole way)
    let stopped = fn() {
      if did_drag.val {
        fraction.val = if dd.target() >= 0.5 { 1.0 } else { 0.0 }
        did_drag.val = false
      } else {
        fraction.val = if on() { 0.0 } else { 1.0 }
      }
      dd.update_value(fraction.val)
      let now = fraction.val == 1.0
      if now != on() {
        turn(now)
      }
      dd.release()
    }
    v.gesture(
      @ui.touch_slop(),
      press=fn(d) {
        if sw.disabled() {
          return
        }
        last_x.val = d.wx
        dd.press()
      },
      tap=fn(_) { if !sw.disabled() { stopped() } },
      drag=fn(d) {
        if sw.disabled() {
          return
        }
        match d.kind {
          // (from where it went down: the slop before a drag is the drag's too, as Compose's overSlop)
          Down => ()
          Moved => {
            let dx = d.wx - last_x.val
            last_x.val = d.wx
            if dx != 0.0 {
              did_drag.val = true
            }
            fraction.val = clamp(fraction.val + dx / toggle_drag, 0.0, 1.0)
            dd.update_value(fraction.val)
          }
          Up => stopped()
          Off => {
            did_drag.val = false
            dd.release()
          }
        }
      },
    )
    |> ignore
    v.box(fn(track) {
      track
      .over(Is(true))
      .radius(Is(toggle_h / 2.0))
      .ground(By(fn() {
        let c = colors()
        lerp_color(c.track, c.toggle_on, clamp(dd.value(track), 0.0, 1.0))
      }))
      |> ignore
    })
    |> ignore
    v.box(fn(thumb) {
      let size = fn() {
        let (sx, sy) = dd.jelly(thumb, 50.0)
        (thumb_w * sx, thumb_h * sy)
      }
      thumb
      .over(Is(true))
      .width(By(fn() { Some(size().0) }))
      .height(By(fn() { Some(size().1) }))
      .radius(By(fn() { size().1 / 2.0 }))
      .offset(By(fn() {
        let (w, h) = size()
        let x = lerp(toggle_pad, toggle_pad + toggle_drag, dd.value(thumb))
        (x + (thumb_w - w) / 2.0, (toggle_h - h) / 2.0)
      }))
      .shadow(Is(shadow_thumb))
      |> ignore
      thumb.box(fn(solid) {
        solid
        .over(Is(true))
        .radius(By(fn() { size().1 / 2.0 }))
        .ground(Is(white))
        .alpha(By(fn() { 1.0 - clamp(dd.pressed(solid), 0.0, 1.0) }))
        |> ignore
      })
      |> ignore
      thumb.box(fn(gl) {
        gl
        .over(Is(true))
        .radius(By(fn() { size().1 / 2.0 }))
        .glass(By(fn() {
          let p = dd.pressed(gl)
          if p > 0.001 {
            Some(toggle_glass(p))
          } else {
            None
          }
        }))
        .alpha(By(fn() { clamp(dd.pressed(gl), 0.0, 1.0) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // (the keyboard's focus on it: a ring round it in the accent)
    v.show(fn() { sw.focus_shown() }, fn(ring) {
      ring
      .over(Is(true))
      .margin(Is((-3.0, -3.0, -3.0, -3.0)))
      .radius(Is(toggle_h / 2.0 + 3.0))
      .edge(By(fn() { (2.0, colors().accent) }))
      |> ignore
    })
  })
}
