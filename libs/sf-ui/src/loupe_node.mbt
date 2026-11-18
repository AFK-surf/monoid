// The loupe (iOS's text loupe, Android's Magnifier) as a node of the window's tree: what a finger hides as it drags
// what needs seeing where it is (@ui.finger_reads: a field's caret or the ends of what is picked by their handles, a
// long press's word slid on) shown larger over it (View::magnifies), in a capsule of the glass a switch's knob held is
// (glass_knob), kit's loupe_lift over the finger, over all else of the window (View::over_all), taking no press nor the
// focus. It is the knob's lens and the bar's ball, not one of its own (kit's loupe.mbt says its measures): it comes in
// as the knob held does (lift_spring, larger by knob_lens_grow, fading in), follows the finger as the ball does
// (follow_spring) and is drawn out by its speed as the ball is (speed_stretch); let go, it goes where it is. Laid out
// where the finger last had it, drawn where its ways have it.

///|
/// The loupe over all else of the window in `root` (one of what the root holds: View::over_all), while `on` holds (else
/// nothing is read), of what the finger reads.
#callsite(autofill(loc))
pub fn loupe_node(root : @view.View, on : () -> Bool, loc~ : SourceLoc) -> Unit {
  // (where the finger last read, where it goes as it is let go; whether it is in the finger, as a knob held is)
  let read : @signals.Signal[(Double, Double)?] = @signals.signal(None, same=fn(a, b) { a == b })
  let held = @motion.NodeWay::new(0.0)
  let ax = @motion.NodeWay::new(0.0)
  let ay = @motion.NodeWay::new(0.0)
  root.box(made_for=loc, fn(l) {
    l
    .over(Is(true))
    .over_all(Is(true))
    .points(Is(false))
    .presses(Is(false))
    |> ignore
    // (where it goes over the point read: within the window's sides, under its top)
    let goal = fn(p : (Double, Double)) {
      let ww = l.window().0
      let half = @kit.loupe_w / 2.0
      let side = @kit.loupe_side
      (
        dclamp(p.0, half + side, dmax(half + side, ww - half - side)),
        dmax(@kit.loupe_h / 2.0 + side, p.1 - @kit.loupe_lift),
      )
    }
    l.reacts(
      fn() {
        if on() {
          @ui.finger_reads()
        } else {
          None
        }
      },
      fn(r) {
        match r {
          Some(p) => {
            let (tx, ty) = goal(p)
            // (come anew: where the finger is, not from where it last was)
            if held.target() == 0.0 && held.value_at(l.cause_at()) <= 0.001 {
              ax.put(tx)
              ay.put(ty)
            } else {
              ax.go(l, tx, @kit.follow_spring)
              ay.go(l, ty, @kit.follow_spring)
            }
            read.set(Some(p))
            held.go(l, 1.0, @motion.lift_spring)
          }
          None => held.go(l, 0.0, @motion.lift_spring)
        }
      },
    )
    // (shown while it is in the finger or on its way out: none drawn, none magnified, once it has gone)
    l.show(at_once=true,
      fn() { read.get() is Some(_) && (held.target() > 0.0 || held.goes(l)) },
      fn(at) { loupe_capsule(at, read, held, ax, ay, goal, loc~) },
    )
  })
  |> ignore
}

///|
/// The loupe's capsule in `at`, laid out where the finger last had it (`goal` of `read`), drawn where its ways have it:
/// what the frame shows there larger, the lens of the glass a knob held is over it (where glass is drawn solid, what it
/// shows bare), as faint and as large as it is in the finger (`held`), drawn out by its speed across.
#callsite(autofill(loc))
fn loupe_capsule(
  at : @view.View,
  read : @signals.Signal[(Double, Double)?],
  held : @motion.NodeWay,
  ax : @motion.NodeWay,
  ay : @motion.NodeWay,
  goal : ((Double, Double)) -> (Double, Double),
  loc~ : SourceLoc,
) -> Unit {
  at.made_for(loc) |> ignore
  let laid = fn() {
    match read.get() {
      Some(p) => goal(p)
      None => (0.0, 0.0)
    }
  }
  let w = @kit.loupe_w
  let h = @kit.loupe_h
  // (drawn out toward where it goes, its back where it was, as it is drawn: how much longer, how much lower, how far
  // over from where it is laid out)
  let drawn = fn(n : @view.View) -> @view.GroundShape {
    let (x, xv) = ax.motion(n)
    let y = ay.shown(n)
    let (tx, ty) = laid()
    // (its way a frame at 60, as the ball's; none where it is all but there)
    let v = if (ax.target() - x).abs() < 0.5 { 0.0 } else { xv / 60.0 }
    let (longer, lower) = @kit.speed_stretch(v)
    let mid = x + (if v < 0.0 { -longer } else { longer }) / 2.0
    let r = (h - lower) / 2.0
    {
      dx: mid - (w + longer) / 2.0 - (tx - w / 2.0),
      dy: y - (h - lower) / 2.0 - (ty - h / 2.0),
      dw: longer,
      dh: -lower,
      corners: Some((r, r, r, r)),
    }
  }
  at
  .over(Is(true))
  .offset(By(fn() {
    let (tx, ty) = laid()
    (tx - w / 2.0, ty - h / 2.0)
  }))
  .width(Is(Some(w)))
  .height(Is(Some(h)))
  .radius(Is(h / 2.0))
  .ground(By(fn() { theme().p.bg }))
  .ground_drawn(By(fn() { drawn(at) }))
  .magnifies(By(fn() {
    match read.get() {
      Some(p) => Some((p.0, p.1, @kit.loupe_zoom))
      None => None
    }
  }))
  // (as faint as it is in the finger, as large: a knob's lens's)
  .alpha(By(fn() { dmin(1.0, held.shown(at)) }))
  .scale(By(fn() { 1.0 + (@kit.knob_lens_grow - 1.0) * held.shown(at) }))
  |> ignore
  at.box(fn(lens) {
    lens
    .over(Is(true))
    .radius(Is(h / 2.0))
    .ground_drawn(By(fn() { drawn(lens) }))
    .glass(By(fn() { if lens.glass_solid() { None } else { Some(glass_knob()) } }))
    .shadow(By(fn() {
      let full = dmin(1.0, held.shown(lens))
      (@kit.lens_shadow * full, @kit.lens_shadow_y * full, ui_theme_now().shadow)
    }))
    |> ignore
  })
  |> ignore
}
