// Forward motion verification probes on Tester: sample frames over a transition window and assert continuity
// invariants that catch instant cuts, initial stalls, and frame-0 geometry collapses.

///|
/// Sample `probe(self, elapsed_ms)` from `t = 0.0` (current drawn state) to `ms` every `step` ms using `run_for`.
pub fn[T] Tester::sample_frames(
  self : Tester,
  ms : Double,
  step? : Double = 16.0,
  probe : (Tester, Double) -> T,
) -> Array[(Double, T)] {
  let dt_step = if step > 0.0 { step } else { 16.0 }
  let out : Array[(Double, T)] = [(0.0, probe(self, 0.0))]
  let mut elapsed = 0.0
  while elapsed + 1.0e-6 < ms {
    let dt = if elapsed + dt_step > ms { ms - elapsed } else { dt_step }
    self.run_for(dt)
    elapsed = elapsed + dt
    out.push((elapsed, probe(self, elapsed)))
  }
  out
}

///|
/// Check that a sampled alpha/opacity curve transitions smoothly from `from` to `to` without an instant hard cut:
/// - consecutive samples differ by at most `max_step`
/// - at least `min_mid_frames` samples lie strictly inside the intermediate band `(0.05, 0.95)`
/// - start is near `from` and end reaches near `to`.
pub fn check_smooth_fade(
  samples : Array[(Double, Double)],
  from~ : Double,
  to~ : Double,
  max_step? : Double = 0.45,
  min_mid_frames? : Int = 2,
) -> Result[Unit, String] {
  if samples.length() < 2 {
    return Err("smooth_fade: need at least 2 samples, got \{samples.length()}")
  }
  let first = samples[0].1
  if (first - from).abs() > max_step {
    return Err("smooth_fade: start alpha \{first} jumped from expected \{from} (max_step \{max_step})")
  }
  let last = samples[samples.length() - 1].1
  if (last - to).abs() > 0.15 {
    return Err("smooth_fade: end alpha \{last} did not reach expected \{to}")
  }
  let lo = (if from < to { from } else { to }) + 0.05
  let hi = (if from > to { from } else { to }) - 0.05
  let mut mid = 0
  for i = 0; i < samples.length(); i = i + 1 {
    let (t, a) = samples[i]
    if a > lo && a < hi {
      mid = mid + 1
    }
    if i > 0 {
      let prev = samples[i - 1].1
      let d = (a - prev).abs()
      if d > max_step {
        return Err("smooth_fade: hard cut at t=\{t}ms: |\{a} - \{prev}| = \{d} > \{max_step}")
      }
    }
  }
  if mid < min_mid_frames {
    return Err("smooth_fade: only \{mid} intermediate frames in (\{lo}, \{hi}), expected >= \{min_mid_frames}")
  }
  Ok(())
}

///|
/// Check that a sampled coordinate/value begins moving within `delay_ms + start_window_ms` by at least `min_delta`
/// relative to its baseline at/before `delay_ms`. Catches dead-stall delays like `up_late` or excess carry delays.
pub fn check_no_stall(
  samples : Array[(Double, Double)],
  delay_ms~ : Double,
  start_window_ms? : Double = 40.0,
  min_delta? : Double = 1.5,
) -> Result[Unit, String] {
  if samples.length() < 2 {
    return Err("no_stall: need at least 2 samples, got \{samples.length()}")
  }
  let mut base = samples[0].1
  for s in samples {
    if s.0 <= delay_ms + 1.0e-6 {
      base = s.1
    } else {
      break
    }
  }
  let deadline = delay_ms + start_window_ms
  let mut max_delta = 0.0
  let mut checked = false
  for s in samples {
    if s.0 > delay_ms + 1.0e-6 && s.0 <= deadline + 1.0e-6 {
      let d = (s.1 - base).abs()
      if d > max_delta {
        max_delta = d
      }
      checked = true
    } else if !checked && s.0 > deadline {
      let d = (s.1 - base).abs()
      if d > max_delta {
        max_delta = d
      }
      checked = true
      break
    }
  }
  if max_delta < min_delta {
    return Err(
      "no_stall: stalled within delay=\{delay_ms}ms + window=\{start_window_ms}ms (max_delta=\{max_delta} < \{min_delta})",
    )
  }
  Ok(())
}

///|
/// Check that a sampled rectangle `(x, y, w, h)` starts continuously from `start_rect` on frame 0 (no top-cut or
/// height collapse > `max_frame0_jump`) and moves without mid-flight jumps > `max_step_jump`.
pub fn check_rect_continuity(
  samples : Array[(Double, (Double, Double, Double, Double))],
  start_rect~ : (Double, Double, Double, Double),
  max_frame0_jump? : Double = 2.5,
  max_step_jump? : Double = 60.0,
) -> Result[Unit, String] {
  if samples.is_empty() {
    return Err("rect_continuity: empty samples")
  }
  let rect_diff = fn(a : (Double, Double, Double, Double), b : (Double, Double, Double, Double)) {
    let dx = (a.0 - b.0).abs()
    let dy = (a.1 - b.1).abs()
    let dw = (a.2 - b.2).abs()
    let dh = (a.3 - b.3).abs()
    let m1 = if dx > dy { dx } else { dy }
    let m2 = if dw > dh { dw } else { dh }
    if m1 > m2 { m1 } else { m2 }
  }
  let f0 = samples[0].1
  let d0 = rect_diff(f0, start_rect)
  if d0 > max_frame0_jump {
    return Err(
      "rect_continuity: frame 0 jump \{d0} > \{max_frame0_jump} (got \{rect_text(f0)}, expected start \{rect_text(start_rect)})",
    )
  }
  for i = 1; i < samples.length(); i = i + 1 {
    let prev = samples[i - 1].1
    let cur = samples[i].1
    let d = rect_diff(cur, prev)
    if d > max_step_jump {
      return Err(
        "rect_continuity: step jump at t=\{samples[i].0}ms: \{d} > \{max_step_jump} (from \{rect_text(prev)} to \{rect_text(cur)})",
      )
    }
  }
  Ok(())
}
