// A hover card on a touch screen, closed and not kept open (hover_card_node's state): no mouse's pointer to rest on what
// it is of, so a finger's press anywhere in the window wakes none of its kind; opened by a finger's hold, it reads the
// window's presses and whether it takes input again, closed as it takes none.

///|
test "ten hover cards closed on a touch screen: none follows whether a press is held in the window, so a finger's tap on nothing wakes none of them; one held open by a finger closes as its trigger takes no input, and once closed follows the window's presses no more" {
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=500.0, platform=1)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    let layer : Ref[@view.View?] = Ref(None)
    let tips = TipLayer::new(fn() { layer.val })
    root.row(Is(true)) |> ignore
    for i in 0..<10 {
      root.box(fn(k) {
        k
        .width(Is(Some(60.0)))
        .height(Is(Some(32.0)))
        .says(Is(Some(@view.said(Text, label="名 \{i}"))))
        |> ignore
        hover_card_node(tips, k, fn(b) { b.box(fn(w) { w.words(Is("卡 \{i}")) |> ignore }) |> ignore }) |> ignore
      })
      |> ignore
    }
    layer.val = Some(root.box(fn(l) { l.over(Is(true)) |> ignore }))
  })
  t.draw()
  t.run_for(hover_settled_ms)
  let tree = @ui.view_tree().unwrap()
  assert_false(tree.held_anywhere.watched(), msg="whether a press is held in the window followed by no card")
  t.touch(0, 700.0, 400.0)
  t.touch(2, 700.0, 400.0)
  t.run_for(hover_settled_ms)
  assert_false(tree.held_anywhere.watched(), msg="after a tap on nothing")
  // (held open by a finger: its trigger taking no input closes it)
  let takes = @signals.signal(true)
  let h = hover_rig(platform=1, takes~)
  let (x, y) = h.on("甲")
  h.t.touch(0, x, y)
  h.t.run_for(@ui.long_press_ms + hover_settled_ms)
  h.t.touch(2, x, y)
  h.t.run_for(hover_settled_ms)
  assert_true(h.open("甲"), msg="held: open")
  assert_true(@ui.view_tree().unwrap().held_anywhere.watched(), msg="open: the window's presses followed")
  assert_true(@ui.view_tree().unwrap().pressed_anywhere.watched(), msg="open: a press anywhere followed, to close it")
  takes.set(false)
  h.t.run_for(hover_settled_ms)
  assert_false(h.open("甲"), msg="its trigger taking no input: closed")
  // (closed again: the card made once is kept, but none of the window's presses followed by it)
  assert_false(@ui.view_tree().unwrap().pressed_anywhere.watched(), msg="closed again: no press anywhere followed")
}
