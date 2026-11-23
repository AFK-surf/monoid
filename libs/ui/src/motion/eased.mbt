// A number a part's look moves between as its state changes (how lit it is under the hand, how far a knob has gone):
// on a Way of its own, from the moment of what changed it, its end declared on its node's timeline so what reads
// `shown` is told once as it comes to rest; drawn where it is at the moment it is drawn while it goes, where it went
// once it is there.

///|
/// One number a node's look moves: its way, and the end of the way it goes now (a moment of the node's timeline, what
/// reads `shown` told as it gets there), let go as another is said and as the node is.
pub struct Eased {
  way : Way
  ended : @signals.Signal[Int]
  mut due : () -> Unit
}

///|
/// At `v`, still.
pub fn Eased::new(v : Double) -> Eased {
  { way: Way::new(v), ended: @signals.signal(0), due: fn() {  } }
}

///|
/// Off to `to` over `ms` (eased out, or as `ease` says, `delay` ms after `n`'s cause's moment), from where it is then;
/// its end a moment of `n`'s, said by its caller (`loc`: whose that moment is, a wake of its own).
#callsite(autofill(loc))
pub fn Eased::go(
  self : Eased,
  n : @view.View,
  to : Double,
  ms : Double,
  ease? : @ui.Ease = Out,
  delay? : Double = 0.0,
  loc~ : SourceLoc,
) -> Unit {
  self.go_by(n, to, tween(ms, ease~, delay~), loc~)
}

///|
/// Off to `to` as `spec` says (a tween, a curve, a Move by how far it goes) from `n`'s cause's moment, from where it
/// is then (or as fast as `velocity` per second); its end a moment of `n`'s, said by its caller (`loc`: what waits for
/// it knows one way's end from another's, the same way said again from many).
#callsite(autofill(loc))
pub fn Eased::go_by(
  self : Eased,
  n : @view.View,
  to : Double,
  spec : Spec,
  velocity? : Double,
  loc~ : SourceLoc,
) -> Unit {
  if self.way.target() == to {
    return
  }
  (self.due)()
  self.way.go(to, spec, at=n.cause_at(), velocity?)
  self.due = if self.way.ends_at() >= 0.0 {
    n.at_moment(self.way.end(), fn() { self.ended.set(self.ended.untracked() + 1) }, loc~)
  } else {
    fn() {  }
  }
}

///|
/// Off from `from` (put there at that moment, still) to `to` as `spec` says, from `n`'s cause's moment; its end a
/// moment of `n`'s, said by its caller (as go_by's).
#callsite(autofill(loc))
pub fn Eased::go_from(
  self : Eased,
  n : @view.View,
  from : Double,
  to : Double,
  spec : Spec,
  loc~ : SourceLoc,
) -> Unit {
  (self.due)()
  self.way.put(from)
  self.way.go(to, spec, at=n.cause_at())
  self.due = if self.way.ends_at() >= 0.0 {
    n.at_moment(self.way.end(), fn() { self.ended.set(self.ended.untracked() + 1) }, loc~)
  } else {
    fn() {  }
  }
}

///|
/// There at once, still (where a hand holds it).
pub fn Eased::put(self : Eased, v : Double) -> Unit {
  (self.due)()
  self.due = fn() {  }
  self.way.put(v)
}

///|
/// The moment its way ends (a moment of its node's timeline: what is done once it is there is declared at it).
pub fn Eased::end(self : Eased) -> Double {
  self.way.end()
}

///|
/// Where it goes (where it is, at rest), followed as another way is said.
pub fn Eased::target(self : Eased) -> Double {
  self.way.said()
  self.way.target()
}

///|
/// Where it is as `n` is drawn: at the moment it is drawn at while it goes, where it went once it is there.
pub fn Eased::shown(self : Eased, n : @view.View) -> Double {
  self.ended.get() |> ignore
  self.way.shown_on(n)
}

///|
/// Where it is as `n` is drawn and how fast it goes then (per second): Way::motion_on's, still (0) once it is there.
pub fn Eased::motion(self : Eased, n : @view.View) -> (Double, Double) {
  self.ended.get() |> ignore
  self.way.motion_on(n)
}

///|
/// An `Eased` moving with `on`, 1 while it holds and 0 while not, as `spec` says from the moment it changed: made in
/// `n`, let go with it.
pub fn eased_on(n : @view.View, on : () -> Bool, spec : Spec) -> Eased {
  let e = Eased::new(if @signals.untracked(on) { 1.0 } else { 0.0 })
  n.reacts(on, fn(now) { e.go_by(n, if now { 1.0 } else { 0.0 }, spec) })
  e
}
