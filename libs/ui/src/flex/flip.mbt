// What moves for one cause, as data read where it is drawn (the user, 2026-11-10: 「动效进行中的帧不需要重搭任何东西」;
// 2026-11-15, the chat page's lag: nothing on its way is laid out again). At the cause, everything is laid out once
// as it ends; each thing that moved is drawn off where it is laid out by how far it was from there as the cause came,
// that offset going to nothing on one way shared by all of it (FLIP: First, Last, Invert, Play). All that moves at one
// moment, with what was still on its way then, is one way, each its share of it (the user, 2026-11-03: a change come
// while others go is put with what is left of theirs, one whole going to where it all ends): the same as a column's
// ComeGroup, whose items' heights each go their share of one way, but over offsets drawn, not heights laid out.
//
// The way is in points: how far the furthest of it is from where it ends (`far`), going to none as a Move does (from
// rest, or on from the speed all of it went at as it was set off again: come_way's, turned back where it went away from
// its end), or on a curve said by the cause (a flight's rise: one's own words sent, `said`). Each thing's offset is its
// own offset at the cause times the share of the way still left.

///|
/// One thing's offset from where it is laid out as a FlipWay sets out (points: across, down, and how much less wide
/// and less tall it is drawn than it is laid out), and how fast that offset went then (points a ms, each).
pub(all) struct FlipItem {
  off : (Double, Double, Double, Double)
  v : (Double, Double, Double, Double)
}

///|
/// One way for all that moves at a cause (FlipWay::new): from moment `at`, the share of each item's offset left at each
/// moment after. `far`: the most any of them is off (points, the way's length); `v`: how fast that share went as it set
/// out, in points a ms of `far` (toward the end below none); `said`: a way said by the cause (how long, on what curve:
/// 0 … 1 of the time to 0 … 1 of the way gone), in place of a Move.
pub struct FlipWay {
  at : Double
  far : Double
  v : Double
  said : (Double, (Double) -> Double)?
}

///|
/// The way set out at `at` for `items` (each its offset then and how fast it went), on `said` where the cause says one:
/// its length the furthest offset, its speed what the items' speeds come to along their offsets (the least squares
/// fit of one share's speed to all of them: one moving alone goes on as fast as it went, several together as near to
/// each's speed as one way can be).
pub fn FlipWay::new(at : Double, items : Array[FlipItem], said? : (Double, (Double) -> Double)) -> FlipWay {
  let mut far = 0.0
  let mut dot = 0.0
  let mut sq = 0.0
  for i in items {
    let (a, b, c, d) = i.off
    let (va, vb, vc, vd) = i.v
    far = fmax(far, fmax(fmax(a.abs(), b.abs()), fmax(c.abs(), d.abs())))
    dot = dot + a * va + b * vb + c * vc + d * vd
    sq = sq + a * a + b * b + c * c + d * d
  }
  // (the share's speed: d(share)/dt fitted, in points a ms of `far`)
  let v = if sq > 0.0 { dot / sq * far } else { 0.0 }
  { at, far, v, said }
}

///|
/// How much of each item's offset is left `now`, 1 as it sets out, 0 at its end and after, and how fast that goes (a
/// ms).
pub fn FlipWay::left(self : FlipWay, now : Double) -> (Double, Double) {
  let t = time_gone(now, self.at)
  if self.far <= 0.0 {
    return (0.0, 0.0)
  }
  if t <= 0.0 {
    return (1.0, self.v / self.far)
  }
  match self.said {
    Some((ms, curve)) if ms > 0.0 => {
      if t >= ms {
        return (0.0, 0.0)
      }
      let x = t / ms
      let dx = 1.0e-4
      let p = curve(x)
      let slope = (curve(fmin(x + dx, 1.0)) - p) / (fmin(x + dx, 1.0) - x) / ms
      (1.0 - p, -slope)
    }
    _ => {
      let (x, xv) = come_way(self.far, self.v, 0.0, t)
      (x / self.far, xv / self.far)
    }
  }
}

///|
/// When it ends: the moment its share left comes to none.
pub fn FlipWay::ends(self : FlipWay) -> Double {
  if self.far <= 0.0 {
    return self.at
  }
  match self.said {
    Some((ms, _)) if ms > 0.0 => self.at + ms
    _ => self.at + come_way_ms(self.far, self.v, 0.0)
  }
}

///|
/// Item `i`'s offset drawn `now` and how fast it goes then (points, points a ms, each of its four).
pub fn FlipWay::drawn(
  self : FlipWay,
  i : FlipItem,
  now : Double,
) -> ((Double, Double, Double, Double), (Double, Double, Double, Double)) {
  let (k, kv) = self.left(now)
  let (a, b, c, d) = i.off
  ((a * k, b * k, c * k, d * k), (a * kv, b * kv, c * kv, d * kv))
}
