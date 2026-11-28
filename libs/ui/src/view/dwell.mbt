// A finger's rest during a drag: the wait before what it hovers over opens under it (a bar's last slot's menu, a folder
// a thing is dragged to). The hand's events say where the finger is; the rest itself is a moment of the tree's
// timeline (View::at_moment), told at its own moment whatever frames come.

///|
/// A finger's rest, waited for: armed where the finger is (Dwell::at), told once it has stayed within `slop` of there
/// for `ms`; stirred further than `slop`, the wait begins anew from where it is then; called off (Dwell::off), nothing
/// is told.
pub struct Dwell {
  ms : Double
  slop : Double
  /// where the wait began, and where the finger is now (within `slop` of there)
  mut ax : Double
  mut ay : Double
  mut x : Double
  mut y : Double
  mut waiting : Bool
  mut cancel : () -> Unit
}

///|
/// A rest of `ms` within `slop` (points), not waited for yet.
pub fn Dwell::new(ms : Double, slop : Double) -> Dwell {
  { ms, slop, ax: 0.0, ay: 0.0, x: 0.0, y: 0.0, waiting: false, cancel: fn() {  } }
}

///|
/// The finger at (`x`, `y`) at `t`, an event's moment: the wait begun there, or begun anew where it has stirred further
/// than the slop from where the wait began; within the slop, the wait goes on as it was. `then` is told when the wait
/// is over, on `node`'s tree's timeline: that moment and where the finger was last said to be.
#callsite(autofill(loc))
pub fn Dwell::at(
  self : Dwell,
  node : View,
  x : Double,
  y : Double,
  t : Double,
  then : (Double, Double, Double) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  self.x = x
  self.y = y
  let dx = x - self.ax
  let dy = y - self.ay
  if self.waiting && (dx * dx + dy * dy).sqrt() <= self.slop {
    return
  }
  self.off()
  self.ax = x
  self.ay = y
  self.waiting = true
  let when = t + self.ms
  self.cancel = node.at_moment(when, loc~, fn() {
    self.waiting = false
    self.cancel = fn() {  }
    then(when, self.x, self.y)
  })
}

///|
/// The wait called off: the finger gone from what it rested on, or lifted. Nothing is told.
pub fn Dwell::off(self : Dwell) -> Unit {
  self.waiting = false
  (self.cancel)()
  self.cancel = fn() {  }
}

///|
/// Whether a rest is waited for now.
pub fn Dwell::waiting(self : Dwell) -> Bool {
  self.waiting
}
