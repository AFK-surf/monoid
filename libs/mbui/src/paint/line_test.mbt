// A line cut to a share of its length (subline), a string pulled aside (tension_line) and a knob drawn into its track
// as one drop (meniscus_outline): worked out of what is given alone.

///|
fn near(a : Double, b : Double) -> Bool {
  (a - b).abs() <= 1.0e-9
}

///|
/// As near as an arc's points come to its circle.
fn about(a : Double, b : Double) -> Bool {
  (a - b).abs() <= 0.06
}

///|
fn length_of(p : Array[(Double, Double)]) -> Double {
  let mut l = 0.0
  for i in 1..<p.length() {
    let (dx, dy) = (p[i].0 - p[i - 1].0, p[i].1 - p[i - 1].1)
    l = l + (dx * dx + dy * dy).sqrt()
  }
  l
}

///|
test "a line's piece between two shares of its length: cut where they fall along it, its corners between kept" {
  // (a tick: down-right then up-right, its two pieces each 10 long)
  let tick = [(0.0, 0.0), (6.0, 8.0), (12.0, 0.0)]
  let whole = @paint.subline(tick, from=0.0, upto=1.0, width=2.0, color=0xFFFFFFFFL)
  let first = @paint.subline(tick, from=0.0, upto=0.25, width=2.0, color=0xFFFFFFFFL)
  let middle = @paint.subline(tick, from=0.25, upto=0.75, width=2.0, color=0xFFFFFFFFL)
  let past = @paint.subline(tick, from=-1.0, upto=2.0, width=2.0, color=0xFFFFFFFFL)
  let none = @paint.subline(tick, from=0.6, upto=0.6, width=2.0, color=0xFFFFFFFFL)
  let flat = @paint.subline([(1.0, 1.0), (1.0, 1.0)], from=0.0, upto=1.0, width=2.0, color=0xFFFFFFFFL)
  assert_eq(
    (
      whole.points == tick && whole.upto == 1.0,
      first.points.length() == 2 && near(first.points[1].0, 3.0) && near(first.points[1].1, 4.0),
      middle.points.length() == 3 && middle.points[1] == (6.0, 8.0) && near(middle.points[2].0, 9.0) && near(middle.points[2].1, 4.0),
      near(length_of(middle.points), 10.0),
      past.points == tick,
      none.points.length(),
      flat.points.length(),
    ),
    (true, true, true, true, true, 0, 0),
  )
}

///|
test "a string pulled aside: straight and two points at rest; its ends kept, its most aside where it is pulled, no step in how it slopes" {
  let rest = @paint.tension_line(200.0, 3.0, 0.04, 100.0)
  let flat = @paint.tension_line(0.0, 3.0, 5.0, 100.0)
  let p = @paint.tension_line(200.0, 3.0, 6.0, 80.0)
  let most = p.fold(init=0.0, fn(m, q) { if (q.0 - 3.0).abs() > m { (q.0 - 3.0).abs() } else { m } })
  let at_pull = p.filter(fn(q) { near(q.1, 80.0) })
  // (the slope between neighbours, as it changes, never jumps more than its curve bends: smooth to the eye)
  let mut steps_ok = true
  for i in 2..<p.length() {
    let s0 = (p[i - 1].0 - p[i - 2].0) / dmax(p[i - 1].1 - p[i - 2].1, 1.0e-9)
    let s1 = (p[i].0 - p[i - 1].0) / dmax(p[i].1 - p[i - 1].1, 1.0e-9)
    if (s1 - s0).abs() > 0.05 {
      steps_ok = false
    }
  }
  let ends_ok = p[0] == (3.0, 0.0) && p[p.length() - 1] == (3.0, 200.0)
  let down = p.iter().zip(p.iter().drop(1)).all(fn(pq) { pq.1.1 > pq.0.1 })
  let near_end = @paint.tension_line(100.0, 0.0, -4.0, 0.0)
  assert_eq(
    (rest, flat, near(most, 6.0), at_pull.length() == 1 && near(at_pull[0].0, 9.0), steps_ok, ends_ok, down,
      near_end[0] == (0.0, 0.0) && near_end.iter().all(fn(q) { q.0 <= 0.0 && q.0 >= -4.0 })),
    ([(3.0, 0.0), (3.0, 200.0)], [(3.0, 0.0), (3.0, 0.0)], true, true, true, true, true, true),
  )
}

///|
fn dmax(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
test "a knob and its track as one drop: the disc alone when hardly held; held, one closed outline holding the disc and the track from its start" {
  let disc = @paint.meniscus_outline(0.0, 10.0, 4.0, 60.0, 9.0, 0.0)
  let close = @paint.meniscus_outline(55.0, 10.0, 4.0, 60.0, 9.0, 1.0)
  let drop = @paint.meniscus_outline(0.0, 10.0, 4.0, 60.0, 9.0, 1.0)
  let soft = @paint.meniscus_outline(0.0, 10.0, 4.0, 60.0, 9.0, 0.3)
  let xs = fn(o : Array[(Array[Double], Bool)]) {
    let out = []
    for i, v in o[0].0 {
      if i % 2 == 0 {
        out.push(v)
      }
    }
    out
  }
  let ys = fn(o : Array[(Array[Double], Bool)]) {
    let out = []
    for i, v in o[0].0 {
      if i % 2 == 1 {
        out.push(v)
      }
    }
    out
  }
  let lo = fn(a : Array[Double]) { a.fold(init=1.0e9, fn(m, x) { if x < m { x } else { m } }) }
  let hi = fn(a : Array[Double]) { a.fold(init=-1.0e9, fn(m, x) { if x > m { x } else { m } }) }
  // (every point of the drop on the disc or within the track's band or between: none past the disc's top or foot)
  let within = ys(drop).all(fn(y) { y >= 1.0 - 1.0e-9 && y <= 19.0 + 1.0e-9 })
  // (its neck leaves the track further back the more it is held)
  let neck_start = fn(o : Array[(Array[Double], Bool)]) {
    let p = o[0].0
    let mut x = 1.0e9
    for i in 0..<(p.length() / 2) {
      if near(p[2 * i + 1], 8.0) && p[2 * i] > 2.0 && p[2 * i] < x {
        x = p[2 * i]
      }
    }
    x
  }
  assert_eq(
    (
      disc.length(),
      disc[0].1,
      about(lo(xs(disc)), 51.0) && about(hi(xs(disc)), 69.0),
      close.length() == 1 && about(lo(xs(close)), 51.0),
      drop.length() == 1 && drop[0].1,
      about(lo(xs(drop)), 0.0) && about(hi(xs(drop)), 69.0),
      about(lo(ys(drop)), 1.0) && about(hi(ys(drop)), 19.0),
      within,
      neck_start(drop) < neck_start(soft),
    ),
    (1, true, true, true, true, true, true, true, true),
  )
}
