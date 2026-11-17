// A sheet up from the window's foot (iOS's, a drawer's): where it is, `rise`, a share of a room (`span`, the window's
// height as show_in has it) under where it rests all the way up (0 up; 1 gone below the window), going by a spring as
// it is put up or down, from wherever it is and as fast as it goes then. It may rest at more than one place (its
// detents, rising: 0 all the way up, 0.45 at the middle). A finger on its handle takes it one to one, held back past
// the highest of its detents (rubber_band: less and less as it is pulled further), and let go it goes where its speed
// would carry it (snap_detent: Apple's projection), at that speed: to the detent nearest that, or down and put away
// past `close_past`; a tap on it is the handle's own (a search to write in), never a drag. Called off mid-way, back to
// the detent it is nearest. Put away, it slides down over `leave_ms` while what is under it takes presses, keys and
// the focus from that moment (show_in: its layer modal, in use and pressed no more as it is put away).

///|
/// How a sheet comes up and goes down: Apple's for a drawer, its response 0.3 s (stiffness (2π / 0.3)²), critically
/// damped (no bounce past where it rests: that would lift it off the window's foot); at rest within 0.001 of its span.
// kept across runs: a constant: its fields are not mut, nothing changes it
pub let drawer_spring : Spec = Spring(1.0, 438.6, 0.001, 0.0)

///|
/// A sheet's way (see the file's head): where it is, where it may rest, how it goes, how long it slides down once put
/// away, and how far down a finger let go of it puts it away.
pub struct SheetWay {
  priv rise : Way
  priv detents : Array[Double]
  priv opens_at : Int
  priv spec : Spec
  priv leave_ms : Double
  priv close_past : Double
}

///|
/// A sheet down (1), resting where it is put up at `detents` (shares of its span under all the way up, rising; none
/// said, all the way up alone), coming up to the `opens_at`th of them, by `spec`; put away, slid down over `leave_ms`;
/// let go where it would land past `close_past` (by default a third of the way from its lowest detent to the window's
/// foot), put away.
pub fn SheetWay::new(
  detents? : Array[Double] = [0.0],
  opens_at? : Int = 0,
  spec? : Spec = drawer_spring,
  leave_ms? : Double = 400.0,
  close_past? : Double,
) -> SheetWay {
  let ds = if detents.is_empty() { [0.0] } else { detents.copy() }
  ds.sort()
  let lowest = ds[ds.length() - 1]
  {
    rise: Way::new(1.0),
    detents: ds,
    opens_at: if opens_at < 0 || opens_at >= ds.length() { 0 } else { opens_at },
    spec,
    leave_ms,
    close_past: close_past.unwrap_or(lowest + (1.0 - lowest) / 3.0),
  }
}

///|
/// Where it rests up: its detent it comes up to.
fn SheetWay::up_at(self : SheetWay) -> Double {
  self.detents[self.opens_at]
}

///|
/// The highest of its detents (where it is held back past).
fn SheetWay::highest(self : SheetWay) -> Double {
  self.detents[0]
}

///|
/// Where it goes (where it is, at rest; as a finger holds it, where the finger has it), a share of its span.
pub fn SheetWay::target(self : SheetWay) -> Double {
  self.rise.said()
  self.rise.target()
}

///|
/// Where it is at `t` (ms, the one clock) and how fast it goes then (shares of its span a second).
pub fn SheetWay::at(self : SheetWay, t : Double) -> (Double, Double) {
  self.rise.at(t)
}

///|
/// How long it slides down once put away (ms): 0 with motion reduced.
pub fn SheetWay::leave_ms(self : SheetWay) -> Double {
  if @ui.reduced_motion() {
    0.0
  } else {
    self.leave_ms
  }
}

///|
/// Where it is as node `v` draws it (a share of its span under all the way up, as the finger or the spring has it):
/// what a scrim under it reads to darken as it comes (1 - this).
pub fn SheetWay::shown_on(self : SheetWay, v : @view.View) -> Double {
  self.rise.shown_on(v)
}

///|
/// How much of a scrim under it shows as node `v` draws it: none down, all of it up at its highest detent.
pub fn SheetWay::covered_on(self : SheetWay, v : @view.View) -> Double {
  dclamp(1.0 - self.rise.shown_on(v), 0.0, 1.0)
}

///|
/// How far down node `v` draws it (points), over a span `span` points tall: one to one where it may rest or under, held
/// back past its highest detent (rubber_band over `span`). A drawn offset, never a size: nothing laid out again as it
/// goes.
pub fn SheetWay::offset_y(self : SheetWay, v : @view.View, span : Double) -> Double {
  rubber_band_clamped(self.rise.shown_on(v) * span, self.highest() * span, @double.infinity, span)
}

///|
/// Up to its `i`th detent (or down, past its last: put away) from the moment `at` (a cause's), from where it is and as
/// fast (or at `velocity`, shares of its span a second).
#callsite(autofill(loc))
pub fn SheetWay::go_detent(self : SheetWay, i : Int, at~ : Double, velocity? : Double, loc~ : SourceLoc) -> Unit {
  let to = if i >= 0 && i < self.detents.length() { self.detents[i] } else { 1.0 }
  self.rise.go(to, self.spec, at~, velocity?, loc~)
}

///|
/// Following whether it is up (`open`), from node `v`'s cause's moment as that changes: up to the detent it opens at,
/// or down; there at once as it is followed from. One already going there (a finger let it go so) goes on as it was.
pub fn SheetWay::follows(self : SheetWay, v : @view.View, open : () -> Bool) -> Unit {
  self.rise.put(if @signals.untracked(open) { self.up_at() } else { 1.0 })
  v.reacts(open, fn(up) {
    let to = if up { self.up_at() } else { 1.0 }
    if self.rise.target() != to {
      self.rise.go(to, self.spec, at=v.cause_at())
    }
  }, at_start=false)
}

///|
/// What a finger on `handle` does to it (its grip, its top, a search over it), the span it is drawn over `span` points
/// tall as that is asked: a tap is `on_tap`'s (none: nothing); a drag takes it from where it is then (going or not),
/// one to one, and let go goes where snap_detent has it at the finger's speed, `close` said where that is put away;
/// called off, back to the detent nearest, still. `slop`: how far a finger moves before it drags.
pub fn SheetWay::attach_handle(
  self : SheetWay,
  handle : @view.View,
  span~ : () -> Double,
  close~ : () -> Unit,
  on_tap? : () -> Unit,
  slop? : Double = 6.0,
) -> Unit {
  // (where it was and where the finger was as it began to drag)
  let from : Ref[(Double, Double)?] = Ref(None)
  let tap = match on_tap {
    Some(f) => Some(fn(_d : @view.Drag) { f() })
    None => None
  }
  handle
  .gesture(slop, tap?, drag=fn(d) {
    let tall = span()
    match d.kind {
      Down => {
        // (caught where it is at the finger's moment, still: its way, if it went, stopped there)
        let now = self.rise.value_at(d.at)
        self.rise.put(now)
        from.val = Some((now, d.wy))
      }
      Moved =>
        match from.val {
          Some((at, wy)) if tall > 0.0 => self.rise.put(at + (d.wy - wy) / tall)
          _ => ()
        }
      Up | Off => {
        let now = self.rise.target()
        from.val = None
        if d.kind is Up && tall > 0.0 {
          // (the finger's speed: points a ms, as shares of the span a second)
          let speed = d.vy() * 1000.0 / tall
          match snap_detent(now, speed, self.detents, close_past=self.close_past) {
            Some(i) => self.go_detent(i, at=d.at, velocity=speed)
            None => {
              self.rise.go(1.0, self.spec, at=d.at, velocity=speed)
              close()
            }
          }
        } else {
          let i = snap_detent(now, 0.0, self.detents).unwrap_or(0)
          self.go_detent(i, at=d.at, velocity=0.0)
        }
      }
    }
  })
  |> ignore
}

///|
/// A sheet in `parent` while `open` holds (follows): a layer over all the window, modal, its ground what `scrim` gives
/// for how much of it shows (none said: none), taking a press on it, back and Escape as `close`; on it at its foot the
/// sheet, made by `sheet` (its look, its handle: attach_handle), drawn `offset_y` down over the window's height, a press
/// on it its own. Put away (`open` no longer holds) it slides down over leave_ms, and from that moment it is modal,
/// in use and pressed no more: what is under it takes presses, keys and the focus as it goes.
#callsite(autofill(loc))
pub fn SheetWay::show_in(
  self : SheetWay,
  parent : @view.View,
  open~ : () -> Bool,
  close~ : () -> Unit,
  scrim? : (Double) -> Int64,
  sheet : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  self.follows(parent, open)
  parent.show(
    open,
    fn(layer) {
      layer
      .over(Is(true), loc~)
      .over_all(Is(true))
      .modal(By(open))
      .in_use(By(open))
      .presses(By(open))
      .lies_along(Is(End), loc~)
      |> ignore
      match scrim {
        Some(ink) => layer.ground(By(fn() { ink(self.covered_on(layer)) }), loc~) |> ignore
        None => ()
      }
      layer.on_press(close) |> ignore
      layer.takes_back(close) |> ignore
      layer.on_key(fn(k) {
        if k.code == @ui.key_escape {
          close()
          true
        } else {
          false
        }
      })
      |> ignore
      layer.box(
        fn(s) {
          s
          .offset(By(fn() { (0.0, self.offset_y(s, s.window().1)) }), loc~)
          // (a press on it its own, never the scrim's)
          .on_press(fn() {  })
          |> ignore
          sheet(s)
        },
        loc~,
      )
      |> ignore
    },
    leave=self.leave_ms(),
    at_once=true,
    loc~,
  )
}
