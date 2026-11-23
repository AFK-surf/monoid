// What a node let go of held is let go of with it, not kept on its index till that is made again (View::let_go,
// Node::let_go_held); the index made again shows as one made fresh. A tree's log of hold faults keeps the latest
// hold_log_max of them.

///|
test "a node let go of holds nothing of what it drew or was given; its index made again shows as made fresh" {
  let shown = @signals.signal(true, same=fn(a, b) { a == b })
  let words = @signals.signal("hello", same=fn(a, b) { a == b })
  let outer : Ref[NodeId?] = Ref(None)
  let inner : Ref[NodeId?] = Ref(None)
  let t = Tree::new(
    fn(root) {
      root.show(at_once=true, fn() { shown.get() }, fn(m) {
        outer.val = Some(m.id())
        m
        .words(By(fn() { words.get() }))
        .shorter(Is(["he"]))
        .moved_by(fn(_, _, _) { (0.0, 0.0) }, fn(_, _) { 0.0 })
        .faults_to(fn(_) {  })
        .glyphs_by(Is(1), fn(_, _) { { alpha: 1.0, dx: 0.0, dy: 0.0, scale: 1.0, sx: 0.0 } })
        |> ignore
        m.box(fn(k) {
          inner.val = Some(k.id())
          k.words_runs(Is([words_run("ab "), words_run("cd", weight=600)])) |> ignore
        })
        |> ignore
      })
    },
    time=fn() { 0.0 },
  )
  t.frame(390.0, 844.0) |> ignore
  let o = outer.val.unwrap()
  let i = inner.val.unwrap()
  assert_eq(t.drawn_of(o).unwrap().words, "hello")
  assert_eq(t.drawn_of(i).unwrap().words, "ab cd")
  let on = t.nodes[o.at]
  let kn = t.nodes[i.at]
  assert_true(on.shorter.length() > 0 && on.moved_by is Some(_) && on.fault_to is Some(_) && on.glyphs_fn is Some(_))
  assert_true(kn.look.runs.length() > 0)
  // let go of: nothing of theirs kept
  shown.set(false)
  t.frame(390.0, 844.0) |> ignore
  assert_false(on.live)
  assert_false(kn.live)
  for n in [on, kn] {
    assert_eq(n.look.words, "")
    assert_true(n.look.words_drawn is None)
    assert_eq(n.look.runs.length(), 0)
    assert_eq(n.look.runs_marks.length(), 0)
    assert_eq(n.look.shapes.length(), 0)
    assert_eq(n.look.lines.length(), 0)
    assert_true(n.look.image is None && n.look.picture is None && n.look.glass is None)
    assert_eq(n.shorter.length(), 0)
    assert_eq(n.takes_units.length(), 0)
    assert_true(n.moved_by is None && n.moved_holds is None && n.moved_ends is None)
    assert_true(n.glyphs_fn is None && n.fault_to is None && n.piece_cell is None && n.scroll_off is None)
    assert_true(n.within_cell is None && n.said_cell is None && n.going is None && n.come_said is None)
    assert_true(n.source is None && n.content is None && n.come_wake is None && n.share_told is None)
    assert_true(n.claims is None && n.claims_from is None && n.claims_for is None && n.shows is None)
  }
  // shown again: their indices made again, each as it is said now
  words.set("again")
  shown.set(true)
  t.frame(390.0, 844.0) |> ignore
  let o2 = outer.val.unwrap()
  let i2 = inner.val.unwrap()
  assert_true(o2.at == o.at || o2.at == i.at, msg="an index let go made again")
  assert_true(o2.gen > 0 || i2.gen > 0)
  assert_eq(t.drawn_of(o2).unwrap().words, "again")
  assert_eq(t.drawn_of(i2).unwrap().words, "ab cd")
  assert_eq(t.drawn_of(o).map(fn(d) { d.words }), None, msg="the old handle finds nothing")
  assert_true(t.nodes[o2.at].shorter.length() > 0)
  assert_eq(t.kept_said(), None)
  // and changed after: told as any
  words.set("third")
  t.frame(390.0, 844.0) |> ignore
  assert_eq(t.drawn_of(o2).unwrap().words, "third")
}

///|
test "a tree's hold faults: the latest hold_log_max kept, the earliest let go" {
  let tree = Tree::new(fn(_) {  })
  let v = tree.root()
  let gate = HoldGate::new()
  let never = @signals.signal(false)
  let count = hold_log_max + 44
  for i in 0..<count {
    let start = i.to_double() * 1000.0
    let most = 200.0 + i.to_double()
    tree.event(start, fn() {
      gate.open_when(
        v,
        most~,
        fn() {
          hold_note(fn() { never.get() })
          true
        },
        fn() {  },
      )
    })
    tree.advance(start + most)
  }
  let faults = tree.hold_faults()
  assert_eq(faults.length(), hold_log_max)
  assert_true(faults[0].contains("waited \{244.0}ms"), msg=faults[0])
  assert_true(faults[hold_log_max - 1].contains("waited \{(200 + count - 1).to_double()}ms"), msg=faults[hold_log_max - 1])
  tree.dispose()
}
