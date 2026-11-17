// A page pushed over another from the window's right (iOS's push): where it is, a share of the window's width (0 over
// what it is pushed over, 1 off at its right), going by a spring as it is pushed or taken off, from wherever it is and
// as fast as it goes then. What it is pushed over is drawn a third of the width to its left as it comes all the way
// over it, and not at all once covered (under_pushed); a scrim between the two darkens as it comes. A finger from the
// window's left edge takes it along one to one, and let go, it goes where its speed would carry it (project_landing):
// off past halfway, else back over, at that speed. Taken off however (back, its button, the finger), it slides away over
// `leave_ms` while what is under it takes presses, keys and the focus from that moment (show_in: its layer in use and
// pressed no more as it is taken off), never only once it is gone.

///|
/// How a page is pushed and taken off: Apple's for moving a thing, its response 0.35 s (stiffness (2π / 0.35)²),
/// critically damped; at rest within 0.001 of the width.
// kept across runs: a constant: its fields are not mut, nothing changes it
pub let push_spring : Spec = Spring(1.0, 322.0, 0.001, 0.0)

///|
/// A pushed page's way (see the file's head): where it is, how it goes, how long it slides away once taken off, how wide
/// the left edge a finger takes it back by is, and how far over a finger let go of it takes it off.
pub struct PushWay {
  priv push : Way
  priv spec : Spec
  priv leave_ms : Double
  priv edge_width : Double
  priv off_past : Double
}

///|
/// A page off (1), pushed over by `spec`; taken off, slid away over `leave_ms`; taken back by a finger from the
/// window's left edge `edge_width` wide, let go where it would land past `off_past` of the width, taken off.
pub fn PushWay::new(
  spec? : Spec = push_spring,
  leave_ms? : Double = 520.0,
  edge_width? : Double = 24.0,
  off_past? : Double = 0.5,
) -> PushWay {
  { push: Way::new(1.0), spec, leave_ms, edge_width, off_past }
}

///|
/// Where it goes (where it is, at rest; as a finger holds it, where the finger has it), a share of the width.
pub fn PushWay::target(self : PushWay) -> Double {
  self.push.said()
  self.push.target()
}

///|
/// Where it is at `t` (ms, the one clock) and how fast it goes then (shares of the width a second).
pub fn PushWay::at(self : PushWay, t : Double) -> (Double, Double) {
  self.push.at(t)
}

///|
/// How wide the left edge a finger takes it back by is (points).
pub fn PushWay::edge_width(self : PushWay) -> Double {
  self.edge_width
}

///|
/// How long it slides away once taken off (ms): 0 with motion reduced.
pub fn PushWay::leave_ms(self : PushWay) -> Double {
  if @ui.reduced_motion() {
    0.0
  } else {
    self.leave_ms
  }
}

///|
/// Where it is as node `v` draws it: 0 over, 1 off at the right.
pub fn PushWay::shown_on(self : PushWay, v : @view.View) -> Double {
  self.push.shown_on(v)
}

///|
/// How much of a scrim under it shows as node `v` draws it: none off, all of it over.
pub fn PushWay::scrim_alpha(self : PushWay, v : @view.View) -> Double {
  dclamp(1.0 - self.push.shown_on(v), 0.0, 1.0)
}

///|
/// How far right node `v` draws the page (points): its share of the window's width.
pub fn PushWay::offset_x(self : PushWay, v : @view.View) -> Double {
  v.window().0 * self.push.shown_on(v)
}

///|
/// What it is pushed over, node `v`: drawn a third of the window's width to its left as it comes all the way over it
/// (iOS's), and not drawn at all once it is covered. Drawn offsets and alpha alone: nothing laid out again.
#callsite(autofill(loc))
pub fn PushWay::under_pushed(self : PushWay, v : @view.View, loc~ : SourceLoc) -> Unit {
  v
  .offset(By(fn() { (-0.3 * v.window().0 * (1.0 - self.push.shown_on(v)), 0.0) }), loc~)
  .alpha(By(fn() { if self.push.shown_on(v) <= 0.0 { 0.0 } else { 1.0 } }), loc~)
  |> ignore
}

///|
/// Over (0) from `at` (a cause's), from where it is and as fast (or at `velocity`, shares of the width a second); `off`,
/// off at the right (1).
#callsite(autofill(loc))
pub fn PushWay::go(self : PushWay, off : Bool, at~ : Double, velocity? : Double, loc~ : SourceLoc) -> Unit {
  self.push.go(if off { 1.0 } else { 0.0 }, self.spec, at~, velocity?, loc~)
}

///|
/// Following whether it is pushed (`open`), from node `v`'s cause's moment as that changes: over, or off; there at once
/// as it is followed from. One already going there (a finger let it go so) goes on as it was.
pub fn PushWay::follows(self : PushWay, v : @view.View, open : () -> Bool) -> Unit {
  self.push.put(if @signals.untracked(open) { 0.0 } else { 1.0 })
  v.reacts(open, fn(on) {
    let to = if on { 0.0 } else { 1.0 }
    if self.push.target() != to {
      self.push.go(to, self.spec, at=v.cause_at())
    }
  }, at_start=false)
}

///|
/// What a finger on `edge` (the window's left edge, edge_width wide) does to it, the width as `width` has it then: a
/// drag takes it from where it is then (going or not), one to one, within over and off; let go, off where it would land
/// past off_past (project_landing at the finger's speed), `close` said then, else back over, at that speed; called
/// off, back over, still.
pub fn PushWay::attach_edge(
  self : PushWay,
  edge : @view.View,
  width~ : () -> Double,
  close~ : () -> Unit,
  slop? : Double = 8.0,
) -> Unit {
  // (where it was and where the finger was as it began to drag)
  let from : Ref[(Double, Double)?] = Ref(None)
  edge
  .gesture(slop, drag=fn(d) {
    let w = width()
    match d.kind {
      Down => {
        // (caught where it is at the finger's moment, still)
        let now = self.push.value_at(d.at)
        self.push.put(now)
        from.val = Some((now, d.wx))
      }
      Moved =>
        match from.val {
          Some((at, wx)) if w > 0.0 => self.push.put(dclamp(at + (d.wx - wx) / w, 0.0, 1.0))
          _ => ()
        }
      Up | Off => {
        let now = self.push.target()
        from.val = None
        // (the finger's speed: points a ms, as shares of the width a second)
        let speed = if d.kind is Up && w > 0.0 { d.vx() * 1000.0 / w } else { 0.0 }
        let off = d.kind is Up && project_landing(now, speed) > self.off_past
        self.push.go(if off { 1.0 } else { 0.0 }, self.spec, at=d.at, velocity=speed)
        if off {
          close()
        }
      }
    }
  })
  |> ignore
}

///|
/// A page pushed over `parent`'s while `open` holds (follows): a layer over it, a scrim under the page its ground by
/// `scrim` for how much of it shows (none said: none), the page made by `page` (its look, its content) drawn offset_x
/// right, back taken as `close`, and over the page's left edge (from `edge_top` down: a bar's back button left to the
/// page) what a finger takes it back by (attach_edge). Taken off (`open` no longer holds) it slides away over leave_ms,
/// and from that moment it is in use and pressed no more: what is under it takes presses, keys and the focus as it
/// goes. What it is pushed over says under_pushed itself.
#callsite(autofill(loc))
pub fn PushWay::show_in(
  self : PushWay,
  parent : @view.View,
  open~ : () -> Bool,
  close~ : () -> Unit,
  scrim? : (Double) -> Int64,
  edge_top? : Double = 0.0,
  page : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  self.follows(parent, open)
  parent.show(
    open,
    fn(layer) {
      layer.over(Is(true), loc~).in_use(By(open)).presses(By(open)) |> ignore
      layer.takes_back(close) |> ignore
      match scrim {
        Some(ink) =>
          layer.box(
            fn(dim) {
              dim
              .over(Is(true), loc~)
              .presses(Is(false))
              .ground(By(fn() { ink(self.scrim_alpha(dim)) }), loc~)
              |> ignore
            },
            loc~,
          )
          |> ignore
        None => ()
      }
      layer.box(
        fn(p) {
          p.over(Is(true), loc~).offset(By(fn() { (self.offset_x(p), 0.0) }), loc~) |> ignore
          page(p)
          // (made after what the page holds: over it, at its left edge)
          p.box(
            fn(edge) {
              edge
              .over(Is(true), edges=(Some(0.0), Some(edge_top), None, Some(0.0)), loc~)
              .width(Is(Some(self.edge_width)), loc~)
              |> ignore
              self.attach_edge(edge, width=fn() { p.window().0 }, close~)
            },
            loc~,
          )
          |> ignore
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
