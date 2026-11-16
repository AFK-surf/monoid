// KeyedList (keyed_list.mbt): a list by key, each reader told only as what it read changed.

///|
test "an item read is told as it changes, not as another does; the order only as it changes" {
  let l : KeyedList[String, Int] = keyed_list(same=fn(a, b) { a == b })
  l.reset(["a", "b", "c"], { "a": 1, "b": 2, "c": 3 })
  let wa = watch(fn() {  })
  let wb = watch(fn() {  })
  let wo = watch(fn() {  })
  assert_eq(wa.read(fn() { l.get("a") }), Some(1))
  assert_eq(wb.read(fn() { l.get("b") }), Some(2))
  assert_eq(wo.read(fn() { l.keys() }), ["a", "b", "c"])
  // (b patched: b alone told)
  l.put("b", 20)
  assert_true(!wa.is_stale())
  assert_true(wb.is_stale())
  assert_true(!wo.is_stale())
  assert_eq(wb.read(fn() { l.get("b") }), Some(20))
  // (put as it was: none told)
  l.put("b", 20)
  assert_true(!wb.is_stale())
  // (one come: the order told, no item read)
  l.put("d", 4)
  assert_true(wo.is_stale())
  assert_true(!wa.is_stale())
  assert_true(!wb.is_stale())
  assert_eq(wo.read(fn() { l.keys() }), ["a", "b", "c", "d"])
  // (one come before another)
  l.put("x", 0, before=Some("a"))
  assert_eq(wo.read(fn() { l.keys() }), ["x", "a", "b", "c", "d"])
  // (moved: the order alone)
  l.move_before("x")
  assert_true(wo.is_stale())
  assert_true(!wa.is_stale())
  assert_eq(wo.read(fn() { l.keys() }), ["a", "b", "c", "d", "x"])
  // (dropped: it and the order)
  l.drop("a")
  assert_true(wa.is_stale())
  assert_true(wo.is_stale())
  assert_true(!wb.is_stale())
  assert_eq(wa.read(fn() { l.get("a") }), None)
  assert_eq(wo.read(fn() { l.keys() }), ["b", "c", "d", "x"])
}

///|
test "a whole value told only where it differs" {
  let l : KeyedList[String, Int] = keyed_list(same=fn(a, b) { a == b })
  l.reset(["a", "b"], { "a": 1, "b": 2 })
  let wa = watch(fn() {  })
  let wb = watch(fn() {  })
  let wo = watch(fn() {  })
  wa.read(fn() { l.get("a") }) |> ignore
  wb.read(fn() { l.get("b") }) |> ignore
  wo.read(fn() { l.keys() }) |> ignore
  l.reset(["a", "b"], { "a": 1, "b": 3 })
  assert_true(!wa.is_stale())
  assert_true(wb.is_stale())
  assert_true(!wo.is_stale())
  wb.read(fn() { l.get("b") }) |> ignore
  l.reset(["b"], { "b": 3 })
  assert_true(wa.is_stale())
  assert_true(!wb.is_stale())
  assert_true(wo.is_stale())
  assert_eq(l.peek_keys(), ["b"])
}

///|
test "what read the order before keeps it as it was" {
  let l : KeyedList[Int, Int] = keyed_list()
  l.put(1, 1)
  let before = l.peek_keys()
  l.put(2, 2)
  assert_eq(before, [1])
  assert_eq(l.peek_keys(), [1, 2])
}

///|
test "reset lets go of the keys read once and read no more, gone from it, as Keyed::set does" {
  let l : KeyedList[String, Int] = keyed_list(same=fn(a, b) { a == b })
  // (a hundred keys each read once by what reads them no more, then all gone but one)
  let keys = Array::makei(100, fn(i) { "k\{i}" })
  let vals : Map[String, Int] = Map([])
  for k in keys {
    vals[k] = 0
  }
  l.reset(keys, vals)
  for k in keys {
    let w = watch(fn() {  })
    w.read(fn() { l.get(k) }) |> ignore
    w.stop()
  }
  // (and a hundred never in it, asked of it once: a row looking up what was not there)
  for i in 0..<100 {
    let w = watch(fn() {  })
    w.read(fn() { l.get("z\{i}") }) |> ignore
    w.stop()
  }
  // (one still read: kept, and told as it goes)
  let kept = watch(fn() {  })
  kept.read(fn() { l.get("k5") }) |> ignore
  assert_eq(l.said.length(), 200)
  l.reset(["k0"], { "k0": 1 })
  // (k0 is in it, k5 is read: those two kept, the rest let go)
  assert_true(l.said.length() <= 2)
  assert_true(l.said.contains("k5"))
  assert_true(kept.is_stale())
}
