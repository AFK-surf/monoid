// A trackpad's two fingers swept to the right, where nothing under them scrolls that way: back, as a finger from the
// left edge goes back (Ctx::back_gesture), the page following the fingers and let go as they stop. No host gives this as
// a gesture of its own: a browser's page is told only `wheel` events, with no phase, no sign of the fingers set down or
// lifted, no mark of the momentum after them (a Mac's own app has AppKit's swipe tracking; a page has nothing like it).
// So a sweep is the wheel's burst: it begins with the first wheel after the wheel was still, is a swipe back once it has
// gone wheel_back_slop to the right (more across than up or down) with nothing under it taking the wheel across, follows
// the fingers (and the momentum after them, which a page cannot tell from them) while it goes on, and is let go
// wheel_back_still_ms after its last wheel, at that moment, on the window's tree's timeline (View::at_moment), whatever
// frames are drawn. Where the host says its momentum (a Mac's, phase 3), it is let go as the momentum begins: the
// fingers lifted then, as fast as they went. A mouse's notches (phase 4) and a wheel with a key held are never one.

///|
/// How far (points) the wheel goes to the right in a burst before it is a swipe back: more than a hand's tremble on a
/// trackpad, as a finger's slop from the edge (Ctx::edge_move's 6) is more than its tremble on a screen.
let wheel_back_slop : Double = 10.0

///|
/// How long (ms) the wheel is still before its burst is over: longer than a trackpad's events are apart (a frame, 8-17
/// ms) and than a browser's momentum's at its slowest, shorter than a person takes to set their fingers down again.
let wheel_back_still_ms : Double = 120.0

///|
/// Fraction of the burst's peak horizontal speed at which a phase-0 host (a browser page, which cannot distinguish
/// fingers lifting from the monotonically decaying momentum that follows) releases the swipe back instead of waiting
/// 1-2 s for momentum to stop plus wheel_back_still_ms.
let wheel_back_fall : Double = 0.7

///|
/// What a burst of the wheel is to the swipe back (WheelBack's `sweep`).
#derive(Eq)
priv enum WheelSweep {
  /// none under way: the next wheel begins one
  Still
  /// not a swipe back: what is under it scrolls by it (or it went up, down or to the left first), all of it theirs
  Theirs
  /// not yet decided: gone less than wheel_back_slop across, nothing under it taking it across so far
  Deciding
  /// a swipe back, following it
  Back
  /// let go (its momentum began), the rest of the burst nobody's: the page gone back is not scrolled by it
  Spent
}

///|
/// The burst of the wheel under way, as a swipe back sees it (wheel_back_take).
priv struct WheelBack {
  mut sweep : WheelSweep
  /// how far it went across while deciding (to the right negative, as the wheel's dx): each of its wheels more across
  /// than up or down (one that was not made it theirs) and taken by nothing
  mut sx : Double
  /// where the swipe began (the pointer's x then) and how far right it has gone since
  mut x0 : Double
  mut across : Double
  /// the last wheel's moment and phase kind (kind 1 after kind 3 begins a new burst)
  mut last : Double
  mut last_kind : Int
  /// phase-0 momentum decay tracking while in Back: wheels seen in Back, peak speed (pt/ms), and last 3 (|dx|, dt)
  mut back_count : Int
  mut peak_v : Double
  win_dx : FixedArray[Double]
  win_dt : FixedArray[Double]
  mut win_n : Int
  mut win_at : Int
  /// what lets it go once the wheel is still (View::at_moment's), called off as the next wheel comes
  mut let_go : () -> Unit
}

///|
fn wheel_back_fresh() -> WheelBack {
  {
    sweep: Still,
    sx: 0.0,
    x0: 0.0,
    across: 0.0,
    last: -1.0e18,
    last_kind: 0,
    back_count: 0,
    peak_v: 0.0,
    win_dx: FixedArray::make(3, 0.0),
    win_dt: FixedArray::make(3, 0.0),
    win_n: 0,
    win_at: 0,
    let_go: fn() {  },
  }
}

///|
// a window's own (window_kept.mbt), a run's own (reset_globals)
let wheel_back : Ref[WheelBack] = Ref(wheel_back_fresh())

///|
/// A wheel turned at (x, y) (`dx`, `dy`, `phase` as on_wheel says them) as a swipe back takes it: true where it was the
/// swipe's or already routed; false where the wheel goes on as ever. `wheel_taken` dispatches the original wheel to
/// what is under (x, y) and reports whether a handler there took it, only while the swipe is being decided.
fn wheel_back_take(
  x : Double,
  y : Double,
  dx : Double,
  dy : Double,
  phase : Int,
  wheel_taken : () -> Bool,
) -> Bool {
  let c = g()
  let s = wheel_back.val
  let t = h_event_time()
  let kind = phase % 16
  let mods = phase / 16
  let prev_last = s.last
  // (a burst over once the wheel was still, or once fingers (kind 1) touch down after momentum (kind 3): what comes
  // now begins another; a swipe back not let go by then, its tree gone meanwhile, let go now)
  if t - s.last >= wheel_back_still_ms || (kind == 1 && s.last_kind == 3) {
    if s.sweep == Back {
      (s.let_go)()
      c.back_gesture(2, s.x0 + s.across, t) |> ignore
    }
    s.sweep = Still
  }
  s.last = t
  s.last_kind = kind
  match s.sweep {
    Back => {
      (s.let_go)()
      s.across = dmax(0.0, s.across - dx)
      wheel_back_said(x, y, dx, dy, phase)
      c.back_gesture(1, s.x0 + s.across, t) |> ignore
      // (its momentum begun: the fingers lifted, let go there, as fast as they went)
      if kind == 3 {
        s.sweep = Spent
        c.back_gesture(2, s.x0 + s.across, t) |> ignore
      } else if kind == 0 && wheel_back_fell(s, dx, t - prev_last) {
        s.sweep = Spent
        c.back_gesture(2, s.x0 + s.across, t) |> ignore
      } else {
        wheel_back_wait(t)
      }
      true
    }
    Spent => {
      wheel_back_said(x, y, dx, dy, phase)
      true
    }
    Theirs => false
    Still | Deciding => {
      if s.sweep == Still {
        s.sx = 0.0
        // (a mouse's notch, a key held, or momentum with no fingers before it here: never a swipe)
        s.sweep = if kind == 4 || kind == 3 || mods != 0 { Theirs } else { Deciding }
        if s.sweep == Theirs {
          return false
        }
      }
      // (up or down more than across: theirs, all of the burst)
      if dy.abs() > dx.abs() || view_app.val is None || !c.back_open() {
        s.sweep = Theirs
        return false
      }
      // (a handler under it took the wheel: theirs, all of the burst)
      if wheel_taken() {
        s.sweep = Theirs
        return true
      }
      // (from here on the wheel was routed, but nothing took it)
      s.sx = s.sx + dx
      if s.sx > wheel_back_slop {
        s.sweep = Theirs
        return true
      }
      if -s.sx > wheel_back_slop {
        s.sweep = Back
        s.x0 = x
        s.across = -s.sx
        s.back_count = 0
        s.peak_v = 0.0
        s.win_n = 0
        s.win_at = 0
        c.back_gesture(0, s.x0, t) |> ignore
        c.back_gesture(1, s.x0 + s.across, t) |> ignore
        wheel_back_wait(t)
      }
      true
    }
  }
}

///|
/// Record a phase-0 wheel during Back and report whether the recent 3-wheel speed has fallen to wheel_back_fall of the
/// burst's peak after at least 4 wheels and once s.across >= back_far: past back_far every taker commits back, so
/// releasing early on momentum decay only cuts the 1-2 s wait without changing the outcome; below back_far we keep
/// following so slow or uneven drags are never prematurely cancelled.
fn wheel_back_fell(s : WheelBack, dx : Double, dt : Double) -> Bool {
  s.back_count = s.back_count + 1
  s.win_dx[s.win_at] = dx.abs()
  s.win_dt[s.win_at] = dmax(0.0, dt)
  s.win_at = (s.win_at + 1) % 3
  if s.win_n < 3 {
    s.win_n = s.win_n + 1
  }
  if s.win_n < 3 {
    return false
  }
  let span = s.win_dt[0] + s.win_dt[1] + s.win_dt[2]
  if span <= 0.0 {
    return false
  }
  let v = (s.win_dx[0] + s.win_dx[1] + s.win_dx[2]) / span
  if v > s.peak_v {
    s.peak_v = v
  }
  s.back_count >= 4 && s.across >= back_far && s.peak_v > 0.0 && v <= s.peak_v * wheel_back_fall
}

///|
/// The swipe back let go wheel_back_still_ms after the wheel's last at `t`, at that moment, unless another comes first.
fn wheel_back_wait(t : Double) -> Unit {
  guard view_app.val is Some(tree) else { return }
  let s = wheel_back.val
  s.let_go = tree
    .root()
    .at_moment(t + wheel_back_still_ms, fn() {
      if s.sweep == Back {
        s.sweep = Still
        s.let_go = fn() {  }
        g().back_gesture(2, s.x0 + s.across, t + wheel_back_still_ms) |> ignore
      }
    })
}

///|
/// A wheel the swipe back took, told as the input it is (what a replay gives again): an old view's where an old view
/// holds the gesture (on_back_now's way), else taped alone.
fn wheel_back_said(x : Double, y : Double, dx : Double, dy : Double, phase : Int) -> Unit {
  let args = [x, y, dx, dy, phase.to_double()]
  match g().back_held {
    Some(h) if h.tree => input_taped("wheel", h_event_time(), args)
    _ => took_input("wheel", h_event_time(), args)
  }
}
