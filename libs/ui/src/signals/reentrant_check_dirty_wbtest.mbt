// Re-entrant untracked read of a downstream computed while an upstream dependency is mid-update (RECURSED_CHECK)
// must not clear PENDING on the downstream chain, or shallow_propagate will skip marking it DIRTY once the upstream
// update finishes with a new value.

///|
test "check_dirty keeps PENDING when a dep is mid-update (RECURSED_CHECK)" {
  let src = signal(1)
  let c_ref : Ref[Computed[Int]?] = Ref(None)
  let a = computed(fn(_) {
    let v = src.get()
    match c_ref.val {
      Some(c) => untracked(fn() { c.get() }) |> ignore
      None => ()
    }
    v * 10
  })
  let b_runs = Ref(0)
  let b = computed(fn(_) {
    b_runs.val += 1
    a.get() + 1
  })
  let c = computed(fn(_) { b.get() + 1 })

  let up_seen = Ref(0)
  let down_seen = Ref(0)
  let w_up_dirty = Ref(false)
  let w_down_dirty = Ref(false)
  let w_up = watch(fn() { w_up_dirty.val = true })
  let w_down = watch(fn() { w_down_dirty.val = true })

  // Initial reads: w_up watches `a`, w_down watches `c` (a -> b -> c).
  up_seen.val = w_up.read(fn() { a.get() })
  down_seen.val = w_down.read(fn() { c.get() })
  assert_eq(up_seen.val, 10)
  assert_eq(down_seen.val, 12)
  assert_eq(b_runs.val, 1)

  // Now enable the re-entrant untracked read of `c` from inside `a`'s getter.
  c_ref.val = Some(c)

  // Mutate `src`: w_up runs before w_down, pulls `a`, whose getter calls untracked(c.get()) while `a` has
  // RECURSED_CHECK. `b` and `c` must keep PENDING so shallow_propagate marks `b` DIRTY when `a` finishes.
  src.set(2)
  assert_true(w_up_dirty.val)
  assert_true(w_down_dirty.val)
  w_up_dirty.val = false
  w_down_dirty.val = false
  up_seen.val = w_up.read(fn() { a.get() })
  down_seen.val = w_down.read(fn() { c.get() })
  assert_eq(up_seen.val, 20)
  assert_eq(down_seen.val, 22)
  assert_eq(b_runs.val, 2)
  assert_eq(c.get(), 22)

  w_up.stop()
  w_down.stop()
}

///|
test "check_dirty settles cleanly when a mid-update dep finishes unchanged" {
  let src = signal(1)
  let c_ref : Ref[Computed[Int]?] = Ref(None)
  // Always returns 0 so `a` finishes unchanged when `src` changes.
  let a = computed(fn(_) {
    let _ = src.get()
    match c_ref.val {
      Some(c) => untracked(fn() { c.get() }) |> ignore
      None => ()
    }
    0
  })
  let b_runs = Ref(0)
  let b = computed(fn(_) {
    b_runs.val += 1
    a.get() + 1
  })
  let c = computed(fn(_) { b.get() + 1 })

  let w_up = watch(fn() {  })
  let w_down = watch(fn() {  })
  assert_eq(w_up.read(fn() { a.get() }), 0)
  assert_eq(w_down.read(fn() { c.get() }), 2)
  assert_eq(b_runs.val, 1)

  c_ref.val = Some(c)

  src.set(2)
  assert_eq(w_up.read(fn() { a.get() }), 0)
  // `b` and `c` did not recompute because `a` was unchanged, and reading `c` clears PENDING cleanly.
  assert_eq(w_down.read(fn() { c.get() }), 2)
  assert_eq(b_runs.val, 1)

  w_up.stop()
  w_down.stop()
}
