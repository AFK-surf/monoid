///|
test "gamepads_follow reports once on initial mount, stops while parked, and wakes without catch-up storm" {
  let pad : @hostapi.Gamepad = {
    index: 0,
    buttons: 1,
    lx: 0.5,
    ly: 0.0,
    rx: 0.0,
    ry: 0.0,
    lt: 0.0,
    rt: 0.0,
  }
  let active = @signals.signal(false)
  let on = @signals.signal(true)
  let calls = Ref(0)
  let told : Array[(Int, @hostapi.Gamepad?)] = []
  let gp_root : Ref[@view.View?] = Ref(None)
  let t = Tester::tree(
    fn(root) {
      root.pick_kept(at_once=true, fn() { active.get() }, fn(slot, show) {
        if show {
          gp_root.val = Some(slot)
          gamepads_follow(slot, fn() { on.get() }, fn(i, g) { told.push((i, g)) })
        }
      })
    },
    w=400.0,
    h=300.0,
  )
  t.set_gamepads([pad])
  let h = @hostapi.host()
  let orig = h.gamepads
  h.gamepads = fn(out) {
    calls.val += 1
    orig(out)
  }
  // True first mount with `on == true`: when_active + reacts(on) must coalesce to 1 look and 1 `then` report.
  active.set(true)
  t.draw()
  assert_eq(told.length(), 1, msg="initial mount must report to `then` exactly once")
  assert_eq(calls.val, 1, msg="initial mount must poll gamepads() exactly once")
  // Park for 10 minutes (gamepads_looked_ms * 600.0): 0 polls and 0 timeline entries while parked.
  active.set(false)
  t.draw()
  let gv = gp_root.val.unwrap()
  assert_eq(t.subtree_timeline_count(gv), 0, msg="parked gamepads_follow must have 0 timeline entries")
  calls.val = 0
  told.clear()
  t.run_for(gamepads_looked_ms * 600.0)
  assert_eq(calls.val, 0, msg="parked gamepads_follow must not poll gamepads() over 10 minutes")
  assert_eq(told.length(), 0, msg="parked gamepads_follow must not emit reports")
  // Wake after 10 minutes: must perform at most 1 look / 1 gamepads() call (no catch-up storm).
  active.set(true)
  t.draw()
  assert_eq(calls.val, 1, msg="waking after 10 min park must poll gamepads() at most once, not catch up")
  assert_eq(told.length(), 1, msg="waking after 10 min park must report current pad state once")
  h.gamepads = orig
  run_let_go()
}
