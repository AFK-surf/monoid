// Whitebox tests for async notification permission polling and reactivity (notify.mbt).

///|
test "notice_permission_state: first notices_arrive wakes pre-frame subscriber when settled before frame" {
  let prev = @hostapi.host()
  let raw_state = Ref(5) // 5 => (true, "unknown") pending
  let h : @hostapi.Host = {
    ..@hostapi.Host::noop(),
    platform: fn() { 0 },
    nt_state: fn(what) { if what == 0 { raw_state.val } else { -1 } },
  }
  @hostapi.set_host(h)
  notices_reset()
  let seen : Array[(Bool, String)] = []
  let read = @signals.computed(fn(_) {
    let s = notice_permission_state()
    seen.push(s)
    s
  })
  // Before the first notices_arrive(): last_arrived is None, getter reads host live and sees pending.
  assert_eq(read.get(), (true, "unknown"))
  // Host settles before the first notices_arrive() runs.
  raw_state.val = 0 // 0 => (false, "unknown")
  notices_arrive()
  assert_eq(read.get(), (false, "unknown"))
  assert_eq(seen, [(true, "unknown"), (false, "unknown")])
  // Subsequent transition to granted also increments perm_tick.
  raw_state.val = 1 // 1 => (false, "granted")
  notices_arrive()
  assert_eq(read.get(), (false, "granted"))
  notices_reset()
  @hostapi.set_host(prev)
}

///|
test "notice_permission_state: live between-frame read sets saw_other so ABA flip back still wakes subscriber" {
  let prev = @hostapi.host()
  let raw_state = Ref(1) // granted
  let h : @hostapi.Host = {
    ..@hostapi.Host::noop(),
    platform: fn() { 0 },
    nt_state: fn(what) { if what == 0 { raw_state.val } else { -1 } },
  }
  @hostapi.set_host(h)
  notices_reset()
  // Frame 1 establishes last_arrived = Some((false, "granted")).
  notices_arrive()
  let seen : Array[(Bool, String)] = []
  let read = @signals.computed(fn(_) {
    let s = notice_permission_state()
    seen.push(s)
    s
  })
  assert_eq(read.get(), (false, "granted"))
  // Between frames host flips to denied; a live reader sees denied immediately and marks saw_other.
  raw_state.val = 2
  assert_eq(notice_permission_state(), (false, "denied"))
  // Before frame 2 host flips back to granted (ABA relative to last_arrived): notices_arrive() must still bump perm_tick.
  raw_state.val = 1
  notices_arrive()
  assert_eq(read.get(), (false, "granted"))
  assert_eq(seen, [(false, "granted"), (false, "granted")])
  notices_reset()
  @hostapi.set_host(prev)
}

///|
test "notice_permission_state: multi-subscriber wakeup when one subscriber reads between frames" {
  let prev = @hostapi.host()
  let raw_state = Ref(1) // granted
  let h : @hostapi.Host = {
    ..@hostapi.Host::noop(),
    platform: fn() { 0 },
    nt_state: fn(what) { if what == 0 { raw_state.val } else { -1 } },
  }
  @hostapi.set_host(h)
  notices_reset()
  notices_arrive()
  let s1 = @signals.computed(fn(_) { notice_permission_state() })
  let s2 = @signals.computed(fn(_) { notice_permission_state() })
  assert_eq(s1.get(), (false, "granted"))
  assert_eq(s2.get(), (false, "granted"))
  // Between frames host flips to denied and only s2 (or an untracked/live read) observes denied.
  raw_state.val = 2
  assert_eq(notice_permission_state(), (false, "denied"))
  // Frame 2 notices_arrive() bumps perm_tick so s1 also wakes and observes denied.
  notices_arrive()
  assert_eq(s1.get(), (false, "denied"))
  assert_eq(s2.get(), (false, "denied"))
  notices_reset()
  @hostapi.set_host(prev)
}
