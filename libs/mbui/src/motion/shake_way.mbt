// A shake across (a control refusing a press, a field refusing what was written in it): a drawn offset, never a size,
// so nothing is laid out again as it goes. Said once at its cause's moment; where it is at any moment is worked out
// from that moment alone, `amplitude` × (1 - p) × sin(2π · cycles · p) over p = (now - start) / duration_ms: 0 where
// it sets out and 0 where it ends, smaller each swing between, whatever frames were drawn. Shaken again before it
// ends, it sets out again from the new cause's moment. A node is shaken by it through `way.shakes(v)`, which draws it
// off by the shake at the moment it is drawn at while it goes (`View::offset` by `View::drawn_while`), so no frame is
// asked for once it is over, and says the node shakes across while it goes (`View::shakes_while`): what turns back
// again and again on purpose is no jolt to a Tester's steadiness judges along its row, its left edge and that of what
// it holds alone, and only while it goes. With motion reduced it does not move at all.

///|
/// A shake's way (see the file's head): how far its first swing goes (points), how long it goes (ms), how many whole
/// swings there and back it makes, and when it was last set off (none: never).
pub struct ShakeWay {
  amplitude : Double
  duration_ms : Double
  cycles : Double
  priv started_at : @signals.Signal[Double?]
}

///|
/// A shake not set off, swinging `amplitude` points at most, over `duration_ms`, `cycles` times there and back.
pub fn ShakeWay::new(amplitude? : Double = 4.0, duration_ms? : Double = 280.0, cycles? : Double = 3.0) -> ShakeWay {
  { amplitude, duration_ms, cycles, started_at: @signals.signal(None) }
}

///|
/// Set off at `at` (a cause's moment: `View::cause_at` in the handler that refuses, never the wall clock); set off
/// again from there where it still goes.
#callsite(autofill(loc))
pub fn ShakeWay::shake(self : ShakeWay, at~ : Double, loc~ : SourceLoc) -> Unit {
  self.started_at.set(Some(at), loc~)
}

///|
/// Whether it goes at `now` (ms, the one clock): from where it was set off till `duration_ms` after; never set off,
/// or with motion reduced (`reduced_motion`, the system's by default), never. Followed as it is set off: what reads
/// this in a binding is told as it is shaken again.
pub fn ShakeWay::active_at(self : ShakeWay, now : Double, reduced_motion? : Bool = @ui.reduced_motion()) -> Bool {
  guard !reduced_motion && self.started_at.get() is Some(start) else { return false }
  now >= start && now < start + self.duration_ms
}

///|
/// How far across it is drawn at `now` (points, the first swing to the right): 0 where it does not go (active_at).
pub fn ShakeWay::offset_at(self : ShakeWay, now : Double, reduced_motion? : Bool = @ui.reduced_motion()) -> Double {
  guard self.active_at(now, reduced_motion~) && self.started_at.get() is Some(start) else { return 0.0 }
  let p = (now - start) / self.duration_ms
  self.amplitude * (1.0 - p) * @dmath.sin(p * self.cycles * 2.0 * @math.PI)
}

///|
/// Shakes `v` by it (see the file's head): drawn off across by `offset_at` at the moment it is drawn at while it goes,
/// and said to shake across then (`View::shakes_while`); with motion reduced (`reduced_motion`, the system's by default),
/// neither.
#callsite(autofill(loc))
pub fn ShakeWay::shakes(self : ShakeWay, v : @view.View, reduced_motion? : Bool, loc~ : SourceLoc) -> @view.View {
  let goes = fn(t : Double) {
    match reduced_motion {
      Some(r) => self.active_at(t, reduced_motion=r)
      None => self.active_at(t)
    }
  }
  v
  .shakes_while(goes)
  .offset(
    By(fn() {
      let at = v.drawn_while(goes)
      let x = match reduced_motion {
        Some(r) => self.offset_at(at, reduced_motion=r)
        None => self.offset_at(at)
      }
      (x, 0.0)
    }),
    loc~,
  )
}
