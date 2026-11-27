// Regressions for O(1) `inputs_in` / `inputs_at` tracking, ancestor deduplication during large subtree mounts,
// zero-allocation `single_flex_kid`, and leaf/branch `View::let_go` & `View::retire_parked` hygiene.

///|
test "building a large nested subtree deduplicates inputs_in to the subtree root and skips walks when inputs_at is empty" {
  let shown = @signals.signal(false, same=fn(a, b) { a == b })
  let max_inputs_in = Ref(0)
  let t = Tree::new(
    fn(root) {
      root.box(fn(host) {
        host.show(at_once=true, fn() { shown.get() }, fn(page) {
          for i in 0..<200 {
            ignore(i)
            page.box(fn(row) {
              row.box(fn(a) {
                a.box(fn(_) {  }) |> ignore
                a.box(fn(_) {  }) |> ignore
              })
              |> ignore
              row.box(fn(b) { b.box(fn(_) {  }) |> ignore }) |> ignore
            })
            |> ignore
          }
          if page.tree.inputs_in.length() > max_inputs_in.val {
            max_inputs_in.val = page.tree.inputs_in.length()
          }
        })
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(390.0, 844.0) |> ignore
  let walked_before = t.work().inputs_walked
  shown.set(true)
  t.frame(390.0, 844.0) |> ignore
  // 200 * 6 = 1200+ nested boxes under `page`: ancestor dedup keeps `inputs_in` at O(1) (the structure box root)
  assert_true(max_inputs_in.val <= 2, msg="expected O(1) inputs_in during subtree build, got \{max_inputs_in.val}")
  // No node reads `takes_input()`, so `inputs_told_each` performs zero subtree walks.
  assert_eq(t.work().inputs_walked - walked_before, 0)
  assert_eq(t.inputs_in.length(), 0)
  t.dispose()
}

///|
test "subtree build with takes_input readers walks each new node at most once and stays exact across pressless, modals, and slot reuse" {
  let shown = @signals.signal(false, same=fn(a, b) { a == b })
  let inert = @signals.signal(false, same=fn(a, b) { a == b })
  let modal = @signals.signal(false, same=fn(a, b) { a == b })
  let leaf_ref : Ref[View?] = Ref(None)
  let t = Tree::new(
    fn(root) {
      root.box(fn(host) {
        host.presses(By(fn() { !inert.get() })) |> ignore
        host.show(at_once=true, fn() { shown.get() }, fn(page) {
          for i in 0..<100 {
            page.box(fn(row) {
              row.box(fn(inner) {
                inner.box(fn(leaf) {
                  if i == 50 {
                    leaf_ref.val = Some(leaf)
                    @signals.untracked(fn() { leaf.takes_input() }) |> ignore
                  }
                })
                |> ignore
              })
              |> ignore
            })
            |> ignore
          }
        })
      })
      |> ignore
      root.show(at_once=true, fn() { modal.get() }, fn(m) {
        m.modal(Is(true)).stacked(Is(1)) |> ignore
      })
    },
    time=fn() { 0.0 },
  )
  t.frame(390.0, 844.0) |> ignore
  let w0 = t.work()
  shown.set(true)
  t.frame(390.0, 844.0) |> ignore
  let w1 = t.work()
  let made = w1.made - w0.made
  let walked = w1.inputs_walked - w0.inputs_walked
  // Single pass over the new subtree (not O(N * depth))
  assert_true(made >= 300, msg="expected >= 300 nodes made, got \{made}")
  assert_true(walked <= made + 2, msg="expected <= \{made + 2} inputs_walked, got \{walked}")
  let leaf = leaf_ref.val.unwrap()
  assert_true(@signals.untracked(fn() { leaf.takes_input() }))
  assert_eq(t.kept_inputs_said(), None)

  // Toggle parent pressless
  inert.set(true)
  t.frame(390.0, 844.0) |> ignore
  assert_false(@signals.untracked(fn() { leaf.takes_input() }))
  assert_eq(t.kept_inputs_said(), None)
  inert.set(false)
  t.frame(390.0, 844.0) |> ignore
  assert_true(@signals.untracked(fn() { leaf.takes_input() }))
  assert_eq(t.kept_inputs_said(), None)

  // Modal open & close (triggers inputs_whole path and pruning)
  modal.set(true)
  t.frame(390.0, 844.0) |> ignore
  assert_false(@signals.untracked(fn() { leaf.takes_input() }))
  assert_eq(t.kept_inputs_said(), None)
  modal.set(false)
  t.frame(390.0, 844.0) |> ignore
  assert_true(@signals.untracked(fn() { leaf.takes_input() }))
  assert_eq(t.kept_inputs_said(), None)

  // Drop subtree, trigger inputs_whole to prune dead inputs_at & clear at_bits, then rebuild and re-register recycled slot
  shown.set(false)
  t.frame(390.0, 844.0) |> ignore
  modal.set(true)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(t.inputs_at.length(), 0)
  modal.set(false)
  shown.set(true)
  t.frame(390.0, 844.0) |> ignore
  let leaf2 = leaf_ref.val.unwrap()
  assert_true(@signals.untracked(fn() { leaf2.takes_input() }))
  assert_eq(t.inputs_at.length(), 1)
  assert_eq(t.kept_inputs_said(), None)
  t.dispose()
}

///|
test "single_flex_kid matches flex_kids length == 1 across 0, 1, 2, and nested-slot children" {
  let show_a = @signals.signal(false, same=fn(a, b) { a == b })
  let show_b = @signals.signal(false, same=fn(a, b) { a == b })
  let box_ref : Ref[View?] = Ref(None)
  let t = Tree::new(
    fn(root) {
      root.box(fn(b) {
        box_ref.val = Some(b)
        b.show(at_once=true, fn() { show_a.get() }, fn(a) { a.width(Is(Some(10.0))) |> ignore })
        b.show(at_once=true, fn() { show_b.get() }, fn(c) { c.width(Is(Some(20.0))) |> ignore })
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(390.0, 844.0) |> ignore
  let b = box_ref.val.unwrap()
  // 0 flex kids
  let fk0 : Array[Int] = []
  t.flex_kids(b.at, fk0)
  assert_eq(fk0.length(), 0)
  assert_eq(t.single_flex_kid(b.at), -1)

  // 1 flex kid through slot
  show_a.set(true)
  t.frame(390.0, 844.0) |> ignore
  let fk1 : Array[Int] = []
  t.flex_kids(b.at, fk1)
  assert_eq(fk1.length(), 1)
  assert_eq(t.single_flex_kid(b.at), fk1[0])

  // 2 flex kids through slots -> early exit -2
  show_b.set(true)
  t.frame(390.0, 844.0) |> ignore
  let fk2 : Array[Int] = []
  t.flex_kids(b.at, fk2)
  assert_eq(fk2.length(), 2)
  assert_eq(t.single_flex_kid(b.at), -2)

  // Back to 1 flex kid
  show_a.set(false)
  t.frame(390.0, 844.0) |> ignore
  let fk3 : Array[Int] = []
  t.flex_kids(b.at, fk3)
  assert_eq(fk3.length(), 1)
  assert_eq(t.single_flex_kid(b.at), fk3[0])
  t.dispose()
}

///|
test "park + take_in across parents after ancestor dedup and retire_parked keep takes_input exact" {
  let parent_a : Ref[View?] = Ref(None)
  let parent_b : Ref[View?] = Ref(None)
  let child_ref : Ref[View?] = Ref(None)
  let leaf_ref : Ref[View?] = Ref(None)
  let t = Tree::new(
    fn(root) {
      root.box(fn(a) {
        parent_a.val = Some(a)
        a.box(fn(child) {
          child_ref.val = Some(child)
          child.box(fn(leaf) {
            leaf_ref.val = Some(leaf)
            @signals.untracked(fn() { leaf.takes_input() }) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      root.box(fn(b) {
        b.presses(Is(false)) |> ignore
        parent_b.val = Some(b)
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(390.0, 844.0) |> ignore
  let a = parent_a.val.unwrap()
  let b = parent_b.val.unwrap()
  let child = child_ref.val.unwrap()
  let leaf = leaf_ref.val.unwrap()
  assert_true(@signals.untracked(fn() { leaf.takes_input() }))

  // Mark ancestor `a`, then attempt to mark `child` (subsumed by ancestor `a`), then park & move `child` under inert `b`.
  t.inputs_marked(a.at)
  t.inputs_marked(child.at)
  let wake = a.park(child)
  b.take_in(child)
  wake()
  t.frame(390.0, 844.0) |> ignore
  assert_false(@signals.untracked(fn() { leaf.takes_input() }))
  assert_eq(t.kept_inputs_said(), None)

  // Park and retire_parked the moved subtree; verify live flags, leaf teardown, and inputs_at hygiene.
  let _ = b.park(child)
  child.retire_parked()
  assert_false(t.nodes[child.at].live)
  assert_false(t.nodes[leaf.at].live)
  t.frame(390.0, 844.0) |> ignore
  assert_eq(t.kept_inputs_said(), None)
  t.dispose()
}

///|
test "multi-Tree InputsAux isolation and Tree::dispose releases removed entries" {
  let base_len = tree_inputs_auxs.length()
  let s1 = @signals.signal(false, same=fn(a, b) { a == b })
  let s2 = @signals.signal(false, same=fn(a, b) { a == b })
  let leaf2 : Ref[View?] = Ref(None)
  let t1 = Tree::new(
    fn(root) {
      root.box(fn(h) {
        h.presses(By(fn() { !s1.get() })) |> ignore
        h.box(fn(l) { @signals.untracked(fn() { l.takes_input() }) |> ignore }) |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  let t2 = Tree::new(
    fn(root) {
      root.box(fn(h) {
        h.presses(By(fn() { !s2.get() })) |> ignore
        h.box(fn(l) {
          leaf2.val = Some(l)
          @signals.untracked(fn() { l.takes_input() }) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t1.frame(390.0, 844.0) |> ignore
  t2.frame(390.0, 844.0) |> ignore
  assert_eq(tree_inputs_auxs.length(), base_len + 2)

  // Disposing t1 removes its entry cleanly while t2 stays fully functional.
  t1.dispose()
  assert_eq(tree_inputs_auxs.length(), base_len + 1)
  s2.set(true)
  t2.frame(390.0, 844.0) |> ignore
  assert_false(@signals.untracked(fn() { leaf2.val.unwrap().takes_input() }))
  assert_eq(t2.kept_inputs_said(), None)

  t2.dispose()
  assert_eq(tree_inputs_auxs.length(), base_len)
}
