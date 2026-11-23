// A flips scrolls_window inside a `transitions_only` subtree receiving a quiet key update (outside any `transition`)
// skips the synchronous `laid_now()` in `set_out` when there is no `foot_room` to deduct, deferring layout to the next
// `Tree::frame`, while preserving `foot_room`, explicit `transition`, and `inner` FLIP behavior.

///|
test "list_window quiet: transitions_only flips list skips synchronous laid_now on quiet key update" {
  for period in [1000.0 / 7.0, 1000.0 / 24.0, 1000.0 / 60.0, 1000.0 / 120.0] {
    let clock = Ref(0.0)
    let keys = @signals.signal([1, 2, 3], same=fn(a, b) { a == b })
    let scroll = Scroll::list()
    let slots : Map[Int, View] = Map([])
    let tree = Tree::new(time=fn() { clock.val }, fn(root) {
      root.transitions_only() |> ignore
      root.box(fn(p) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        p.scrolls_window(
          scroll,
          fn() { keys.get() },
          est=40.0,
          flips=true,
          comes=fn(_) { true },
          fn(slot, k) {
            slots[k] = slot
            slot.box(fn(b) { b.height(Is(Some(40.0))).words(Is("row-\{k}")) |> ignore }) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
    tree.frame(390.0, 400.0, now=0.0) |> ignore
    while clock.val + period <= 60.0 {
      clock.val += period
      tree.frame(390.0, 400.0, now=clock.val) |> ignore
    }
    clock.val = 60.0
    let passes_before = tree.passes_run()
    tree.event(60.0, fn() { keys.set([1, 2, 3, 4]) })
    let passes_in_event = tree.passes_run() - passes_before
    assert_eq(
      passes_in_event,
      0,
      msg="at \{period}: quiet key update ran \{passes_in_event} synchronous layout passes inside Tree::event",
    )
    clock.val += period
    tree.frame(390.0, 400.0, now=clock.val) |> ignore
    assert_true(tree.passes_run() > passes_before, msg="at \{period}: next frame did not lay out")
    assert_true(slots.contains(4), msg="at \{period}: row 4 was not created on next frame")
    let (_, y4, _, h4) = slots[4].placed_window_now()
    assert_true((h4 - 40.0).abs() < 0.5, msg="at \{period}: row 4 height \{h4} != 40")
    assert_true((y4 - 120.0).abs() < 0.5, msg="at \{period}: row 4 top \{y4} != 120")
    assert_true(!answer_marks_left(), msg="at \{period}: marks left set")
    assert_true(!transition_now(), msg="at \{period}: transition left active")
    tree.dispose()
  }
}

///|
fn drawn_of(tree : Tree, label : String) -> (Double, Double)? {
  for d in tree.drawn() {
    if d.words == label {
      return Some((d.y, d.h))
    }
  }
  None
}

///|
test "list_window quiet: explicit transition and inner comes still animate, foot_room still deducts on quiet tail add" {
  let clock = Ref(0.0)
  let keys = @signals.signal([1, 2, 3, 4, 5, 6], same=fn(a, b) { a == b })
  let show_inner = @signals.signal(false)
  let scroll = Scroll::list()
  let slots : Map[Int, View] = Map([])
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
        comes=fn(_) { true },
        leaves_room=fn(k) { k == 10 },
        fn(slot, k) {
          slots[k] = slot
          slot.box(fn(b) {
            b.height(Is(Some(40.0))).words(Is("row-\{k}")) |> ignore
            if k == 5 {
              b.show(fn() { show_inner.get() }, fn(s) {
                s.box(fn(i) { i.height(Is(Some(30.0))) |> ignore }) |> ignore
              })
            }
          })
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 200.0, now=0.0) |> ignore
  clock.val = 16.0
  tree.frame(390.0, 200.0, now=16.0) |> ignore
  let y6_before = drawn_of(tree, "row-6").unwrap().0

  // 1. Explicit transition adds key 10 at tail: must animate (row-6 moves up gradually, not in one jump).
  clock.val = 60.0
  tree.event(60.0, fn() { transition(fn() { keys.set([1, 2, 3, 4, 5, 6, 10]) }) })
  clock.val = 76.0
  tree.frame(390.0, 200.0, now=76.0) |> ignore
  assert_true(slots.contains(10), msg="transition tail row 10 not created")
  let y6_mid = drawn_of(tree, "row-6").unwrap().0
  assert_true(
    y6_mid > y6_before - 39.0,
    msg="transition tail add jumped immediately instead of animating: y6_before=\{y6_before}, y6_mid=\{y6_mid}",
  )
  clock.val = 800.0
  tree.frame(390.0, 200.0, now=800.0) |> ignore
  let y6_end = drawn_of(tree, "row-6").unwrap().0
  assert_true(
    (y6_before - y6_end - 40.0).abs() < 1.0,
    msg="row-6 did not settle 40px higher: before=\{y6_before}, end=\{y6_end}",
  )

  // 2. Transition removes key 10 (leaves_room=true) leaving foot_room=40, then quiet adds key 11 (40 tall) to consume it.
  clock.val = 860.0
  tree.event(860.0, fn() { transition(fn() { keys.set([1, 2, 3, 4, 5, 6]) }) })
  clock.val = 1400.0
  tree.frame(390.0, 200.0, now=1400.0) |> ignore
  let y6_with_room = drawn_of(tree, "row-6").unwrap().0
  clock.val = 1460.0
  tree.event(1460.0, fn() { keys.set([1, 2, 3, 4, 5, 6, 11]) })
  clock.val = 1476.0
  tree.frame(390.0, 200.0, now=1476.0) |> ignore
  let y6_after_quiet = drawn_of(tree, "row-6").unwrap().0
  assert_true(
    (y6_after_quiet - y6_with_room).abs() < 1.0,
    msg="row 6 shifted from \{y6_with_room} to \{y6_after_quiet} instead of consuming foot_room",
  )

  // 3. Inner comes inside a block under transition still triggers FLIP/comes.
  clock.val = 2000.0
  tree.frame(390.0, 200.0, now=2000.0) |> ignore
  let y6_pre_inner = drawn_of(tree, "row-6").unwrap().0
  clock.val = 2060.0
  tree.event(2060.0, fn() { transition(fn() { show_inner.set(true) }) })
  clock.val = 2076.0
  tree.frame(390.0, 200.0, now=2076.0) |> ignore
  let y6_mid_inner = drawn_of(tree, "row-6").unwrap().0
  assert_true(
    y6_mid_inner > y6_pre_inner - 29.0,
    msg="inner comes did not animate: pre=\{y6_pre_inner}, mid=\{y6_mid_inner}",
  )
  assert_true(!answer_marks_left(), msg="marks left set")
  assert_true(!transition_now(), msg="transition left active")
  tree.dispose()
}
