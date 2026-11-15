// What sizes_steady calls stopped dead: a step in how fast a measure slows as it comes to rest, not where its rest falls
// among the frames (sizes_steady_fault, stop_jerk).

///|
/// A measure's samples (each frame's moment, drawn then, and the measure) `period` apart, its speed a frame at each.
fn dead_samples(speeds : Array[Double], period : Double) -> Array[(Double, Double, Double)] {
  let out = [(1000.0, 1000.0, 100.0)]
  let mut x = 100.0
  for i, v in speeds {
    x = x + v
    let t = 1000.0 + (i + 1).to_double() * period
    out.push((t, t, x))
  }
  out
}

///|
fn dead_said(speeds : Array[Double], period : Double) -> Bool {
  let (said, _) = sizes_steady_fault(dead_samples(speeds, period), period, turned=-1.0)
  said is Some(s) && s.contains("stopped dead")
}

///|
test "stopped dead: at speed, then still in a frame, said; as fast or a little slower before, said" {
  let period = 1000.0 / 60.0
  assert_true(dead_said([10.0, 10.0, 10.0, 0.0], period))
  assert_true(dead_said([10.0, 10.0, 9.0, 0.0], period))
  assert_true(dead_said([10.0, 10.0, 0.0], period))
  assert_true(dead_said([10.0, 9.0, 0.0], period))
  // (going faster, then still)
  assert_true(dead_said([16.5, 18.4, 0.0], period))
  // (as come_group's turned back, before: 12.9, 12.95, then slowing 5.3 and 6.3 a frame)
  assert_true(dead_said([12.9, 12.95, 7.68, 1.38], period))
}

///|
test "stopped dead: slowing at one rate to rest, wherever its rest falls among the frames and at any rate, not said" {
  for rate in [7.0, 24.0, 60.0, 120.0] {
    let period = 1000.0 / rate
    for phase in [0.0, 0.25, 0.5, 0.75] {
      // (from 20 a 60th of a second, slowing 4 a 60th each 60th, sampled every frame of `rate`, at rest once there)
      let a = 4.0 / (1000.0 / 60.0) / (1000.0 / 60.0)
      let v0 = 20.0 / (1000.0 / 60.0)
      let stop = v0 / a
      let at = fn(t : Double) {
        let u = if t < stop { t } else { stop }
        v0 * u - a * u * u / 2.0
      }
      let samples = []
      let mut k = 0
      while k < 12 {
        let t = (k.to_double() + phase) * period
        samples.push((1000.0 + t, 1000.0 + t, at(t)))
        let (said, _) = sizes_steady_fault(samples, period, turned=-1.0)
        assert_true(!(said is Some(s) && s.contains("stopped dead")), msg="\{rate} \{phase} at \{k}: \{Repr(said)}")
        k = k + 1
      }
    }
  }
}

///|
test "stopped dead: what it does after has no part in it" {
  let period = 1000.0 / 60.0
  // (slowing at one rate to rest, or on through it a little: not said, whether it turns back after or not; it is judged
  // on the frame it comes to rest, as drawn, what comes after unseen then)
  assert_true(!dead_said([12.0, 8.0, 4.0, 0.0], period))
  assert_true(!dead_said([12.0, 8.0, 4.0, -0.1], period))
  assert_true(!dead_said([12.0, 8.0, 4.0, 0.3], period))
  // (at speed, then still: said, as it will turn back after or not)
  assert_true(dead_said([10.0, 10.0, 0.0], period))
  assert_true(dead_said([10.0, 10.0, -0.5], period))
}

///|
test "stopped dead: slowing at one rate through its top with frames twice as long between, not said; at speed then still, said" {
  let period = 1000.0 / 60.0
  // (a sheet's top slowing at one rate as it came, through where it turns back, drawn every frame and then every other:
  // a test's run walking the host's frames, then going on to what is due next; drive_wbtest's ＋ sheet, 2026-11-15)
  // (as it was drawn: slowing 6.9 a 60th of a second each 60th, through its top between the last two)
  let seen = [
    (1300.0, 1300.0, 254.0781395200147),
    (1316.6666666666667, 1316.6666666666667, 222.5948057883727),
    (1333.3333333333333, 1333.3333333333333, 198.00475242425284),
    (1366.6666666666667, 1366.6666666666667, 169.58126872420496),
    (1400.0, 1400.0, 172.07559340467776),
  ]
  let (said, _) = sizes_steady_fault(seen, period, turned=-1.0)
  assert_true(!(said is Some(s) && s.contains("stopped dead")), msg="\{Repr(said)}")
  // (the same way set out between the first two frames, a piece of a frame at speed in the first: not said)
  let set_out = [
    (1300.0, 1300.0, 791.7271589377052),
    (1316.6666666666667, 1316.6666666666667, 789.3539697013215),
    (1333.3333333333333, 1333.3333333333333, 764.7639163372016),
    (1366.6666666666667, 1366.6666666666667, 736.3404326371538),
    (1400.0, 1400.0, 738.8347573176266),
  ]
  let (said, _) = sizes_steady_fault(set_out, period, turned=-1.0)
  assert_true(!(said is Some(s) && s.contains("stopped dead")), msg="set out: \{Repr(said)}")
  // (the same frames, at speed then still in the longer one: said)
  let still = [(1300.0, 1300.0, 254.0), (1316.0, 1316.0, 224.0), (1333.0, 1333.0, 194.0), (1366.0, 1366.0, 134.0), (1400.0, 1400.0, 134.0)]
  let (said, _) = sizes_steady_fault(still, period, turned=-1.0)
  assert_true(said is Some(s) && s.contains("stopped dead"), msg="\{Repr(said)}")
}
