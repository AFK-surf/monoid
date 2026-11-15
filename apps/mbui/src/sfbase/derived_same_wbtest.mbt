// What is worked out of a topic (Derived) tells what reads it only as what `work` makes comes out another value: a
// change of the topic in what `work` does not read, `work` making the same again, runs nothing that follows it.

///|
/// A source whose topic is `value` as it is now, followed by what reads it through `changes` (the core client's
/// subscription's changes, as it says them).
fn same_source(value : Ref[Json], changes : @signals.Signal[Int]) -> Source {
  made_source(topic=fn(_, _) {
    changes.get() |> ignore
    Some(value.val)
  })
}

///|
/// What `work` makes of the topic `{n, noise}`: its `n`, and words made anew each time (never the object made last).
fn same_work(v : Json, _was : (Int, String)?) -> (Int, String) {
  let n = match v {
    { "n": Number(n, ..), .. } => n.to_int()
    _ => -1
  }
  let words = StringBuilder()
  words.write_string("n=")
  words.write_string(n.to_string())
  (n, words.to_string())
}

///|
test "a topic changed where its Derived's work does not read runs nothing that reads what it made" {
  kept_reset()
  let _tester = @ui.Tester::new(fn(_) {  })
  let value = Ref(({ "n": 1, "noise": 0 } : Json))
  let changes = @signals.signal(0)
  let src = same_source(value, changes)
  let worked = Ref(0)
  let d : Derived[(Int, String)] = Derived::new("same", fn(v, was) {
    worked.val += 1
    same_work(v, was)
  })
  let params : Map[String, Json] = { "k": "1" }
  // (what reads it: only what `work` made, as a page's part reads a derived value)
  let made = @signals.computed(fn(_) { d.read(src, params).0 })
  let ran = Ref(0)
  let w = @signals.watch(fn() {  })
  let stop = @signals.effect(fn() {
    made.get() |> ignore
    ran.val += 1
  })
  w.read(fn() { made.get() }) |> ignore
  assert_eq(made.get(), Some((1, "n=1")))
  assert_eq((worked.val, ran.val), (1, 1))
  // the topic changes in what `work` does not read: worked out again, the same made, nothing that reads it run
  value.val = { "n": 1, "noise": 1 }
  changes.set(1)
  assert_eq(worked.val, 2)
  assert_eq(ran.val, 1)
  assert_false(w.is_stale())
  // what `work` reads changes: told
  value.val = { "n": 2, "noise": 1 }
  changes.set(2)
  assert_eq(made.get(), Some((2, "n=2")))
  assert_eq(ran.val, 2)
  stop()
  w.stop()
}

///|
test "a Derived's own value tells nothing where work makes the same again, by its kept computed alone" {
  kept_reset()
  let _tester = @ui.Tester::new(fn(_) {  })
  let value = Ref(({ "n": 1, "noise": 0 } : Json))
  let changes = @signals.signal(0)
  let src = same_source(value, changes)
  let d : Derived[(Int, String)] = Derived::new("same", same_work)
  let params : Map[String, Json] = { "k": "1" }
  // (made by its first read; read after it by the computed it keeps alone, not the topic: what Derived's `same` tells)
  d.read(src, params) |> ignore
  let key = topic_key("same", params)
  let kept_alone = @signals.computed_ref(fn(_) {
    d.kept.read(src, key, fn(_) { @halt.saying("made by its first read") }, same=d.same)
  })
  let ran = Ref(0)
  let stop = @signals.effect(fn() {
    kept_alone.get() |> ignore
    ran.val += 1
  })
  value.val = { "n": 1, "noise": 1 }
  changes.set(1)
  assert_eq(ran.val, 1)
  value.val = { "n": 3, "noise": 1 }
  changes.set(2)
  assert_eq(ran.val, 2)
  stop()
}

///|
test "what reads a Derived's value alone, a watch over it, is not told as its topic changes where work does not read" {
  kept_reset()
  let _tester = @ui.Tester::new(fn(_) {  })
  let value = Ref(({ "n": 1, "noise": 0 } : Json))
  let changes = @signals.signal(0)
  let src = same_source(value, changes)
  let d : Derived[(Int, String)] = Derived::new("same", same_work)
  let params : Map[String, Json] = { "k": "1" }
  let w = @signals.watch(fn() {  })
  assert_eq(w.read(fn() { d.value(src, params) }), Some((1, "n=1")))
  // the topic changes in what `work` does not read: the watch not told
  value.val = { "n": 1, "noise": 1 }
  changes.set(1)
  assert_false(w.is_stale())
  // what `work` reads changes: told, and read anew it has it
  value.val = { "n": 2, "noise": 1 }
  changes.set(2)
  assert_true(w.is_stale())
  assert_eq(w.read(fn() { d.value(src, params) }), Some((2, "n=2")))
  w.stop()
}

///|
test "what reads Derived::read follows its topic as well: told as the topic changes, whatever work made" {
  kept_reset()
  let _tester = @ui.Tester::new(fn(_) {  })
  let value = Ref(({ "n": 1, "noise": 0 } : Json))
  let changes = @signals.signal(0)
  let src = same_source(value, changes)
  let d : Derived[(Int, String)] = Derived::new("same", same_work)
  let params : Map[String, Json] = { "k": "1" }
  let w = @signals.watch(fn() {  })
  w.read(fn() { d.read(src, params).0 }) |> ignore
  value.val = { "n": 1, "noise": 1 }
  changes.set(1)
  assert_true(w.is_stale())
  w.stop()
}
