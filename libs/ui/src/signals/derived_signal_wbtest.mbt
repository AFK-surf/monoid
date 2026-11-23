///|
test "derived signal: upstream and local writes win in call order, including inside a batch" {
  let source = signal(1)
  let state = derived_signal(fn(_) { source.get() * 10 })
  let told = Ref(0)
  let reader = watch(fn() { told.val += 1 })
  defer reader.stop()
  assert_eq(reader.read(fn() { state.get() }), 10)

  source.set(2)
  state.set(91)
  assert_eq(reader.read(fn() { state.get() }), 91)
  state.set(92)
  source.set(3)
  assert_eq(reader.read(fn() { state.get() }), 30)

  let before = told.val
  start_batch()
  source.set(4)
  state.set(93)
  end_batch()
  assert_eq(told.val - before, 1)
  assert_eq(reader.read(fn() { state.get() }), 93)

  let before = told.val
  start_batch()
  state.set(94)
  source.set(5)
  end_batch()
  assert_eq(told.val - before, 1)
  assert_eq(reader.read(fn() { state.get() }), 50)
}

///|
test "derived signal: equal upstream computations keep a local write; a later ABA cannot revive it" {
  let source = signal(10)
  let previous : Array[Int?] = []
  let state = derived_signal(fn(last) {
    previous.push(last)
    source.get() / 10
  })
  let seen : Array[Int] = []
  let stop = effect(fn() { seen.push(state.get()) })
  defer stop()
  state.set(7)
  source.set(11)
  source.set(20)
  source.set(10)
  assert_eq(seen, [1, 7, 2, 1])
  assert_eq(previous, [None, Some(1), Some(1), Some(2)])
}

///|
test "derived signal: equal writes and authority catching up leave downstream values alone" {
  let source = signal([0])
  let state = derived_signal(fn(_) { source.get() })
  let computations = Ref(0)
  let doubled = computed(fn(_) {
    computations.val += 1
    state.get()[0] * 2
  })
  let told = Ref(0)
  let reader = watch(fn() { told.val += 1 })
  defer reader.stop()
  reader.read(fn() { (state.get(), doubled.get()) }) |> ignore
  let before = sets_said()
  state.set([0])
  assert_eq((sets_said() - before, told.val, computations.val), (0, 0, 1))

  state.set([2])
  assert_eq((sets_said() - before, told.val), (1, 1))
  assert_eq(reader.read(fn() { (state.get(), doubled.get()) }), ([2], 4))
  source.set([2])
  assert_eq((told.val, computations.val), (1, 2))
  assert_false(reader.is_stale())
}

///|
test "derived signal: sampling upstream in a local write still coalesces a batch's effective value" {
  let source = signal(0)
  let state = derived_signal(fn(_) { source.get() })
  let told = Ref(0)
  let reader = watch(fn() { told.val += 1 })
  defer reader.stop()
  reader.read(fn() { state.get() }) |> ignore
  start_batch()
  source.set(1)
  state.set(0)
  end_batch()
  assert_eq((state.get(), told.val), (0, 0))
  assert_false(reader.is_stale())
  source.set(2)
  assert_eq((state.get(), told.val), (2, 1))
}

///|
test "derived signal: a write before the first read stays visible and starts following upstream" {
  let source = signal(5)
  let state = derived_signal(fn(_) { source.get() })
  assert_eq(state.peek(), None)
  state.set(8)
  assert_eq(state.peek(), Some(8))
  let reader = watch(fn() {  })
  defer reader.stop()
  assert_eq(reader.read(fn() { state.get() }), 8)
  assert_true(state.watched())
  source.set(6)
  assert_true(reader.is_stale())
  assert_eq(reader.read(fn() { state.get() }), 6)
}

///|
#callsite(autofill(loc))
fn graph_test_loc(loc~ : SourceLoc) -> SourceLoc {
  loc
}

///|
test "derived signal: write locations survive batch delivery and a write during a watch read" {
  let state = derived_signal(fn(_) { 0 })
  let delivered : Array[String] = []
  let reader = watch(fn() {
    if setting_at() is Some(at) {
      delivered.push(at.to_string())
    }
  })
  defer reader.stop()
  reader.read(fn() { state.get() }) |> ignore
  let batch_loc = graph_test_loc()
  start_batch()
  state.set(1, loc=batch_loc)
  end_batch()
  let read_loc = graph_test_loc()
  let read = reader.read(fn() {
    let v = state.get()
    state.set(2, loc=read_loc)
    v
  })
  assert_eq(read, 1)
  assert_eq(delivered, [batch_loc.to_string()])
  assert_eq(reader.set_as_read(), [read_loc.to_string()])
  assert_eq(last_set_at(), read_loc.to_string())
  assert_true(reader.is_stale())
  assert_true(setting_at() is None)
  assert_true(active_sub() is None)
  assert_eq(batch_depth(), 0)
}

///|
test "derived signal: one-off reads, rest and the last reader release resources" {
  let source = signal(0)
  let released = Ref(0)
  source.on_unwatched(fn() { released.val += 1 })
  let held = computed_scoped(fn(_) { source.get() })
  let state = derived_signal(fn(_) { held.get() })
  assert_eq(state.untracked(), 0)
  assert_eq((source.watched(), released.val), (false, 1))

  let owner = Ref(None)
  let reader = Ref(None)
  let stop = effect_scope(fn() {
    owner.val = active_sub()
    let w = watch(fn() {  })
    w.read(fn() { state.get() }) |> ignore
    reader.val = Some(w)
  })
  defer stop()
  let w = reader.val.unwrap()
  let wake = rest(owner.val.unwrap())
  assert_eq((state.watched(), source.watched(), released.val), (false, false, 2))
  source.set(1)
  wake()
  assert_eq(w.read(fn() { state.get() }), 1)
  assert_true(source.watched())
  w.stop()
  assert_eq((source.watched(), released.val), (false, 3))
  state.set(2)
  assert_eq((source.watched(), released.val), (false, 4))
  assert_eq(state.get(), 2)
  assert_eq((source.watched(), released.val), (false, 5))
}

///|
test "derived signal: dispose releases a cached dependency acquired by a first write" {
  let source = signal(1)
  let state = derived_signal(fn(_) { source.get() })
  state.set(9)
  assert_true(source.watched())
  state.dispose()
  assert_false(source.watched())
  source.set(2)
  assert_eq(state.get(), 2)
  state.dispose()
}

///|
test "derived signal: the reference and custom constructors select equality explicitly" {
  let source = signal_ref([1])
  let state = derived_signal_ref(fn(_) { source.get() })
  let first = state.get()
  let local_value = [1]
  state.set(local_value)
  assert_true(physical_equal(state.get(), local_value))
  source.set(first)
  assert_true(physical_equal(state.get(), local_value))
  let replacement = [1]
  source.set(replacement)
  assert_true(physical_equal(state.get(), replacement))
  state.dispose()

  let n = signal(1)
  let state = derived_signal_by(fn(_) { n.get() }, same=fn(a, b) { a % 2 == b % 2 })
  state.set(2)
  n.set(3)
  assert_eq(state.get(), 2)
  n.set(4)
  assert_eq(state.get(), 4)
  state.dispose()
}
