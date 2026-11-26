// Unified curtain motion (`CurtainRun`):
// - Strict pixel-grid conservation `Σ_j slot_h_j(t) == R(t)` across 1x/2x/2.75x/3x/3.5x grids
// - At most one frontier row partially exposed at any moment; inner children laid out at full natural height
// - Smooth mid-flight reversal via standard `come_back_path` preserving `wholes`
// - Multiple `CurtainRun` segments in one `ComeGroup` sharing start/end and duration

///|
test "CurtainRun pixel-grid conservation and single frontier across grids" {
  let grids = [0.0, 1.0, 2.0, 2.75, 3.0, 3.5]
  let raw_hs = [56.0, 62.5, 48.0, 56.0, 40.3]
  for g in grids {
    // Opening: 0 -> total
    let open = @flex.CurtainRun::new(raw_hs, 0.0, 0.0, 10000.0, 100.0, grid=g)
    let dur = open.ends - open.at
    assert_true(dur >= @flex.move_least_ms && dur <= @flex.move_most_ms)
    let mut prev_r = -1.0
    for step in 0..=40 {
      let at = open.at + dur * step.to_double() / 40.0
      let r = open.total_at(at)
      assert_true(r >= prev_r - 1.0e-9, msg="opening R(t) must be monotonic at grid=\{g}")
      prev_r = r
      let mut sum = 0.0
      let mut partial = 0
      for j in 0..<open.wholes.length() {
        let sh = open.slot_height_at(j, at)
        assert_true(sh >= -1.0e-9 && sh <= open.wholes[j] + 1.0e-9)
        if sh > 1.0e-6 && sh < open.wholes[j] - 1.0e-6 {
          partial += 1
        }
        sum = sum + sh
      }
      assert_true(partial <= 1, msg="at most one frontier row partially exposed at grid=\{g}")
      assert_true((sum - r).abs() <= 1.0e-6, msg="sum(slot_h) must equal R(t) at grid=\{g}: sum=\{sum} r=\{r}")
      if g > 0.0 {
        let px = r * g
        assert_true((px - px.round()).abs() <= 1.0e-5, msg="R(t) must lie on pixel grid=\{g}")
      }
    }
    assert_true((open.total_at(open.ends) - open.total).abs() <= 1.0e-6)

    // Closing: total -> 0
    let close = @flex.CurtainRun::new(raw_hs, open.total, 0.0, 0.0, 500.0, grid=g)
    let cdur = close.ends - close.at
    let mut prev_c = close.total + 1.0
    for step in 0..=40 {
      let at = close.at + cdur * step.to_double() / 40.0
      let r = close.total_at(at)
      assert_true(r <= prev_c + 1.0e-9, msg="closing R(t) must be monotonic at grid=\{g}")
      prev_c = r
      let mut sum = 0.0
      for j in 0..<close.wholes.length() {
        sum = sum + close.slot_height_at(j, at)
      }
      assert_true((sum - r).abs() <= 1.0e-6, msg="closing sum(slot_h) must equal R(t) at grid=\{g}")
    }
    assert_true(close.total_at(close.ends).abs() <= 1.0e-6)
  }
}

///|
test "CurtainRun layout in rows_grid column keeps inner content full height and moves sibling smoothly" {
  let g = 2.75
  let col = @flex.Node::new()
  col.style.position = Absolute
  col.style.set_width(Pt(320.0))
  col.style.rows_grid = g
  let head = @flex.Node::new()
  head.style.set_height(Pt(36.0))
  head.style.shrink = 0.0
  col.add(head)
  let raw_hs = [56.0, 56.0, 56.0]
  let run = @flex.CurtainRun::new(raw_hs, 0.0, 0.0, 10000.0, 0.0, grid=g)
  let slots : Array[@flex.Node] = []
  let inners : Array[@flex.Node] = []
  for j, h in raw_hs {
    let slot = @flex.Node::new()
    slot.style.shrink = 0.0
    let inner = @flex.Node::new()
    inner.style.set_height(Pt(h))
    inner.style.shrink = 0.0
    slot.add(inner)
    slot.style.set_come_curtain(Some((run, j)))
    slot.style.come_from = 0.0
    slot.style.come_to = 1.0
    slot.style.come_at = 0.0
    slot.style.come_now = 0.0
    slot.style.come_ends = run.ends
    col.add(slot)
    slots.push(slot)
    inners.push(inner)
  }
  let foot = @flex.Node::new()
  foot.style.set_height(Pt(40.0))
  foot.style.shrink = 0.0
  col.add(foot)

  let dur = run.ends
  for step in 0..=20 {
    let at = dur * step.to_double() / 20.0
    for s in slots {
      s.style.come_now = at
    }
    @flex.compute(col, round=false, reuse=false, grid=g)
    let r = run.total_at(at)
    let mut sum = 0.0
    for j, s in slots {
      sum = sum + s.height
      // Inner content is always laid out at its full natural height (never compressed).
      assert_true((inners[j].height - raw_hs[j]).abs() <= 0.01)
    }
    assert_true((sum - r).abs() <= 1.0e-5, msg="laid slot sum=\{sum} vs R=\{r} at t=\{at}")
    assert_true((foot.top - (head.height + r)).abs() <= 1.0e-4, msg="foot.top=\{foot.top} expected=\{head.height + r}")
  }
}

///|
test "CurtainRun mid-flight reversal uses come_back_path without height jump and preserves wholes" {
  let hs = [56.0, 64.0, 52.0]
  let open = @flex.CurtainRun::new(hs, 0.0, 0.0, 1000.0, 0.0, grid=2.0)
  let t_rev = 80.0
  let (r_now, v_now) = open.state_at(t_rev)
  assert_true(r_now > 10.0 && r_now < open.total - 10.0)
  assert_true(v_now > 0.0)
  let rev = @flex.CurtainRun::new(open.wholes, r_now, v_now, 0.0, t_rev, grid=2.0)
  assert_eq(rev.wholes, open.wholes)
  let (r0, v0) = rev.state_at(t_rev)
  assert_true((r0 - r_now).abs() <= 1.0e-6, msg="reversal must start at exact R_now")
  assert_true((v0 - v_now).abs() <= 1.0e-6, msg="reversal must preserve velocity v_now")
  assert_true(rev.ends > t_rev + @flex.move_least_ms)
  assert_true(rev.total_at(rev.ends).abs() <= 1.0e-6)
}

///|
test "Two CurtainRuns in one ComeGroup share scalar group timing and land together" {
  let run_a = @flex.CurtainRun::new([56.0, 56.0], 112.0, 0.0, 0.0, 100.0, grid=2.0)
  let run_b = @flex.CurtainRun::new([56.0, 56.0, 56.0, 56.0], 224.0, 0.0, 0.0, 100.0, grid=2.0)
  let g = @flex.ComeGroup::new(100.0)
  for j in 0..<2 {
    let s = @flex.Style::new()
    s.set_come_curtain(Some((run_a, j)))
    s.come_from = 56.0
    s.come_to = 0.0
    s.come_goal = 0.0
    s.come_at = 100.0
    g.members.push(s)
  }
  for j in 0..<4 {
    let s = @flex.Style::new()
    s.set_come_curtain(Some((run_b, j)))
    s.come_from = 56.0
    s.come_to = 0.0
    s.come_goal = 0.0
    s.come_at = 100.0
    g.members.push(s)
  }
  @flex.come_group_set(g)
  assert_true(g.set)
  assert_eq(run_a.ends, run_b.ends)
  // Duration is driven by the longer segment's total (224pt), not a single row (56pt).
  assert_eq(run_a.ends - 100.0, @flex.move_ms(224.0))
  // Both reach 0 at the exact same moment.
  assert_true(run_a.total_at(run_a.ends).abs() <= 1.0e-6)
  assert_true(run_b.total_at(run_b.ends).abs() <= 1.0e-6)
}
