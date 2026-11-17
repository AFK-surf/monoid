// What a finger's way comes to (physics.mbt): the rubber band's pull drawn less and less and never past its room, the
// same either way and smooth through 0; a fling's landing as UIScrollView's deceleration has it; the detent it goes to.

///|
/// Whether `a` and `b` are within `eps` of each other.
fn about(a : Double, b : Double, eps? : Double = 1.0e-9) -> Bool {
  (a - b).abs() <= eps
}

///|
test "rubber band: none for nothing pulled or no room, its sign kept, the same either way" {
  assert_eq(@motion.rubber_band(0.0, 800.0), 0.0)
  assert_eq(@motion.rubber_band(120.0, 0.0), 0.0)
  assert_eq(@motion.rubber_band(120.0, -10.0), 0.0)
  let up = @motion.rubber_band(120.0, 800.0)
  let down = @motion.rubber_band(-120.0, 800.0)
  // (0.55 · 120 · 800 / (800 + 66) = 52800 / 866)
  assert_eq((about(up, 52800.0 / 866.0), about(down, -up), up > 0.0), (true, true, true))
}

///|
test "rubber band: growing as it is pulled, each step less than the one before, never as far as its room" {
  let dim = 600.0
  let pulls = [0.0, 50.0, 100.0, 200.0, 400.0, 800.0, 1600.0, 1.0e6]
  let drawn = pulls.map(fn(p) { @motion.rubber_band(p, dim) })
  let mut grows = true
  let mut slows = true
  let mut bounded = true
  for i in 1..<drawn.length() {
    grows = grows && drawn[i] > drawn[i - 1]
    bounded = bounded && drawn[i] < dim
    if i >= 2 {
      // (each a step twice as long as the one before or more: what it draws per point pulled falls)
      let was = (drawn[i - 1] - drawn[i - 2]) / (pulls[i - 1] - pulls[i - 2])
      let now = (drawn[i] - drawn[i - 1]) / (pulls[i] - pulls[i - 1])
      slows = slows && now < was
    }
  }
  // (pulled a million points over 600: within a point of 600, short of it)
  assert_eq((grows, slows, bounded, dim - drawn[drawn.length() - 1] < 1.0), (true, true, true, true))
}

///|
test "rubber band: its slope through 0 the coefficient from either side, at any coefficient" {
  let h = 1.0e-6
  let checks = [0.55, 0.3, 1.0].map(fn(c) {
    let right = @motion.rubber_band(h, 500.0, coeff=c) / h
    let left = @motion.rubber_band(-h, 500.0, coeff=c) / -h
    about(right, c, eps=1.0e-6) && about(left, c, eps=1.0e-6)
  })
  assert_eq(checks, [true, true, true])
}

///|
test "rubber band within bounds: one to one inside, held back past either end, continuous at both" {
  let (lo, hi, dim) = (100.0, 300.0, 400.0)
  let inside = [100.0, 150.0, 300.0].map(fn(v) { @motion.rubber_band_clamped(v, lo, hi, dim) })
  let past_lo = @motion.rubber_band_clamped(40.0, lo, hi, dim)
  let past_hi = @motion.rubber_band_clamped(380.0, lo, hi, dim)
  let e = 1.0e-7
  let cont_lo = about(@motion.rubber_band_clamped(lo - e, lo, hi, dim), lo, eps=1.0e-6)
  let cont_hi = about(@motion.rubber_band_clamped(hi + e, lo, hi, dim), hi, eps=1.0e-6)
  assert_eq(
    (
      inside,
      about(past_lo, lo + @motion.rubber_band(-60.0, dim)),
      past_lo > 40.0 && past_lo < lo,
      about(past_hi, hi + @motion.rubber_band(80.0, dim)),
      past_hi < 380.0 && past_hi > hi,
      cont_lo,
      cont_hi,
    ),
    ([100.0, 150.0, 300.0], true, true, true, true, true, true),
  )
}

///|
test "a fling's landing: 0.499 s of its speed at the normal rate, as UIScrollView's deceleration adds up" {
  // (its speed kept 0.998 a ms, each ms's step added up: Σ 0.998^k / 1000 = 0.998 / 0.002 / 1000)
  let mut sum = 0.0
  let mut k = 0.998
  for _ in 0..<20000 {
    sum = sum + k / 1000.0
    k = k * 0.998
  }
  assert_eq(
    (
      about(@motion.landing_reach(), 0.499),
      about(@motion.project_landing(0.2, 1.0), 0.699),
      about(@motion.project_landing(100.0, -2000.0), 100.0 - 998.0),
      about(@motion.landing_reach(), sum, eps=1.0e-9),
      // (UIScrollView.DecelerationRate.fast: 0.99, 0.099 s of it)
      about(@motion.project_landing(0.0, 1000.0, decel_rate=0.99), 99.0),
      @motion.project_landing(5.0, 0.0),
    ),
    (true, true, true, true, true, 5.0),
  )
}

///|
test "the detent it goes to: the nearest where it would land, put away past where it is said to close" {
  let detents = [0.0, 0.45]
  // (let go still: the nearest where it is)
  let still_up = @motion.snap_detent(0.1, 0.0, detents, close_past=0.63)
  let still_mid = @motion.snap_detent(0.3, 0.0, detents, close_past=0.63)
  // (let go at the middle, flung up: 0.45 − 0.6 · 0.499 ≈ 0.15, nearer the top)
  let flung_up = @motion.snap_detent(0.45, -0.6, detents, close_past=0.63)
  // (let go near the top, flung down: 0.05 + 2 · 0.499 ≈ 1.05, past 0.63: put away)
  let flung_down = @motion.snap_detent(0.05, 2.0, detents, close_past=0.63)
  // (pulled down past the close, flung back up: lands at 0.7 − 0.3 · 0.499 ≈ 0.55, kept, at the middle)
  let saved = @motion.snap_detent(0.7, -0.3, detents, close_past=0.63)
  // (no close said: the nearest, however far it would go)
  let no_close = @motion.snap_detent(0.05, 2.0, detents)
  // (as near two: the first)
  let tie = @motion.snap_detent(0.5, 0.0, [0.0, 1.0])
  let none = @motion.snap_detent(0.5, 0.0, [])
  debug_inspect(
    (still_up, still_mid, flung_up, flung_down, saved, no_close, tie, none),
    content="(Some(0), Some(1), Some(0), None, Some(1), Some(1), Some(0), None)",
  )
}
