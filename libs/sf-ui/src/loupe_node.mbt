// The loupe (iOS's text loupe, Android's Magnifier) as a node of the window's tree: what a finger hides as it drags
// what needs seeing where it is (@ui.finger_reads: a field's caret or the ends of what is picked by their handles, a
// long press's word slid on) shown larger over it (View::magnifies), in a capsule of the glass a switch's knob held is
// (glass_knob), loupe_lift over the finger, over all else of the window (View::over_all), taking no press nor the
// focus. It is the knob's lens and the bar's ball, not one of its own (its measures at this file's foot): it comes in
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
  let follow = @motion.SpringFollow2D::new()
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
      let half = loupe_w / 2.0
      let side = loupe_side
      (
        dclamp(p.0, half + side, dmax(half + side, ww - half - side)),
        dmax(loupe_h / 2.0 + side, p.1 - loupe_lift),
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
            follow.chase(l, tx, ty)
            read.set(Some(p))
          }
          None => follow.release(l)
        }
      },
    )
    // (shown while it is in the finger or on its way out: none drawn, none magnified, once it has gone)
    l.show(at_once=true,
      fn() { read.get() is Some(_) && follow.active(l) },
      fn(at) { loupe_capsule(at, read, follow, goal, loc~) },
    )
  })
  |> ignore
}

///|
/// The loupe's capsule in `at`, laid out where the finger last had it (`goal` of `read`), drawn where its ways have it:
/// what the frame shows there larger, the lens of the glass a knob held is over it (where glass is drawn solid, what it
/// shows bare), as faint and as large as it is in the finger (`follow`), drawn out by its speed across.
#callsite(autofill(loc))
fn loupe_capsule(
  at : @view.View,
  read : @signals.Signal[(Double, Double)?],
  follow : @motion.SpringFollow2D,
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
  let w = loupe_w
  let h = loupe_h
  // (drawn out toward where it goes, its back where it was, as it is drawn: how much longer, how much lower, how far
  // over from where it is laid out)
  let drawn = fn(n : @view.View) -> @view.GroundShape {
    let (tx, ty) = laid()
    follow.capsule_shape(n, w, h, tx, ty)
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
      Some(p) => Some((p.0, p.1, loupe_zoom))
      None => None
    }
  }))
  // (as faint as it is in the finger, as large: a knob's lens's)
  .alpha(By(fn() { dmin(1.0, follow.held_shown(at)) }))
  .scale(By(fn() { 1.0 + (knob_lens_grow - 1.0) * follow.held_shown(at) }))
  |> ignore
  at.box(fn(lens) {
    lens
    .over(Is(true))
    .radius(Is(h / 2.0))
    .ground_drawn(By(fn() { drawn(lens) }))
    .glass(By(fn() { if lens.glass_solid() { None } else { Some(glass_knob()) } }))
    .shadow(By(fn() {
      let full = dmin(1.0, follow.held_shown(lens))
      (lens_shadow * full, lens_shadow_y * full, ui_theme_now().shadow)
    }))
    |> ignore
  })
  |> ignore
}

///|
/// How much larger the loupe shows what is under the finger, its size, how far over the finger its middle is, and how
/// far in from the window's sides it stays; how much larger a knob's lens grows as it comes (kit's loupe.mbt's).
let loupe_zoom : Double = 1.35

///|
let loupe_w : Double = 124.0

///|
let loupe_h : Double = 48.0

///|
let loupe_lift : Double = 92.0

///|
let loupe_side : Double = 8.0

///|
let knob_lens_grow : Double = 1.25

///|
/// A lens's shadow, held all the way: its blur and how far down (kit's toggle.mbt's, a sliding group's lens's).
let lens_shadow : Double = 6.0

///|
let lens_shadow_y : Double = 2.0
