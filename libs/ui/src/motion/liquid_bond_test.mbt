// Tests for LiquidBond capillary liquid bridge hysteresis, cross-time solver, and 2D surface gap functions.

///|
test "liquid bond: separated approach has strictly zero attraction until physical contact" {
  let bond = @motion.LiquidBond::new(merged=false, merge_max=24.0)
  assert_eq(bond.is_bonded(), false)
  assert_eq(bond.merge_at(0.0), 0.0)
  // Approaching from 48pt down to 0.01pt: zero attraction, never fuses early
  for i, g in [48.0, 20.0, 8.0, 3.0, 1.0, 0.1, 0.01] {
    let t = (i + 1).to_double() * 16.0
    assert_eq(bond.update(g, at=t), @motion.BondEvent::Steady)
    assert_eq(bond.is_bonded(), false)
    assert_eq(bond.merge_at(t), 0.0)
  }
  // Exact contact (gap == 0.0) triggers Fused and blooms merge to merge_max
  let t_hit = 200.0
  assert_eq(bond.update(0.0, at=t_hit), @motion.BondEvent::Fused)
  assert_eq(bond.is_bonded(), true)
  assert_true(bond.merge_at(t_hit + 50.0) > 5.0)
  assert_true((bond.merge_at(bond.end() + 10.0) - 24.0).abs() < 0.02)
  assert_true(bond.recoil_at(t_hit + 30.0) > 0.0)
  assert_true(bond.recoil_at(bond.end() + 10.0).abs() < 0.002)
}

///|
test "liquid bond: merged stretch holds bridge until break_gap, snaps cleanly with zero overshoot and zero re-attraction" {
  let bond = @motion.LiquidBond::new(merged=true, merge_max=24.0, break_gap=10.8)
  assert_eq(bond.is_bonded(), true)
  assert_eq(bond.merge_at(0.0), 24.0)
  // Pulling through 0 < gap < break_gap stays bonded with full liquid bridge
  for i, g in [0.5, 2.0, 5.0, 9.0, 10.79] {
    let t = (i + 1).to_double() * 16.0
    assert_eq(bond.update(g, at=t), @motion.BondEvent::Steady)
    assert_eq(bond.is_bonded(), true)
    assert_eq(bond.merge_at(t), 24.0)
  }
  // Crossing break_gap triggers Split immediately
  let t_split = 200.0
  assert_eq(bond.update(10.8, at=t_split), @motion.BondEvent::Split)
  assert_eq(bond.is_bonded(), false)
  // Critically damped decay: monotonic non-increasing and strictly >= 0.0 (zero bounce)
  let mut prev = bond.merge_at(t_split)
  for step in 1..<=40 {
    let cur = bond.merge_at(t_split + step.to_double() * 8.0)
    assert_true(cur <= prev + 0.000001, msg="step=\{step} cur=\{cur} prev=\{prev}")
    assert_true(cur >= 0.0, msg="step=\{step} cur=\{cur}")
    prev = cur
  }
  let t_rest = bond.end() + 10.0
  assert_eq(bond.merge_at(t_rest), 0.0)
  // Returning close to gap = 1.0 or 0.05 after splitting: strictly zero magnetic re-attraction
  for i, g in [8.0, 4.0, 2.0, 1.0, 0.05] {
    let t = t_rest + (i + 1).to_double() * 16.0
    assert_eq(bond.update(g, at=t), @motion.BondEvent::Steady)
    assert_eq(bond.is_bonded(), false)
    assert_eq(bond.merge_at(t), 0.0)
  }
  // Only physical contact again re-fuses
  assert_eq(bond.update(-0.01, at=t_rest + 200.0), @motion.BondEvent::Fused)
  assert_eq(bond.is_bonded(), true)
}

///|
test "liquid bond: reset puts state immediately with zero residual motion" {
  let bond = @motion.LiquidBond::new(merged=false, merge_max=20.0)
  assert_eq(bond.update(0.0, at=100.0), @motion.BondEvent::Fused)
  bond.reset(false)
  assert_eq(bond.is_bonded(), false)
  assert_eq(bond.merge_at(120.0), 0.0)
  assert_eq(bond.recoil_at(120.0), 0.0)
  bond.reset(true)
  assert_eq(bond.is_bonded(), true)
  assert_eq(bond.merge_at(120.0), 20.0)
}

///|
test "liquid bond: cross_time precision and 2D surface gap functions" {
  // Linear gap from -56 to +10 over [100, 600] => crosses 6.5 at t = 100 + 500 * (62.5 / 66) = 573.4848...
  let gap_open = fn(t : Double) { -56.0 + 66.0 * ((t - 100.0) / 500.0) }
  let t_split = @motion.liquid_bond_cross_time(100.0, 600.0, gap_open, true, 6.5).unwrap()
  let expected_split = 100.0 + 500.0 * (62.5 / 66.0)
  assert_true((t_split - expected_split).abs() < 0.01, msg="t_split=\{t_split} expected=\{expected_split}")
  // Closing from +10 to -56 over [100, 600] => crosses 0.0 at t = 100 + 500 * (10 / 66) = 175.7575...
  let gap_close = fn(t : Double) { 10.0 - 66.0 * ((t - 100.0) / 500.0) }
  let t_touch = @motion.liquid_bond_cross_time(100.0, 600.0, gap_close, false, 0.0).unwrap()
  let expected_touch = 100.0 + 500.0 * (10.0 / 66.0)
  assert_true((t_touch - expected_touch).abs() < 0.01, msg="t_touch=\{t_touch} expected=\{expected_touch}")
  // Never crosses
  assert_eq(@motion.liquid_bond_cross_time(100.0, 600.0, fn(_) { 5.0 }, true, 10.0), None)
  // Circle gap
  assert_true((@motion.circle_gap(0.0, 0.0, 28.0, 60.0, 0.0, 28.0) - 4.0).abs() < 1.0e-9)
  assert_true((@motion.circle_gap(0.0, 0.0, 28.0, 56.0, 0.0, 28.0) - 0.0).abs() < 1.0e-9)
  assert_true((@motion.circle_gap(0.0, 0.0, 28.0, 46.0, 0.0, 28.0) - (-10.0)).abs() < 1.0e-9)
  // Capsule gap x
  assert_eq(@motion.capsule_gap_x(200.0, 206.5), 6.5)
  // Rounded rect gap: horizontal capsules
  assert_true((@motion.rounded_rect_gap(0.0, 0.0, 160.0, 56.0, 28.0, 164.0, 0.0, 56.0, 56.0, 28.0) - 4.0).abs() < 1.0e-9)
  assert_true((@motion.rounded_rect_gap(0.0, 0.0, 160.0, 56.0, 28.0, 160.0, 0.0, 56.0, 56.0, 28.0) - 0.0).abs() < 1.0e-9)
  assert_true((@motion.rounded_rect_gap(0.0, 0.0, 160.0, 56.0, 28.0, 150.0, 0.0, 56.0, 56.0, 28.0) - (-10.0)).abs() < 1.0e-9)
  // Rounded rect gap: diagonal corner-to-corner distance matches circle gap between corner centers
  let diag = @motion.rounded_rect_gap(0.0, 0.0, 60.0, 60.0, 20.0, 70.0, 70.0, 60.0, 60.0, 20.0)
  // Core A right-bottom corner: (40, 40); Core B left-top corner: (90, 90); dist = sqrt(50^2+50^2) - 40
  let expected_diag = (5000.0).sqrt() - 40.0
  assert_true((diag - expected_diag).abs() < 1.0e-9, msg="diag=\{diag} expected=\{expected_diag}")
}

///|
test "liquid bond: frame-rate invariance at 60/120/24/7 fps" {
  // Sample the same fuse/split trajectory at different frame rates: values at identical timestamps match to the bit
  let make_bond = fn() raise {
    let b = @motion.LiquidBond::new(merged=false, merge_max=24.0, break_gap=10.8)
    assert_eq(b.update(0.0, at=100.0), @motion.BondEvent::Fused)
    assert_eq(b.update(11.0, at=500.0), @motion.BondEvent::Split)
    b
  }
  let reference = make_bond()
  for fps in [60.0, 120.0, 24.0, 7.0] {
    let b = make_bond()
    let dt = 1000.0 / fps
    let mut t = 0.0
    while t <= 1200.0 {
      assert_eq(b.merge_at(t), reference.merge_at(t))
      assert_eq(b.recoil_at(t), reference.recoil_at(t))
      t += dt
    }
  }
}
