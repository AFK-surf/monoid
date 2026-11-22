// A container's corner lent down what it holds (container_corner.mbt): one card, a window's panel's card's row three
// deep, the window's corner going square as it is maximized, none lent, a control at a row's end out of its corner.

///|
/// What `l` is now.
fn corner_now(l : Live[Double]) -> Double {
  match l {
    Is(v) => v
    By(f) => f()
  }
}

///|
/// A tree made by `make`, laid out once; let go after `check`.
fn corner_tree(make : (View) -> Unit, check : () -> Unit raise) -> Unit raise {
  let t = Tree::new(make, time=fn() { 0.0 })
  t.frame(400.0, 300.0) |> ignore
  check()
  t.dispose()
}

///|
test "container corner: a card's row concentric with it, its padding in" {
  let row : Ref[Live[Double]] = Ref(Is(-1.0))
  let alone : Ref[Live[Double]] = Ref(Is(-1.0))
  corner_tree(
    fn(root) {
      root.box(fn(card) {
        card.padding(Is((8.0, 8.0, 8.0, 8.0))).corner_scope(fn() { 26.0 }, inset=fn() { 8.0 }) |> ignore
        card.box(fn(r) { row.val = r.concentric_radius(fn() { 99.0 }) }) |> ignore
      })
      |> ignore
      root.box(fn(o) { alone.val = o.concentric_radius(fn() { 26.0 }) }) |> ignore
    },
    fn() raise {
      assert_eq(corner_now(row.val), 18.0)
      // (none lent outside the card: its own)
      assert_eq(corner_now(alone.val), 26.0)
    },
  )
}

///|
test "container corner: window, panel, card, row: each inset added on the way down" {
  let window = @signals.signal(16.0, same=fn(a, b) { a == b })
  let panel_r : Ref[Live[Double]] = Ref(Is(-1.0))
  let card_r : Ref[Live[Double]] = Ref(Is(-1.0))
  let row_r : Ref[Live[Double]] = Ref(Is(-1.0))
  let end_pad : Ref[Live[Double]] = Ref(Is(-1.0))
  corner_tree(
    fn(root) {
      root.box(fn(w) {
        // (the window: 42 round in this test's theme, its panels 6 in)
        w.corner_scope(fn() { window.get() + 26.0 }) |> ignore
        w.box(fn(panel) {
          panel.corner_inset(fn() { 6.0 }) |> ignore
          panel_r.val = panel.concentric_radius(fn() { 0.0 })
          panel.box(fn(card) {
            card.corner_inset(fn() { 10.0 }) |> ignore
            card_r.val = card.concentric_radius(fn() { 0.0 })
            card.box(fn(row) {
              row.corner_inset(fn() { 8.0 }) |> ignore
              row_r.val = row.concentric_radius(fn() { 0.0 })
              end_pad.val = row.concentric_end_pad(12.0)
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    fn() raise {
      assert_eq(corner_now(panel_r.val), 36.0)
      assert_eq(corner_now(card_r.val), 26.0)
      assert_eq(corner_now(row_r.val), 18.0)
      assert_eq(corner_now(end_pad.val), 18.0)
      // (the window's corner changing, every one of them follows)
      window.set(0.0)
      assert_eq(corner_now(panel_r.val), 20.0)
      assert_eq(corner_now(card_r.val), 10.0)
      assert_eq(corner_now(row_r.val), 2.0)
      assert_eq(corner_now(end_pad.val), 12.0)
    },
  )
}

///|
test "container corner: maximized to square, what follows it stands alone" {
  let window = @signals.signal(16.0, same=fn(a, b) { a == b })
  let panel_r : Ref[Live[Double]] = Ref(Is(-1.0))
  let tight : Ref[Live[Double]] = Ref(Is(-1.0))
  corner_tree(
    fn(root) {
      root.box(fn(w) {
        w.corner_scope(fn() { window.get() }) |> ignore
        w.box(fn(panel) {
          panel_r.val = panel.concentric_radius(fn() { 12.0 }, extra_inset=fn() { 6.0 })
          tight.val = panel.concentric_radius(fn() { 12.0 }, extra_inset=fn() { 6.0 }, min_radius=11.0)
        })
        |> ignore
      })
      |> ignore
    },
    fn() raise {
      assert_eq(corner_now(panel_r.val), 10.0)
      // (concentric only at 11 or more: its own under that)
      assert_eq(corner_now(tight.val), 12.0)
      window.set(0.0)
      assert_eq(corner_now(panel_r.val), 12.0)
      // (as far in as the corner is round: no corner left, its own)
      window.set(6.0)
      assert_eq(corner_now(panel_r.val), 12.0)
    },
  )
}

///|
test "container corner: none lent, an inset is nothing and each falls back" {
  let r : Ref[Live[Double]] = Ref(Is(-1.0))
  let pad : Ref[Live[Double]] = Ref(Is(-1.0))
  let lent : Ref[Bool] = Ref(true)
  corner_tree(
    fn(root) {
      root.box(fn(b) {
        b.corner_inset(fn() { 8.0 }) |> ignore
        lent.val = b.container_corner() is Some(_)
        r.val = b.concentric_radius(fn() { 7.0 })
        pad.val = b.concentric_end_pad(16.0)
      })
      |> ignore
    },
    fn() raise {
      assert_eq(lent.val, false)
      assert_eq(corner_now(r.val), 7.0)
      assert_eq(corner_now(pad.val), 16.0)
    },
  )
}

///|
test "container corner: a switch at a card's row's end out of the card's corner" {
  let first : Ref[Live[Double]] = Ref(Is(-1.0))
  let deep : Ref[Live[Double]] = Ref(Is(-1.0))
  corner_tree(
    fn(root) {
      root.box(fn(card) {
        // (a card 26 round, its rows 8 in: the switch's end 18 in from the row's, its corner's reach)
        card.corner_scope(fn() { 26.0 }, inset=fn() { 8.0 }) |> ignore
        card.box(fn(row) { first.val = row.concentric_end_pad(12.0) }) |> ignore
        card.box(fn(row) {
          // (a row 16 further in: the card's corner reaches no further than its own room)
          row.corner_inset(fn() { 16.0 }) |> ignore
          deep.val = row.concentric_end_pad(12.0)
        })
        |> ignore
      })
      |> ignore
    },
    fn() raise {
      assert_eq(corner_now(first.val), 18.0)
      assert_eq(corner_now(deep.val), 12.0)
    },
  )
}
