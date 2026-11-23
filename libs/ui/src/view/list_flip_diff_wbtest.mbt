// Unit tests for O(N) FLIP key-diff helpers (`flip_steady_left`, `flip_order_changed`,
// `flip_tail_removed`, `flip_tail_added`) and large-list `flips=true` inner updates.

///|
test "flip_diff helpers: empty, same-ref, add, remove, and reorder edge cases" {
  let empty : Array[Int] = []
  assert_false(flip_steady_left(empty, empty))
  assert_eq(flip_tail_removed(empty, empty), [])
  assert_eq(flip_tail_added(empty, empty), [])

  let a = [1, 2, 3, 4]
  assert_false(flip_steady_left(a, a))
  assert_false(flip_order_changed(a, a, flip_key_set(a), flip_key_set(a)))
  assert_eq(flip_tail_removed(a, a), [])
  assert_eq(flip_tail_added(a, a), [])

  // Equal content, distinct array instances
  let a_copy = [1, 2, 3, 4]
  assert_false(flip_steady_left(a, a_copy))
  assert_false(flip_order_changed(a, a_copy, flip_key_set(a), flip_key_set(a_copy)))
  assert_eq(flip_tail_removed(a, a_copy), [])
  assert_eq(flip_tail_added(a, a_copy), [])

  // Pure removal (strict subset -> steady_left = true)
  let removed_tail = [1, 2]
  assert_true(flip_steady_left(a, removed_tail))
  assert_false(flip_order_changed(a, removed_tail, flip_key_set(a), flip_key_set(removed_tail)))
  assert_eq(flip_tail_removed(a, removed_tail), [3, 4])
  assert_eq(flip_tail_added(a, removed_tail), [])

  // Pure middle removal (still strict subset, no tail removed)
  let removed_mid = [1, 3, 4]
  assert_true(flip_steady_left(a, removed_mid))
  assert_eq(flip_tail_removed(a, removed_mid), [])
  assert_eq(flip_tail_added(a, removed_mid), [])

  // Pure tail addition
  let added_tail = [1, 2, 3, 4, 5, 6]
  assert_false(flip_steady_left(a, added_tail))
  assert_false(flip_order_changed(a, added_tail, flip_key_set(a), flip_key_set(added_tail)))
  assert_eq(flip_tail_removed(a, added_tail), [])
  assert_eq(flip_tail_added(a, added_tail), [5, 6])

  // Mixed remove + add (not steady_left)
  let mixed = [1, 2, 5]
  assert_false(flip_steady_left(a, mixed))
  assert_eq(flip_tail_removed(a, mixed), [3, 4])
  assert_eq(flip_tail_added(a, mixed), [5])

  // Reorder of kept keys
  let reordered = [1, 3, 2, 4]
  assert_false(flip_steady_left(a, reordered))
  assert_true(flip_order_changed(a, reordered, flip_key_set(a), flip_key_set(reordered)))

  // All removed -> empty
  assert_true(flip_steady_left(a, empty))
  assert_eq(flip_tail_removed(a, empty), [1, 2, 3, 4])
  assert_eq(flip_tail_added(a, empty), [])
  assert_eq(flip_tail_added(empty, a), [1, 2, 3, 4])
}

///|
test "list_flip_diff: 2000-key flips=true list handles inner resize cleanly across fps" {
  let base : Array[Int] = Array::makei(2000, fn(i) { i + 1 })
  for fps in [7.0, 24.0, 60.0, 120.0] {
    let period = 1000.0 / fps
    let clock = Ref(0.0)
    let keys = @signals.signal(base, same=fn(a, b) { physical_equal(a, b) })
    let tall = @signals.signal(false, same=fn(a, b) { a == b })
    let scroll = Scroll::list()
    let tree = Tree::new(time=fn() { clock.val }, fn(root) {
      root.transitions_only() |> ignore
      root.box(fn(p) {
        p.width(Is(Some(390.0))).height(Is(Some(200.0))) |> ignore
        p.scrolls_window(
          scroll,
          fn() { keys.get() },
          est=40.0,
          flips=true,
          follows=fn() { true },
          fn(slot, k) {
            slot.box(fn(b) {
              if k == 2000 {
                b.height(By(fn() { Some(if tall.get() { 80.0 } else { 40.0 }) })) |> ignore
                b.resizes() |> ignore
              } else {
                b.height(Is(Some(40.0))) |> ignore
              }
              b.words(Is("row-\{k}")) |> ignore
            })
            |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
    tree.frame(390.0, 200.0, now=0.0) |> ignore
    flip_step_to(tree, clock, 60.0, period)
    let before = flip_drawn_info(tree, "row-2000").unwrap()
    assert_eq(before.1, 40.0)

    // Trigger inner resize on the visible tail row while keys stay at 2000 items.
    clock.val = 60.0
    tree.event(60.0, fn() { transition(fn() { tall.set(true) }) })
    flip_step_to(tree, clock, 600.0, period)
    let after = flip_drawn_info(tree, "row-2000").unwrap()
    assert_eq(after.1, 80.0)
    tree.dispose()
  }
}
