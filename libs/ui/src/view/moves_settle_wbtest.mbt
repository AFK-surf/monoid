// View::laid_before_moves (view.mbt, transition.mbt): under View::transitions_only, non-transition events defer
// settlement to the next frame instead of running synchronous settle_now at event end; an outer @view.transition
// lazily settles any pending prior non-transition layout before its body runs so moves_for reads the exact pre-change
// placement.

///|
test "laid_before_moves: non-transition events defer settle to frame and input transition skips trailing settle" {
  let clock = Ref(0.0)
  let pad = @signals.signal(0.0)
  let mode = @signals.signal(0)
  let target : Ref[View?] = Ref(None)
  let tree = Tree::new(time=fn() { clock.val }, fn(root) {
    root.transitions_only() |> ignore
    root.box(fn(col) {
      col.laid_before_moves()
      col.box(fn(spacer) { spacer.height(By(fn() { Some(pad.get()) })) |> ignore }) |> ignore
      col.box(fn(mode_spacer) {
        mode_spacer.height(By(fn() { Some(if mode.get() == 1 { 20.0 } else { 0.0 }) })) |> ignore
      })
      |> ignore
      col.box(fn(b) {
        target.val = Some(b)
        b.height(Is(Some(40.0))) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  let t = target.val.unwrap()
  assert_eq(t.placed_window_now().1, 0.0)

  let settles0 = tree.work.settles
  let passes0 = tree.work.passes
  clock.val = 20.0
  tree.event(20.0, fn() { pad.set(10.0) })
  clock.val = 40.0
  tree.event(40.0, fn() { pad.set(25.0) })
  clock.val = 60.0
  tree.event(60.0, fn() { pad.set(50.0) })
  assert_eq(tree.work.settles, settles0)
  assert_eq(tree.work.passes, passes0)

  clock.val = 66.0
  tree.frame(390.0, 844.0, now=66.0) |> ignore
  assert_eq(tree.work.passes, passes0 + 1)
  assert_eq(t.placed_window_now().1, 50.0)

  let settles1 = tree.work.settles
  let passes1 = tree.work.passes
  clock.val = 80.0
  tree.input(80.0, fn() { transition(fn() { mode.set(1) }) })
  assert_eq(tree.work.settles, settles1)
  assert_eq(tree.work.passes, passes1)

  clock.val = 96.0
  tree.frame(390.0, 844.0, now=96.0) |> ignore
  assert_eq(t.placed_window_now().1, 70.0)
  tree.dispose()
}

///|
test "laid_before_moves: transition entry lazily settles prior non-transition layout before moves_for reads placement" {
  let clock = Ref(0.0)
  let pad = @signals.signal(0.0)
  let mode = @signals.signal(0)
  let target : Ref[View?] = Ref(None)
  let seen_placed_y = Ref(-1.0)
  let seen_laid_y = Ref(-1.0)
  let tree = Tree::new(time=fn() { clock.val }, fn(root) {
    root.transitions_only() |> ignore
    root.box(fn(col) {
      col.laid_before_moves()
      col.box(fn(spacer) { spacer.height(By(fn() { Some(pad.get()) })) |> ignore }) |> ignore
      col.box(fn(mode_spacer) {
        mode_spacer.height(By(fn() { Some(if mode.get() == 1 { 30.0 } else { 0.0 }) })) |> ignore
      })
      |> ignore
      col.box(fn(b) {
        target.val = Some(b)
        b.height(Is(Some(40.0))) |> ignore
      })
      |> ignore
      let initialized = Ref(false)
      col.reacts(fn() { mode.get() }, fn(_) {
        if !initialized.val {
          initialized.val = true
          return
        }
        if col.transition_gate() {
          let b = target.val.unwrap()
          seen_placed_y.val = b.placed_window_now().1
          seen_laid_y.val = b.laid_window_now().1
        }
      })
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  assert_eq(target.val.unwrap().placed_window_now().1, 0.0)

  clock.val = 100.0
  tree.event(100.0, fn() { pad.set(60.0) })
  assert_eq(tree.work.settles, 0)

  // A no-op transition (0 signal writes) must not force premature settlement of prior non-transition layout
  clock.val = 110.0
  tree.event(110.0, fn() { transition(fn() { () }) })
  assert_eq(tree.work.settles, 0)

  clock.val = 120.0
  tree.event(120.0, fn() { transition(fn() { mode.set(1) }) })
  assert_eq(seen_placed_y.val, 60.0)
  assert_eq(seen_laid_y.val, 90.0)
  tree.dispose()
}

///|
test "laid_before_moves: lit_all(false) drains looks_due synchronously without leaving lit content" {
  let clock = Ref(0.0)
  let lit_node : Ref[View?] = Ref(None)
  let tree = Tree::new(time=fn() { clock.val }, fn(root) {
    root.transitions_only() |> ignore
    root.box(fn(col) {
      col.laid_before_moves()
      col.box(fn(b) {
        lit_node.val = Some(b)
        b
        .width(Is(Some(80.0)))
        .height(Is(Some(24.0)))
        .ground(By(fn() { if b.pointed() { 0xFF112233L } else { 0L } }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  let b = lit_node.val.unwrap()
  assert_eq(tree.nodes[b.at].look.ground, 0L)

  tree.lit_all(true)
  tree.frame(390.0, 844.0, now=16.0) |> ignore
  assert_eq(tree.nodes[b.at].look.ground, 0xFF112233L)
  assert_eq(tree.nodes[b.at].content.unwrap().ground, 0xFF112233L)

  tree.lit_all(false)
  assert_true(tree.looks_due.is_empty())
  assert_eq(tree.nodes[b.at].look.ground, 0L)
  assert_eq(tree.nodes[b.at].content.unwrap().ground, 0L)
  tree.dispose()
}
