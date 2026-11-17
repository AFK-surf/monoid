///|
test "optimistic: batched authority handoff never changes the projection or wakes its reader" {
  let authority = signal(false)
  let state = optimistic(fn() { authority.get() })
  let told = Ref(0)
  let reader = watch(fn() { told.val += 1 })
  defer reader.stop()
  assert_false(reader.read(fn() { state.get() }))
  let done = state.set_value(true)
  assert_true(reader.read(fn() { state.get() }))
  assert_true(state.is_pending())
  assert_eq(told.val, 1)
  start_batch()
  authority.set(true)
  let before_done = state.get()
  done()
  let after_done = state.get()
  end_batch()
  assert_true(before_done)
  assert_true(after_done)
  assert_true(state.get())
  assert_false(state.is_pending())
  assert_false(reader.is_stale())
  assert_eq(told.val, 1)
}

///|
test "optimistic: edits fold in order and a rollback replays only the remaining edits" {
  let authority = signal(2)
  let state = optimistic(fn() { authority.get() })
  let seen : Array[Int] = []
  let stop = effect(fn() { seen.push(state.get()) })
  defer stop()
  let first = state.push(fn(value) { value + 3 })
  let second = state.push(fn(value) { value * 10 })
  authority.set(4)
  first()
  first()
  second()
  second()
  assert_eq(seen, [2, 5, 50, 70, 40, 4])
  assert_false(state.is_pending())
}

///|
test "optimistic: pending changes only at empty boundaries; cleared handles cannot remove later edits" {
  let authority_reads = Ref(0)
  let state = optimistic(fn() {
    authority_reads.val += 1
    0
  })
  let seen : Array[Bool] = []
  let stop = effect(fn() { seen.push(state.is_pending()) })
  defer stop()
  let first = state.set_value(1)
  let second = state.set_value(2)
  first()
  state.clear()
  state.clear()
  let third = state.set_value(3)
  first()
  second()
  assert_eq(authority_reads.val, 0)
  assert_eq(state.untracked(), 3)
  third()
  assert_eq(state.untracked(), 0)
  assert_eq(seen, [false, true, false, true, false])
}

///|
test "optimistic: separate edits with the same projection deduplicate by value" {
  let authority = signal([1])
  let state = optimistic(fn() { authority.get() })
  let runs = Ref(0)
  let stop = effect(fn() {
    state.get() |> ignore
    runs.val += 1
  })
  defer stop()
  let done = state.set_value([1])
  done()
  assert_eq(runs.val, 1)
}

///|
test "optimistic: reference and custom equality are explicit" {
  let original = [1]
  let state = optimistic_ref(fn() { original })
  let runs = Ref(0)
  let stop = effect(fn() {
    state.get() |> ignore
    runs.val += 1
  })
  defer stop()
  let same = state.set_value(original)
  same()
  assert_eq(runs.val, 1)
  let fresh = state.set_value([1])
  fresh()
  assert_eq(runs.val, 3)

  let state = optimistic_by(fn() { 1 }, same=fn(a, b) { a % 2 == b % 2 })
  let told = Ref(0)
  let reader = watch(fn() { told.val += 1 })
  defer reader.stop()
  assert_eq(reader.read(fn() { state.get() }), 1)
  let done = state.set_value(3)
  assert_eq(state.get(), 3)
  done()
  assert_eq(told.val, 0)
}

///|
test "optimistic: one-off reads and rest release authority while keeping pending edits" {
  let source = signal(1)
  let released = Ref(0)
  source.on_unwatched(fn() { released.val += 1 })
  let held = computed_scoped(fn(_) { source.get() })
  let state = optimistic(fn() { held.get() })
  let done = state.push(fn(value) { value + 10 })
  assert_eq(state.untracked(), 11)
  assert_eq((source.watched(), released.val), (false, 1))

  let owner = Ref(None)
  let reader = Ref(None)
  let stop = effect_scope(fn() {
    owner.val = active_sub()
    let w = watch(fn() {  })
    w.read(fn() { (state.get(), state.is_pending()) }) |> ignore
    reader.val = Some(w)
  })
  defer stop()
  let w = reader.val.unwrap()
  let wake = rest(owner.val.unwrap())
  assert_eq((source.watched(), released.val), (false, 2))
  source.set(2)
  wake()
  assert_eq(w.read(fn() { (state.get(), state.is_pending()) }), (12, true))
  assert_true(source.watched())
  w.stop()
  done()
  assert_eq((source.watched(), released.val), (false, 3))
}
