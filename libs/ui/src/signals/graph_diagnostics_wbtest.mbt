///|
test "graph diagnostics: bare reads report their node once, tracked and untracked reads stay quiet" {
  let made = graph_test_loc()
  let a = signal(1)
  let b = signal_ref(2)
  let c = signal_by(3, same=same_value)
  let d = computed(fn(_) { a.get() + b.get() + c.get() }, loc=made)
  let derived_at = graph_test_loc()
  let e = derived_signal(fn(_) { d.get() }, loc=derived_at)
  let f = optimistic(fn() { e.get() })
  let scoped = computed_scoped(fn(_) { 0 }, untracked_read=Some(fn() { Some(42) }))
  let seen : Array[ReactiveNode] = []
  let was = on_untracked_read.val
  defer { on_untracked_read.val = was }
  on_untracked_read.val = Some(fn(node) { seen.push(node) })

  let reader = watch(fn() {  })
  defer reader.stop()
  reader.read(fn() { f.get() }) |> ignore
  assert_true(seen.is_empty())
  a.untracked() |> ignore
  d.untracked() |> ignore
  e.untracked() |> ignore
  f.untracked() |> ignore
  untracked(fn() { c.get() }) |> ignore
  // A scoped direct answer does not read a graph node.
  assert_eq(scoped.get(), 42)
  assert_true(seen.is_empty())

  a.get() |> ignore
  b.get() |> ignore
  c.get() |> ignore
  // Make the getter run under the diagnostic so the nested signal reads are tracked.
  d.invalidate()
  d.get() |> ignore
  e.get() |> ignore
  f.get() |> ignore
  let expected = [a.0, b.0, c.0, d.0, e.value.0, f.value.0]
  assert_eq(seen.length(), expected.length())
  for i, node in expected {
    assert_true(physical_equal(seen[i], node))
  }
  assert_eq(d.made_at().to_string(), made.to_string())
  assert_eq(e.made_at().to_string(), derived_at.to_string())
}

///|
test "graph diagnostics: explicit untracked depth nests and restores the subscriber" {
  let signal = signal(1)
  let depths : Array[Int] = []
  let reader = watch(fn() {  })
  defer reader.stop()
  let restored = reader.read(fn() {
    depths.push(untracked_depth())
    untracked(fn() {
      depths.push(untracked_depth())
      untracked(fn() {
        depths.push(untracked_depth())
        signal.get() |> ignore
      })
      depths.push(untracked_depth())
    })
    depths.push(untracked_depth())
    signal.get() |> ignore
    active_sub() is Some(_)
  })
  assert_eq(depths, [0, 1, 2, 1, 0])
  assert_true(restored)
  assert_true(signal.watched())
  assert_true(active_sub() is None)
  assert_eq(untracked_depth(), 0)
}

///|
test "graph diagnostics: fan-out counts newly queued sibling readers for the write and reports its location" {
  let was_limit = fanout_limit.val
  let was_hook = on_fanout.val
  defer {
    fanout_limit.val = was_limit
    on_fanout.val = was_hook
  }
  let source = signal(0)
  let seen : Array[(String?, Int)] = []
  on_fanout.val = Some(fn(at, count) { seen.push((at.map(fn(l) { l.to_string() }), count)) })
  fanout_limit.val = 4
  let told = Ref(0)
  let readers = [watch(fn() { told.val += 1 }), watch(fn() { told.val += 1 }), watch(fn() { told.val += 1 })]
  defer { for reader in readers { reader.stop() } }
  for reader in readers {
    reader.read(fn() { source.get() }) |> ignore
  }
  source.set(1)
  assert_eq(seen, [])
  assert_eq(told.val, 3)

  for reader in readers {
    reader.read(fn() { source.get() }) |> ignore
  }
  fanout_limit.val = 3
  let write_loc = graph_test_loc()
  start_batch()
  source.set(2, loc=write_loc)
  source.set(3)
  end_batch()
  assert_eq(seen, [(Some(write_loc.to_string()), 3)])
  assert_eq(told.val, 6)
  assert_eq(batch_depth(), 0)
  assert_true(active_sub() is None)
  assert_true(setting_at() is None)
}

///|
test "Signal::update updates without self-subscribing, deduplicates equal values, and forwards loc" {
  let count = signal(10)
  let writes : Array[(Int, String)] = []
  let w = watch(fn() {
    writes.push((count.untracked(), last_set_at()))
  })
  defer w.stop()
  w.read(fn() { count.get() }) |> ignore

  // Normal update notifies subscribers and forwards callsite loc.
  let upd_loc = graph_test_loc()
  count.update(fn(n) { n + 5 }, loc=upd_loc)
  assert_eq(count.untracked(), 15)
  assert_eq(writes.length(), 1)
  assert_eq(writes[0].0, 15)
  assert_eq(writes[0].1, upd_loc.to_string())

  // Equal result deduplicates via `same` and notifies nobody.
  w.read(fn() { count.get() }) |> ignore
  count.update(fn(n) { n })
  assert_eq(writes.length(), 1)

  // Calling Signal::update inside a Watch::read or computed does not subscribe to the signal itself.
  let target = signal(1)
  let trigger_sig = signal(0)
  let computed_runs = Ref(0)
  let c = computed(fn(_) {
    computed_runs.val += 1
    let v = trigger_sig.get()
    target.update(fn(x) { x + 1 })
    v
  })
  assert_eq(c.get(), 0)
  assert_eq(computed_runs.val, 1)
  assert_false(target.watched(), msg="Signal::update inside computed must not subscribe computed to target")

  let watch_runs = Ref(0)
  let w2 = watch(fn() { watch_runs.val += 1 })
  defer w2.stop()
  w2.read(fn() { target.update(fn(x) { x + 1 }) })
  assert_false(target.watched(), msg="Signal::update inside Watch::read must not subscribe watch to target")
  target.set(99)
  assert_eq(watch_runs.val, 0)
}

///|
test "on_effect_in_view fires for effect and effect_cleanup, not effect_scope or watch" {
  let seen : Array[String] = []
  let was = on_effect_in_view.val
  defer { on_effect_in_view.val = was }
  on_effect_in_view.val = Some(fn(loc) { seen.push(loc.to_string()) })

  let scope_stop = effect_scope(fn() { () })
  scope_stop()
  let w = watch(fn() { () })
  w.stop()
  assert_eq(seen, [])

  let loc1 = graph_test_loc()
  let s1 = effect(fn() { () }, loc=loc1)
  s1()
  let loc2 = graph_test_loc()
  let s2 = effect_cleanup(fn() { fn() { () } }, loc=loc2)
  s2()
  assert_eq(seen, [loc1.to_string(), loc2.to_string()])
}
