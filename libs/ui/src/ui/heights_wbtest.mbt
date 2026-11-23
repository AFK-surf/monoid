// One height for what is pressed side by side (heights.mbt, Tester::height_faults): a row of buttons of the window's
// tree, one of them another height, found; all alike, or one only wrapped in a box as big as it (#6246's stop in the
// row of 只看收发 and 详情), or taller than a control is, as the rule says.

///|
/// A button of the window's tree in `v`, `h` high, 60 wide, its ground 8 round, named `name`.
fn height_button(v : @view.View, name : String, h : Double) -> Unit {
  v.box(fn(b) {
    b
    .width(Is(Some(60.0)))
    .height(Is(Some(h)))
    .ground(Is(0xEEEEEEFFL))
    .radius(Is(8.0))
    .on_press(fn() {  })
    .says(Is(Some(@view.said(Button, label=name))))
    |> ignore
  })
  |> ignore
}

///|
/// The rule's faults on a row, 8 apart, of buttons `heights` high, the last wrapped in a box as big as it where
/// `wrapped`.
fn heights_row(heights : Array[Double], wrapped? : Bool = false) -> Array[String] {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0, platform=0, corners_held=false)
  set_view_app(fn(root) {
    root.box(fn(row) {
      row.row(Is(true)).gap(Is(8.0)) |> ignore
      for i, h in heights {
        let name = "b\{i}"
        if wrapped && i == heights.length() - 1 {
          row.box(fn(w) { height_button(w, name, h) }) |> ignore
        } else {
          height_button(row, name, h)
        }
      }
    })
    |> ignore
  })
  t.draw()
  t.height_faults()
}

///|
test "one height in a row: a button 24 high among two 36 high found, the one 24 named; all 36 nothing" {
  let off = heights_row([36.0, 36.0, 24.0])
  assert_eq(off.length(), 1, msg=off.join("\n"))
  assert_true(off[0].contains("at 136,0 60×24") && off[0].contains("in its row 36"), msg=off[0])
  assert_eq(heights_row([36.0, 36.0, 36.0]), [])
}

///|
test "one height in a row: one wrapped in a box as big as it is still of the row (#6246's stop); a card's 60 is no control's" {
  let off = heights_row([22.0, 22.0, 24.0], wrapped=true)
  assert_eq(off.length(), 1, msg=off.join("\n"))
  assert_eq(heights_row([36.0, 60.0]), [])
}

///|
/// A tile of the window's tree in `v`, 40 high and wide, its ground 8 round, pressed as a whole, named `name`: marked
/// a tile (tree_mark_tile) where `marked`. Its node.
fn height_tile(v : @view.View, name : String, marked : Bool) -> @view.View {
  v.box(fn(b) {
    b
    .width(Is(Some(40.0)))
    .height(Is(Some(40.0)))
    .ground(Is(0xDDDDDDFFL))
    .radius(Is(8.0))
    .on_press(fn() {  })
    .says(Is(Some(@view.said(Button, label=name))))
    |> ignore
    if marked {
      tree_mark_tile(b)
    }
  })
}

///|
test "one height in a row: a tile marked so (tree_mark_tile) beside a button is no control of the row; unmarked, it is; let go, it is marked no more and one made after it is not" {
  let row_of = fn(marked : Bool) -> Array[String] {
    let t = Tester::tree(
      fn(root) {
        root.box(fn(row) {
          row.row(Is(true)).gap(Is(8.0)) |> ignore
          height_tile(row, "mark", marked) |> ignore
          height_button(row, "more", 44.0)
        })
        |> ignore
      },
      w=400.0,
      h=200.0,
      platform=0,
      corners_held=false,
    )
    t.draw()
    t.height_faults()
  }
  assert_eq(row_of(true), [])
  let off = row_of(false)
  assert_eq(off.length(), 1, msg=off.join("\n"))
  assert_true(off[0].contains("40×40") && off[0].contains("in its row 44"), msg=off[0])
  // (the marked tile let go, an unmarked one made in its place: what was kept for the one let go forgotten, none kept
  // for the new one, whatever index it is made at; its row lining them up in the middle, as a page's head does, so the
  // pick's box is as big as the tile)
  let which = @signals.signal(true, same=fn(a, b) { a == b })
  let made : Array[@view.NodeId] = []
  let t = Tester::tree(
    fn(root) {
      root.box(fn(row) {
        row.row(Is(true)).lines_up(Is(Some(@view.Along::Middle))).gap(Is(8.0)) |> ignore
        row.pick(at_once=true, fn() { which.get() }, fn(v, marked) {
          made.push(height_tile(v, "mark", marked).id())
        })
        height_button(row, "more", 44.0)
      })
      |> ignore
    },
    w=400.0,
    h=200.0,
    platform=0,
    corners_held=false,
  )
  t.draw()
  assert_eq(made.length(), 1)
  assert_true(tree_height_tiles.contains(made[0]))
  assert_eq(t.height_faults(), [])
  which.set(false)
  t.draw()
  assert_eq(made.length(), 2)
  assert_false(tree_height_tiles.contains(made[0]))
  assert_false(tree_height_tiles.contains(made[1]))
  let off = t.height_faults()
  assert_eq(off.length(), 1, msg=off.join("\n"))
}
