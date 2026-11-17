// A subscription's keyed list (keyed.mbt): taken from the core's keyed ops by key, each reader told only as what it
// read changed.

///|
test "a keyed op tells the item it changes, and the order only as an item comes, goes or moves" {
  let (c, _) = recorder()
  let s = c.subscribe("chat", params={ "station": "ws1/st1", "thread": 1 })
  assert_true(
    c.receive(
      "{\"id\":1,\"value\":{\"lastEntry\":2,\"messages\":[{\"seq\":1,\"outgoing\":\"\",\"text\":\"a\"},{\"seq\":2,\"outgoing\":\"\",\"text\":\"b\"}]}}",
    ),
  )
  let l = s.keyed("messages", ["seq", "outgoing"])
  let k1 = "[1,\"\"]"
  let k2 = "[2,\"\"]"
  let k3 = "[3,\"o-9\"]"
  assert_eq(l.peek_keys(), [k1, k2])
  let w1 = @signals.watch(fn() {  })
  let w2 = @signals.watch(fn() {  })
  let wo = @signals.watch(fn() {  })
  w1.read(fn() { l.get(k1) }) |> ignore
  w2.read(fn() { l.get(k2) }) |> ignore
  wo.read(fn() { l.keys() }) |> ignore
  // (the second patched, and a field beside the list set: the second alone told)
  assert_true(
    c.receive(
      "{\"id\":1,\"delta\":[{\"path\":[\"lastEntry\"],\"set\":3},{\"path\":[\"messages\"],\"key\":[\"seq\",\"outgoing\"],\"patch\":[2,\"\"],\"ops\":[{\"path\":[\"text\"],\"set\":\"bb\"}]}]}",
    ),
  )
  assert_true(!w1.is_stale())
  assert_true(w2.is_stale())
  assert_true(!wo.is_stale())
  assert_eq(w2.read(fn() { l.get(k2) }).map(fn(j) { j.stringify() }), Some("{\"seq\":2,\"outgoing\":\"\",\"text\":\"bb\"}"))
  // (one put at the end: the order alone)
  assert_true(
    c.receive(
      "{\"id\":1,\"delta\":[{\"path\":[\"messages\"],\"key\":[\"seq\",\"outgoing\"],\"put\":{\"seq\":3,\"outgoing\":\"o-9\",\"text\":\"c\"},\"before\":null}]}",
    ),
  )
  assert_true(wo.is_stale())
  assert_true(!w1.is_stale())
  assert_true(!w2.is_stale())
  assert_eq(wo.read(fn() { l.keys() }), [k1, k2, k3])
  // (the first dropped)
  assert_true(
    c.receive("{\"id\":1,\"delta\":[{\"path\":[\"messages\"],\"key\":[\"seq\",\"outgoing\"],\"drop\":[1,\"\"]}]}"),
  )
  assert_true(w1.is_stale())
  assert_true(wo.is_stale())
  assert_true(!w2.is_stale())
  assert_eq(l.peek_keys(), [k2, k3])
  // (what the value holds is what the list holds)
  match s.value {
    Some(Object(m)) =>
      match m.get("messages") {
        Some(Array(a)) => assert_eq(a.length(), l.count())
        _ => fail("no messages")
      }
    _ => fail("no value")
  }
}

///|
test "a value come whole tells only the items that are not as they were" {
  let (c, _) = recorder()
  let s = c.subscribe("chat", params={ "station": "ws1/st1", "thread": 1 })
  let first = "{\"id\":1,\"value\":{\"messages\":[{\"seq\":1,\"outgoing\":\"\",\"text\":\"a\"},{\"seq\":2,\"outgoing\":\"\",\"text\":\"b\"}]}}"
  assert_true(c.receive(first))
  let l = s.keyed("messages", ["seq", "outgoing"])
  let w1 = @signals.watch(fn() {  })
  let w2 = @signals.watch(fn() {  })
  w1.read(fn() { l.get("[1,\"\"]") }) |> ignore
  w2.read(fn() { l.get("[2,\"\"]") }) |> ignore
  // (whole again, the second another: a parse makes every item anew, so each is compared as it was said)
  assert_true(
    c.receive(
      "{\"id\":1,\"value\":{\"messages\":[{\"seq\":1,\"outgoing\":\"\",\"text\":\"a\"},{\"seq\":2,\"outgoing\":\"\",\"text\":\"c\"}]}}",
    ),
  )
  assert_true(w2.is_stale())
  assert_true(!w1.is_stale())
}
