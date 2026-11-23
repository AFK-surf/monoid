///|
fn stage_test_policy(
  lane : @motion.StageLane,
  during_barrier : @motion.StageDuringBarrier,
  rekey? : Bool = false,
) -> @motion.StagePolicy {
  { lane, during_barrier, rekey_on_prev_change: rekey, hold_as_anchor: true, live_removable: true }
}

///|
fn stage_test_keep() -> @motion.StageIngestItem {
  { policy: stage_test_policy(Content, Keep), starts_barrier_until: None, custom_hold: None }
}

///|
fn stage_test_trailer() -> @motion.StageIngestItem {
  { policy: stage_test_policy(Trailer, DeferUntilBarriers, rekey=true), starts_barrier_until: None, custom_hold: None }
}

///|
fn stage_test_activity() -> @motion.StageIngestItem {
  { policy: stage_test_policy(Activity, CoMoveWithBarrier), starts_barrier_until: None, custom_hold: None }
}

///|
test "ListStage: zero-copy fast path, zero inspect on initial/non-staged, and O(tail) inspection" {
  let st = @motion.ListStage::new(tail_window=8, is_rekey=fn(k) { k.has_prefix("tr:") })
  let raw0 : Array[String] = []
  for i in 0..<100 {
    raw0.push("r:" + i.to_string())
  }
  raw0.push("tr:tail")
  let inspected = Ref(0)
  // Initial ingest must never call inspect, while still registering tail is_rekey keys
  let r0 = st.ingest(raw0, 0.0, true, fn(_) {
    inspected.val += 1
    stage_test_keep()
  })
  assert_eq(inspected.val, 0)
  assert_true(physical_equal(r0.visible, raw0))
  assert_eq(r0.next_due, None)

  // can_stage = false must also never call inspect
  let raw_nc = raw0.copy()
  raw_nc.insert(raw_nc.length() - 1, "r:100")
  let r_nc = st.ingest(raw_nc, 5.0, false, fn(_) {
    inspected.val += 1
    stage_test_keep()
  })
  assert_eq(inspected.val, 0)
  assert_eq(r_nc.visible[r_nc.visible.length() - 1], "tr:tail:1")
  assert_eq(st.unalias("tr:tail:1"), "tr:tail")

  // Incremental staged ingest inspects only newly arrived tail items
  inspected.val = 0
  let raw1 = raw_nc.copy()
  raw1.push("r:101")
  let r1 = st.ingest(raw1, 10.0, true, fn(_) {
    inspected.val += 1
    stage_test_keep()
  })
  assert_eq(inspected.val, 1)
  assert_eq(r1.visible[r1.visible.length() - 2], "tr:tail:1")
}

///|
test "ListStage: barrier defers trailers, co-moves same-batch activity, holds later activity" {
  let st = @motion.ListStage::new()
  let _ = st.ingest(["k:1"], 0.0, true, fn(_) { stage_test_keep() })

  // Same batch: barrier item + co-moving activity + deferred trailer
  let step1 = st.ingest(["k:1", "b:1", "act:1", "t:1"], 100.0, true, fn(k) {
    if k == "b:1" {
      { policy: stage_test_policy(Content, Keep), starts_barrier_until: Some(300.0), custom_hold: None }
    } else if k == "act:1" {
      stage_test_activity()
    } else if k == "t:1" {
      stage_test_trailer()
    } else {
      stage_test_keep()
    }
  })
  assert_eq(step1.visible, ["k:1", "b:1", "act:1"])
  assert_eq(step1.newly_held, ["t:1"])
  assert_eq(st.shows_at("act:1"), 300.0)
  assert_eq(step1.next_due, Some(300.0))

  // Mid-barrier: a second activity arrives in a later batch -> must be held until barrier ends
  let step2 = st.ingest(["k:1", "b:1", "act:1", "act:2", "t:1"], 150.0, true, fn(k) {
    if k == "act:2" {
      stage_test_activity()
    } else {
      stage_test_keep()
    }
  })
  assert_eq(step2.visible, ["k:1", "b:1", "act:1"])
  assert_eq(step2.newly_held, ["act:2"])

  // Extend barrier before tick: tick at 300 must reschedule rather than release mid-barrier
  st.extend_barrier(450.0)
  let tick_mid = st.tick(300.0)
  assert_eq(tick_mid.released, [])
  assert_eq(tick_mid.rescheduled.length(), 2)
  assert_eq(tick_mid.next_due, Some(450.0))
  assert_true(st.is_held("t:1"))
  assert_true(st.is_held("act:2"))

  // Tick at 450 releases both in one batch
  let tick_end = st.tick(450.0)
  assert_eq(tick_end.released.length(), 2)
  assert_eq(tick_end.visible, ["k:1", "b:1", "act:1", "act:2", "t:1"])
  assert_eq(tick_end.next_due, None)
}

///|
test "ListStage: custom hold with linger key, bridged pairs, and flush" {
  let st = @motion.ListStage::new()
  let _ = st.ingest(["u:1", "act:a"], 0.0, true, fn(_) { stage_test_keep() })

  // Custom hold arrives while act:a disappears from raw_keys -> act:a lingers after u:1
  let s1 = st.ingest(["u:1", "x:1", "u:2"], 50.0, true, fn(k) {
    if k == "x:1" {
      {
        policy: stage_test_policy(Content, Keep),
        starts_barrier_until: None,
        custom_hold: Some({ release_at: 250.0, has_custom_plan: true, linger_key: Some("act:a") }),
      }
    } else {
      stage_test_keep()
    }
  })
  assert_eq(s1.visible, ["u:1", "act:a", "u:2"])
  assert_true(st.is_lingering("act:a"))

  // Bridged pair check when no linger sits between u:1 and u:2
  let st2 = @motion.ListStage::new()
  let _ = st2.ingest(["u:1"], 0.0, true, fn(_) { stage_test_keep() })
  let _ = st2.ingest(["u:1", "x:1", "u:2"], 50.0, true, fn(k) {
    if k == "x:1" {
      {
        policy: stage_test_policy(Content, Keep),
        starts_barrier_until: None,
        custom_hold: Some({ release_at: 250.0, has_custom_plan: true, linger_key: None }),
      }
    } else {
      stage_test_keep()
    }
  })
  st2.recompute_bridged(fn(a, b) { a.has_prefix("u:") && b.has_prefix("u:") })
  assert_true(st2.is_bridged("u:2"))
  let fl = st2.flush()
  assert_eq(fl.flushed, ["x:1"])
  assert_true(st2.is_flushed("x:1"))
  assert_false(st2.is_bridged("u:2"))
  assert_eq(fl.visible, ["u:1", "x:1", "u:2"])

  // Tick releases custom hold and its linger
  let rel = st.tick(250.0)
  assert_eq(rel.released, ["x:1"])
  assert_eq(rel.released_lingers, ["act:a"])
  assert_false(st.is_lingering("act:a"))
  assert_eq(rel.visible, ["u:1", "x:1", "u:2"])

  // Dropping a held key mid-hold reports both dropped_held and dropped_lingers
  let st3 = @motion.ListStage::new()
  let _ = st3.ingest(["u:1", "act:b"], 0.0, true, fn(_) { stage_test_keep() })
  let _ = st3.ingest(["u:1", "x:2"], 10.0, true, fn(k) {
    if k == "x:2" {
      {
        policy: stage_test_policy(Content, Keep),
        starts_barrier_until: None,
        custom_hold: Some({ release_at: 200.0, has_custom_plan: true, linger_key: Some("act:b") }),
      }
    } else {
      stage_test_keep()
    }
  })
  assert_true(st3.is_lingering("act:b"))
  let drop_res = st3.ingest(["u:1"], 20.0, true, fn(_) { stage_test_keep() })
  assert_eq(drop_res.dropped_held, ["x:2"])
  assert_eq(drop_res.dropped_lingers, ["act:b"])
  assert_false(st3.is_lingering("act:b"))
}

///|
test "ListStage: rekey on predecessor change for multiple trailers without mutating input" {
  let st = @motion.ListStage::new(is_rekey=fn(k) { k.has_prefix("tr:") })
  let raw0 = ["k:1", "tr:a", "tr:b"]
  let s0 = st.ingest(raw0, 0.0, true, fn(k) {
    if k.has_prefix("tr:") {
      stage_test_trailer()
    } else {
      stage_test_keep()
    }
  })
  assert_true(physical_equal(s0.visible, raw0))

  // Insert k:2 before tr:a -> both tr:a and tr:b rekey deterministically, raw1 untouched
  let raw1 = ["k:1", "k:2", "tr:a", "tr:b"]
  let s1 = st.ingest(raw1, 10.0, true, fn(k) {
    if k.has_prefix("tr:") {
      stage_test_trailer()
    } else {
      stage_test_keep()
    }
  })
  assert_eq(raw1, ["k:1", "k:2", "tr:a", "tr:b"])
  assert_eq(s1.visible, ["k:1", "k:2", "tr:a:1", "tr:b:1"])
  assert_eq(st.unalias("tr:a:1"), "tr:a")
  assert_eq(st.unalias("tr:b:1"), "tr:b")

  // Re-ingesting identical sequence keeps aliases stable
  let s2 = st.ingest(raw1, 20.0, true, fn(_) { stage_test_keep() })
  assert_eq(s2.visible, ["k:1", "k:2", "tr:a:1", "tr:b:1"])

  // Trailer disappears then reappears after k:3 -> last_prev reset on absence, keeps gen=1
  let _ = st.ingest(["k:1", "k:2"], 30.0, true, fn(_) { stage_test_keep() })
  let s4 = st.ingest(["k:1", "k:2", "k:3", "tr:a"], 40.0, true, fn(k) {
    if k.has_prefix("tr:") {
      stage_test_trailer()
    } else {
      stage_test_keep()
    }
  })
  assert_eq(s4.visible, ["k:1", "k:2", "k:3", "tr:a:1"])
  assert_eq(st.unalias("tr:a:1"), "tr:a")
}

///|
fn fuzz_next(seed : Ref[Int]) -> Int {
  // Deterministic 31-bit LCG
  seed.val = (seed.val * 1103515245 + 12345) & 0x7fffffff
  seed.val
}

///|
fn assert_unique_keys(ks : Array[String]) -> Unit raise {
  let seen : Map[String, Bool] = Map([])
  for k in ks {
    assert_false(seen.contains(k))
    seen[k] = true
  }
}

///|
test "ListStage: deterministic out-of-order fuzz (240 rounds)" {
  let seed = Ref(42)
  for round in 0..<240 {
    let st = @motion.ListStage::new(tail_window=32)
    let raw : Array[String] = ["base:0", "base:1"]
    let mut now = 0.0
    let mut seq = 0
    let prev_trailer : Map[String, (String, String?)] = Map([])
    let init_res = st.ingest(raw.copy(), now, true, fn(_) { stage_test_keep() })
    assert_unique_keys(init_res.visible)

    let steps = 12 + (fuzz_next(seed) % 16)
    for _ in 0..<steps {
      now = now + (5 + (fuzz_next(seed) % 60)).to_double()
      let op = fuzz_next(seed) % 10
      if op == 0 {
        // Start or extend a barrier with a new content key
        seq += 1
        let bk = "b:" + round.to_string() + ":" + seq.to_string()
        let dur = (40 + (fuzz_next(seed) % 200)).to_double()
        raw.push(bk)
        let snap = raw.copy()
        let res = st.ingest(snap, now, true, fn(k) {
          if k == bk {
            { policy: stage_test_policy(Content, Keep), starts_barrier_until: Some(now + dur), custom_hold: None }
          } else {
            stage_test_keep()
          }
        })
        assert_unique_keys(res.visible)
      } else if op == 1 {
        // Extend barrier directly
        st.extend_barrier(now + (30 + (fuzz_next(seed) % 150)).to_double())
      } else if op == 2 {
        // Add an activity key
        seq += 1
        let ak = "act:" + seq.to_string()
        raw.push(ak)
        let snap = raw.copy()
        let barrier_before = st.barrier_until()
        let res = st.ingest(snap, now, true, fn(k) {
          if k == ak {
            stage_test_activity()
          } else {
            stage_test_keep()
          }
        })
        assert_unique_keys(res.visible)
        if barrier_before > now {
          assert_true(st.is_held(ak))
          assert_false(res.visible.contains(ak))
        }
      } else if op == 3 {
        // Add or re-add a trailer key
        let tk = "tr:" + (fuzz_next(seed) % 3).to_string()
        if !raw.contains(tk) {
          let barrier_before = st.barrier_until()
          let had_held = st.has_held()
          raw.push(tk)
          let snap = raw.copy()
          let res = st.ingest(snap, now, true, fn(k) {
            if k == tk {
              stage_test_trailer()
            } else {
              stage_test_keep()
            }
          })
          assert_unique_keys(res.visible)
          if barrier_before > now || (had_held && st.next_due_at().map_or(-1.0, fn(d) { d }) > now) {
            assert_true(st.is_held(tk))
          }
        }
      } else if op == 4 {
        // Custom held item with optional linger
        seq += 1
        let ck = "c:" + seq.to_string()
        let use_linger = (fuzz_next(seed) % 2) == 0
        let lk = if use_linger { Some("lg:" + (fuzz_next(seed) % 2).to_string()) } else { None }
        let dur = (20 + (fuzz_next(seed) % 180)).to_double()
        raw.push(ck)
        let snap = raw.copy()
        let res = st.ingest(snap, now, true, fn(k) {
          if k == ck {
            {
              policy: stage_test_policy(Content, Keep),
              starts_barrier_until: None,
              custom_hold: Some({ release_at: now + dur, has_custom_plan: true, linger_key: lk }),
            }
          } else {
            stage_test_keep()
          }
        })
        assert_unique_keys(res.visible)
        assert_true(st.is_held(ck))
      } else if op == 5 {
        // Drop a random tail key (possibly held)
        if raw.length() > 2 {
          let idx = 2 + (fuzz_next(seed) % (raw.length() - 2))
          raw.remove(idx) |> ignore
          let res = st.ingest(raw.copy(), now, true, fn(_) { stage_test_keep() })
          assert_unique_keys(res.visible)
        }
      } else if op == 6 {
        // Insert a content item before trailing items to trigger predecessor-change rekey
        seq += 1
        let nk = "n:" + seq.to_string()
        let pos = if raw.length() > 2 { raw.length() - 1 } else { raw.length() }
        raw.insert(pos, nk)
        let res = st.ingest(raw.copy(), now, true, fn(_) { stage_test_keep() })
        assert_unique_keys(res.visible)
      } else if op == 7 {
        // Tick at current time
        let barrier_active = st.barrier_until() > now
        let rel = st.tick(now)
        assert_unique_keys(rel.visible)
        if barrier_active {
          assert_eq(rel.released, [])
        }
      } else if op == 8 {
        // Flush
        let fl = st.flush()
        assert_unique_keys(fl.visible)
        assert_false(st.has_held())
      } else {
        // Tick at next_due_at if any
        match st.next_due_at() {
          Some(due) => {
            if due > now {
              now = due
            }
            let rel = st.tick(now)
            assert_unique_keys(rel.visible)
          }
          None => ()
        }
      }
      // Verify rekey monotonicity & invertibility on visible sequence
      let vis = st.visible_keys()
      for idx, vk in vis {
        let rk = st.unalias(vk)
        if rk.has_prefix("tr:") {
          let prev_k = if idx > 0 { Some(vis[idx - 1]) } else { None }
          match prev_trailer.get(rk) {
            Some((was_vk, Some(was_prev))) if prev_k != Some(was_prev) =>
              assert_true(vk != was_vk)
            _ => ()
          }
          prev_trailer[rk] = (vk, prev_k)
        }
      }
      for rk in prev_trailer.keys().collect() {
        let present = vis.iter().any(fn(vk) { st.unalias(vk) == rk })
        if !present {
          let (was_vk, _) = prev_trailer[rk]
          prev_trailer[rk] = (was_vk, None)
        }
      }
    }

    // Drain to final time: zero deadlock, all items released, visible.map(unalias) == raw
    let mut drain_guard = 0
    while st.has_held() && drain_guard < 32 {
      drain_guard += 1
      let next_t = match st.next_due_at() {
        Some(d) => if d > st.barrier_until() { d } else { st.barrier_until() }
        None => st.barrier_until()
      }
      let target = if next_t > now { next_t } else { now + 1.0 }
      now = target
      let _ = st.tick(now)
    }
    assert_false(st.has_held())
    let final_vis = st.visible_keys()
    assert_unique_keys(final_vis)
    let unaliased = final_vis.map(fn(k) { st.unalias(k) })
    assert_eq(unaliased, raw)
  }
}
