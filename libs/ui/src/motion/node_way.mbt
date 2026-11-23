// A number's way bound to a node of the window's tree (Way), set off from the moment of its cause, drawn where it is
// at the moment its node is drawn while it goes, and told at its declared end on that node's timeline (View::at_moment).
// Whatever moment is pending on a node is called off as another way is said on this NodeWay and as that node is let go
// (View::owns), so no node ever leaves a due moment behind when torn down mid-way.

///|
pub struct NodeWay {
  priv way : Way
  priv ended : @signals.Signal[Int]
  priv mut due : (() -> Unit)?
}

///|
/// At `v`, still.
pub fn NodeWay::new(v : Double) -> NodeWay {
  { way: Way::new(v), ended: @signals.signal(0), due: None }
}

///|
/// Arm its declared end on `n`'s timeline, and tie its handle to `n` (View::owns_while) so tearing `n` down mid-way
/// drops both the timeline moment and `self.due`.
fn NodeWay::arm(self : NodeWay, n : @view.View) -> Unit {
  if self.way.ends_at() >= 0.0 && n.alive() {
    let unkeep : Ref[(() -> Unit)?] = Ref(None)
    let drop_unkeep = fn() {
      match unkeep.val {
        Some(f) => {
          unkeep.val = None
          f()
        }
        None => ()
      }
    }
    let stop_moment = n.at_moment(self.way.end(), fn() {
      drop_unkeep()
      self.due = None
      self.ended.set(self.ended.untracked() + 1)
    })
    unkeep.val = Some(n.owns_while(fn() {
      unkeep.val = None
      stop_moment()
      self.due = None
    }))
    self.due = Some(fn() {
      drop_unkeep()
      stop_moment()
      self.due = None
    })
  } else {
    self.due = None
  }
}

///|
/// Cancel any pending end moment without changing the way's value.
pub fn NodeWay::stop(self : NodeWay) -> Unit {
  match self.due {
    Some(d) => {
      self.due = None
      d()
    }
    None => ()
  }
}

///|
/// Off to `to` as `spec` says from `n`'s cause's moment, from where it is then (as fast as it goes then, or at
/// `velocity` per second); its end a moment of `n`'s, what reads it told then.
#callsite(autofill(loc))
pub fn NodeWay::go(
  self : NodeWay,
  n : @view.View,
  to : Double,
  spec : Spec,
  velocity? : Double,
  loc~ : SourceLoc,
) -> Unit {
  if self.way.target() == to && velocity is None {
    return
  }
  self.stop()
  self.way.go(to, spec, at=n.cause_at(), velocity?, loc~)
  self.arm(n)
}

///|
/// Off to `to` over `ms` (eased out, or as `ease` says) from `n`'s cause's moment, from where it is then; its end a
/// moment of `n`'s.
#callsite(autofill(loc))
pub fn NodeWay::go_ms(
  self : NodeWay,
  n : @view.View,
  to : Double,
  ms : Double,
  ease? : @ui.Ease = Out,
  loc~ : SourceLoc,
) -> Unit {
  self.go(n, to, tween(ms, ease~), loc~)
}

///|
/// On a way from `from` to `to` as `spec` says from the moment `at` (a cause's), as fast as it went at that moment on
/// the way it was on (its place carried over into the new terms: `from`), its end a moment of `n`'s.
#callsite(autofill(loc))
pub fn NodeWay::put_at(
  self : NodeWay,
  n : @view.View,
  from : Double,
  to : Double,
  spec : Spec,
  at : Double,
  loc~ : SourceLoc,
) -> Unit {
  self.stop()
  let (_, v) = self.way.at(at)
  self.way.put(from, loc~)
  self.way.go(to, spec, at~, velocity=v, loc~)
  self.arm(n)
}

///|
/// On a way from `from` (put there, still) to `to` as `spec` says from `at` (`n`'s cause's moment by default), its end
/// a moment of `n`'s: set off anew from its start.
#callsite(autofill(loc))
pub fn NodeWay::go_from(
  self : NodeWay,
  n : @view.View,
  from : Double,
  to : Double,
  spec : Spec,
  at? : Double,
  loc~ : SourceLoc,
) -> Unit {
  self.stop()
  let start = at.unwrap_or(n.cause_at())
  self.way.put(from, loc~)
  self.way.go(to, spec, at=start, loc~)
  self.arm(n)
}

///|
/// There at once, still.
#callsite(autofill(loc))
pub fn NodeWay::put(self : NodeWay, v : Double, loc~ : SourceLoc) -> Unit {
  self.stop()
  self.way.put(v, loc~)
}

///|
/// Where it is at `t` (ms, the one clock).
pub fn NodeWay::value_at(self : NodeWay, t : Double) -> Double {
  self.way.value_at(t)
}

///|
/// Whether it still goes at `t`.
pub fn NodeWay::goes_at(self : NodeWay, t : Double) -> Bool {
  self.way.goes_at(t)
}

///|
/// Where it goes (where it is, at rest), followed as another way is said.
pub fn NodeWay::target(self : NodeWay) -> Double {
  self.way.said()
  self.way.target()
}

///|
/// The moment its way ends (a moment of its node's timeline).
pub fn NodeWay::end(self : NodeWay) -> Double {
  self.way.end()
}

///|
/// When it is there, as it was told; -1 for one put there at once.
pub fn NodeWay::ends_at(self : NodeWay) -> Double {
  self.way.ends_at()
}

///|
/// Whether it goes at `n`'s logic's moment, followed: told as a way is said and as it ends (its declared end, a moment
/// of `n`'s).
pub fn NodeWay::goes(self : NodeWay, n : @view.View) -> Bool {
  self.way.said()
  self.ended.get() |> ignore
  n.goes_now(fn(at) { self.way.goes_at(at) })
}

///|
/// Where it is as `n` is drawn: at the moment it is drawn at while it goes, where it went once it is there.
pub fn NodeWay::shown(self : NodeWay, n : @view.View) -> Double {
  self.ended.get() |> ignore
  self.way.shown_on(n)
}

///|
/// When it set out, as it was told; -1 for one put there at once.
pub fn NodeWay::starts_at(self : NodeWay) -> Double {
  self.way.starts_at()
}

///|
/// Where it is as `n` is drawn and how fast it goes then (per second): Way::motion_on's, still (0) once it is there.
pub fn NodeWay::motion(self : NodeWay, n : @view.View) -> (Double, Double) {
  self.ended.get() |> ignore
  self.way.motion_on(n)
}
