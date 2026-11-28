// What reads a table or a list kept in place (live.mbt) follows its changes: a computed of it is worked out again
// once it changed, not before, and not for a change that changed nothing.

///|
test "a computed of a LiveMap is worked out again as it changes, and only then" {
  let m : LiveMap[String, Int] = LiveMap::new()
  let runs = Ref(0)
  let sum = @signals.computed(fn(_) {
    runs.val += 1
    m.values().fold(init=0, fn(a, b) { a + b })
  })
  assert_eq(sum.get(), 0)
  m["a"] = 2
  m["b"] = 3
  assert_eq(sum.get(), 5)
  assert_eq(sum.get(), 5)
  assert_eq(runs.val, 2)
  // (what is not there let go of: nothing changed)
  m.remove("c")
  assert_eq(sum.get(), 5)
  assert_eq(runs.val, 2)
  m.remove("a")
  assert_eq(sum.get(), 3)
}

///|
test "a computed of a LiveArray follows what is pushed, put in place of it and let go of" {
  let a : LiveArray[String] = LiveArray::new()
  let seen = @signals.computed(fn(_) { a.length() })
  assert_eq(seen.get(), 0)
  a.push("x")
  assert_eq(seen.get(), 1)
  a.replace(["y", "z"])
  assert_eq(seen.get(), 2)
  a.retain(fn(s) { s != "y" })
  assert_eq((seen.get(), a.copy()), (1, ["z"]))
  // (a copy read as it is: nothing followed changes it)
  let c = a.copy()
  a.clear()
  assert_eq((seen.get(), c), (0, ["z"]))
}

///|
test "LiveArray::iter, push_iter, any, all, and search_by keep initial length snapshot when mutated" {
  let a : LiveArray[Int] = LiveArray::new()
  a.replace([1, 2, 3])
  a.push_iter(a.iter())
  assert_eq(a.copy(), [1, 2, 3, 1, 2, 3])

  let b : LiveArray[Int] = LiveArray::new()
  b.replace([10, 20, 30])
  let mut steps = 0
  for x in b.iter() {
    steps = steps + 1
    b.push(x + 1)
  }
  assert_eq(steps, 3)
  assert_eq(b.copy(), [10, 20, 30, 11, 21, 31])

  let c : LiveArray[Int] = LiveArray::new()
  c.replace([1, 2, 3])
  let mut any_steps = 0
  assert_eq(c.any(fn(x) {
    any_steps = any_steps + 1
    c.push(x + 10)
    false
  }), false)
  assert_eq(any_steps, 3)

  let d : LiveArray[Int] = LiveArray::new()
  d.replace([1, 2, 3])
  let mut all_steps = 0
  assert_eq(d.all(fn(x) {
    all_steps = all_steps + 1
    d.push(x + 10)
    true
  }), true)
  assert_eq(all_steps, 3)

  let e : LiveArray[Int] = LiveArray::new()
  e.replace([1, 2, 3])
  let mut search_steps = 0
  assert_eq(e.search_by(fn(x) {
    search_steps = search_steps + 1
    e.push(x + 10)
    false
  }), None)
  assert_eq(search_steps, 3)
}

///|
test "LiveArray::iter2 and rev_iter walk a snapshot in order" {
  let e : LiveArray[Int] = LiveArray::new()
  assert_eq(e.iter2().to_array(), [])
  assert_eq(e.rev_iter().to_array(), [])
  let a : LiveArray[Int] = LiveArray::new()
  a.replace([10, 20, 30])
  assert_eq(a.iter2().to_array(), [(0, 10), (1, 20), (2, 30)])
  assert_eq(a.rev_iter().to_array(), [30, 20, 10])
  let seen = []
  for i, x in a.iter2() {
    seen.push((i, x))
    a.push(x + 1)
  }
  assert_eq(seen, [(0, 10), (1, 20), (2, 30)])
  let back = []
  for x in a.rev_iter() {
    back.push(x)
    a.push(0)
  }
  assert_eq(back, [31, 21, 11, 30, 20, 10])
}
