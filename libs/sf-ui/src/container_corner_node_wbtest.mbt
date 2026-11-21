// The container's corner lent down on the ladder's terms (container_corner_node.mbt): a panel's card and its row and a
// small block on it each concentric with what holds it, a capsule across a card's foot, at a phone's width, a tablet's
// and a desk's; the corner rule finding nothing in any; what stands too far in or none lent round as it is alone.

///|
/// A panel `pane_corner` round, `panel_card_in` in: a card on it (its rows `corner_inset` in, a row of them with a small
/// block in its start corner), then a card with a capsule across its foot; each corner the lent card's less how far in it
/// stands, none written by hand. `w` wide.
fn nested_corners(w : Double) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w~, h=600.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(panel) {
      let p = panel_card_in
      panel.width(Is(Some(w))).padding(Is((p, p, p, p))).gap(Is(p)).radius(Is(pane_corner)).ground(Is(0xEEEEEEFFL))
      |> ignore
      corner_card_node(panel, fn() { pane_corner }, inset=fn() { p })
      panel.box(fn(card) {
        let i = corner_inset
        card.padding(Is((i, i, i, i))).gap(Is(i)).ground(Is(0xFFFFFFFFL)) |> ignore
        concentric_radius_node(card, fn() { 0.0 })
        corner_card_node(card, fn() { card_corner }, inset=fn() { i })
        for _ in 0..<2 {
          card.box(fn(row) {
            row.padding(Is((i, i, i, i))).ground(Is(0xDDDDDDFFL)) |> ignore
            concentric_radius_node(row, fn() { 0.0 })
            corner_card_node(row, fn() { row_corner }, inset=fn() { i })
            row.box(fn(block) {
              block.width(Is(Some(24.0))).height(Is(Some(24.0))).ground(Is(0x999999FFL)) |> ignore
              concentric_radius_node(block, fn() { 0.0 })
            })
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
      panel.box(fn(card) {
        card.ground(Is(0xFFFFFFFFL)) |> ignore
        concentric_radius_node(card, fn() { 0.0 })
        corner_card_node(card, fn() { card_corner })
        card.box(fn(cap) {
          let d = concentric_capsule_pad(cap, cap_h, 0.0)
          cap.height(Is(Some(cap_h))).margin(Is((d, d, d, d))).radius(Is(cap_h / 2.0)).ground(Is(0x3366CCFFL))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// A capsule's height on a card's foot (a button's).
let cap_h : Double = 36.0

///|
test "nested cards, a row, a small block and a capsule each concentric with what holds them, at every width" {
  for w in [390.0, 840.0, 1280.0] {
    let t = nested_corners(w)
    assert_eq(t.corner_faults(), [])
    assert_eq(t.audit(), [])
  }
}

///|
test "the ladder worked out from the lent corners: a card 26, a row 18, a small block 10, a capsule 8 in" {
  let got : Array[Double] = []
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(panel) {
      corner_card_node(panel, fn() { pane_corner }, inset=fn() { panel_card_in })
      panel.box(fn(card) {
        got.push(concentric_now(card))
        corner_card_node(card, fn() { card_corner }, inset=fn() { corner_inset })
        card.box(fn(row) {
          got.push(concentric_now(row))
          corner_card_node(row, fn() { row_corner }, inset=fn() { corner_inset })
          row.box(fn(block) { got.push(concentric_now(block)) }) |> ignore
        })
        |> ignore
      })
      |> ignore
      panel.box(fn(card) {
        corner_card_node(card, fn() { card_corner })
        card.box(fn(cap) { got.push(concentric_capsule_pad(cap, cap_h, 0.0)) }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(got, [card_corner, row_corner, small_corner, card_foot_in(cap_h)])
}

///|
/// The corner concentric_radius_node gives `v` now.
fn concentric_now(v : @view.View) -> Double {
  @signals.untracked(fn() { concentric_fit(v.container_corner(), fn() { -1.0 }, 0.0) })
}

///|
test "past the theme's ranges or none lent, a corner as it is alone" {
  let got : Array[Double] = []
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(card) {
      corner_card_node(card, fn() { card_corner })
      // (20 in: further than corner_fit's 16)
      card.box(fn(far) {
        got.push(@signals.untracked(fn() { concentric_fit(far.container_corner(), fn() { 7.0 }, 20.0) }))
      })
      |> ignore
      // (4 in: 22 round, within its ranges)
      card.box(fn(near) {
        got.push(@signals.untracked(fn() { concentric_fit(near.container_corner(), fn() { 7.0 }, 4.0) }))
      })
      |> ignore
    })
    |> ignore
    root.box(fn(alone) {
      got.push(concentric_now(alone))
      got.push(concentric_capsule_pad(alone, cap_h, 5.0))
    })
    |> ignore
  })
  t.draw()
  assert_eq(got, [7.0, card_corner - 4.0, -1.0, 5.0])
}
