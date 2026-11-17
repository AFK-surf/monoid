// View::keyed_by and View::selected (keyed_by.mbt): a whole list given anew wakes the rows of the items that changed
// alone, a choice moved wakes the two rows it concerns alone, and neither follows its source once its node is let go;
// at rest with its node, read anew as it wakes.

///|
/// Fifty rows by key, each its words its own item's by key; how many bindings a frame ran.
fn keyed_by_rows() -> (Tree, @signals.Signal[Array[(String, Int)]], Ref[@signals.KeyedList[String, (String, Int)]?]) {
  let src = @signals.signal(Array::makei(50, fn(i) { ("k\{i}", 0) }))
  let held : Ref[@signals.KeyedList[String, (String, Int)]?] = Ref(None)
  let tree = Tree::new(fn(root) {
    let list = root.keyed_by(fn() { src.get() }, fn(v) { v.0 })
    held.val = Some(list)
    root.each(fn() { list.keys() }, fn(k) { k }, fn(r, k) {
      let k = k.untracked()
      r.height(Is(Some(10.0))).words(By(fn() { list.get(k).map(fn(v) { "\{v.0} \{v.1}" }).unwrap_or("") })) |> ignore
    })
  })
  tree.frame(390.0, 844.0) |> ignore
  (tree, src, held)
}

///|
test "keyed_by: one item of fifty changed in a list given whole runs that row's binding alone" {
  let (tree, src, held) = keyed_by_rows()
  let before = tree.work().bindings_run
  tree.event(100.0, fn() {
    let all = src.untracked().copy()
    all[17] = ("k17", 1)
    src.set(all)
  })
  tree.frame(390.0, 844.0) |> ignore
  let ran = tree.work().bindings_run - before
  // (the list's own watch, and the row of k17's words)
  assert_true(ran <= 2, msg="ran \{ran} bindings")
  assert_eq(held.val.unwrap().peek("k17"), Some(("k17", 1)))
  // (the same list given again: nothing told past the list's own watch)
  let before = tree.work().bindings_run
  tree.event(200.0, fn() { src.set(src.untracked().copy()) })
  tree.frame(390.0, 844.0) |> ignore
  assert_true(tree.work().bindings_run - before <= 1, msg="ran \{tree.work().bindings_run - before} for the same list")
}

///|
test "keyed_by: one key first by order, an item gone told to what read it" {
  let src = @signals.signal([("a", 1), ("b", 2), ("a", 3)])
  let held : Ref[@signals.KeyedList[String, (String, Int)]?] = Ref(None)
  let tree = Tree::new(fn(root) { held.val = Some(root.keyed_by(fn() { src.get() }, fn(v) { v.0 })) })
  tree.frame(390.0, 844.0) |> ignore
  let list = held.val.unwrap()
  assert_eq(list.peek_keys(), ["a", "b"])
  assert_eq(list.peek("a"), Some(("a", 1)))
  tree.event(100.0, fn() { src.set([("b", 2)]) })
  assert_eq(list.peek_keys(), ["b"])
  assert_eq(list.peek("a"), None)
}

///|
test "selected: the choice moved from one row of a hundred to another runs those two rows' bindings alone" {
  let chosen : @signals.Signal[Int?] = @signals.signal(Some(3))
  let tree = Tree::new(fn(root) {
    let chosen_is = root.selected(fn() { chosen.get() })
    for i in 0..<100 {
      root.box(fn(r) {
        r.height(Is(Some(4.0))).alpha(By(fn() { if chosen_is(i) { 1.0 } else { 0.5 } })) |> ignore
      })
      |> ignore
    }
  })
  tree.frame(390.0, 844.0) |> ignore
  let before = tree.work().bindings_run
  tree.event(100.0, fn() { chosen.set(Some(70)) })
  tree.frame(390.0, 844.0) |> ignore
  // (the choice's own watch, then rows 3 and 70)
  let ran = tree.work().bindings_run - before
  assert_true(ran <= 3, msg="ran \{ran}")
  let before = tree.work().bindings_run
  tree.event(200.0, fn() { chosen.set(None) })
  tree.frame(390.0, 844.0) |> ignore
  let ran = tree.work().bindings_run - before
  assert_true(ran <= 2, msg="none chosen: ran \{ran}")
}

///|
test "keyed_by and selected: let go with their node, followed no more; at rest with it, read anew as it wakes" {
  let src = @signals.signal([("a", 1)])
  let chosen : @signals.Signal[String?] = @signals.signal(None)
  let here = @signals.signal(true)
  let keys = @signals.signal(["x"])
  let held : Ref[@signals.KeyedList[String, (String, Int)]?] = Ref(None)
  let resets = Ref(0)
  let tree = Tree::new(fn(root) {
    root.show(fn() { here.get() }, at_once=true, fn(s) {
      s.each(fn() { keys.get() }, fn(k) { k }, keeps=fn() { ["x"] }, at_once=true, fn(r, _) {
        let list = r.keyed_by(fn() {
          resets.val += 1
          src.get()
        }, fn(v) { v.0 })
        held.val = Some(list)
        let chosen_is = r.selected(fn() { chosen.get() })
        r.height(Is(Some(10.0))).alpha(By(fn() { if chosen_is("a") { 1.0 } else { 0.5 } })) |> ignore
      })
    })
  })
  tree.frame(390.0, 844.0) |> ignore
  assert_true(src.watched())
  assert_true(chosen.watched())
  // (put by at rest: its source not read as it changes, read anew as the row is taken in again)
  tree.event(100.0, fn() { keys.set([]) })
  tree.frame(390.0, 844.0) |> ignore
  let read = resets.val
  tree.event(200.0, fn() { src.set([("a", 2)]) })
  tree.frame(390.0, 844.0) |> ignore
  assert_eq(resets.val, read)
  assert_eq(held.val.unwrap().peek("a"), Some(("a", 1)))
  tree.event(300.0, fn() { keys.set(["x"]) })
  tree.frame(390.0, 844.0) |> ignore
  assert_eq(held.val.unwrap().peek("a"), Some(("a", 2)))
  // (let go: neither source followed)
  tree.event(400.0, fn() { here.set(false) })
  tree.frame(390.0, 844.0) |> ignore
  assert_false(src.watched())
  assert_false(chosen.watched())
}
