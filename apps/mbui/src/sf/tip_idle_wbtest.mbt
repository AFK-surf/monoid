// A tip no finger holds (tip_node's hand Free) reads neither the window's presses nor its taps (View::window_downs,
// window_taps): a press or a tap anywhere in the window wakes none of them. One let go by the finger that held it open
// still goes at the next press, wherever it lands (tool_node_wbtest's finger_held_tip); one tapped open, at the next
// tap (sfapp's tape_bar_wbtest).

///|
test "twenty tips no finger holds: none follows the window's presses or taps, so a finger's tap on nothing wakes none of them" {
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=500.0, platform=1)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    let layer : Ref[@view.View?] = Ref(None)
    let tips = TipLayer::new(fn() { layer.val })
    root.row(Is(true)) |> ignore
    for i in 0..<20 {
      root.box(fn(k) {
        k.width(Is(Some(36.0))).height(Is(Some(36.0))).says(Is(Some(@view.said(Text, label="图 \{i}")))) |> ignore
        tip_node(tips, k, fn() { "提示 \{i}" }) |> ignore
      })
      |> ignore
    }
    layer.val = Some(root.box(fn(l) { l.over(Is(true)) |> ignore }))
  })
  t.draw()
  let tree = @ui.view_tree().unwrap()
  let follows = fn() { (tree.pressed_anywhere.watched(), tree.tapped_anywhere.watched()) }
  assert_eq(follows(), (false, false), msg="the window's presses and taps followed by no tip")
  t.touch(0, 700.0, 400.0)
  t.touch(2, 700.0, 400.0)
  t.run_for(tip_settled_ms)
  assert_eq(follows(), (false, false), msg="after a tap on nothing")
}
