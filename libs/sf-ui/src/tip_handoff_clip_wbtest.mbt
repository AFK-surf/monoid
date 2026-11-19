// A tip handed from a narrow one to a wide one (TipLayer's handoff, motion's HandPart::draws carrying its words) over
// words under it: its words cut to its ground as that goes from the narrow one's shape to its own, never drawn past it
// over what is under it.

///|
test "a narrow tip handed to a wide one over words under it: the wide one's words cut to its ground all its way, none over what is under it" {
  let (wide_at, _) = roving_cold(1)
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=300.0, platform=0, words_over_held=false)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    let layer : Ref[@view.View?] = Ref(None)
    let tips = TipLayer::new(fn() { layer.val })
    root.box(fn(r) {
      r.row(Is(true)).padding(Is((200.0, 40.0, 0.0, 0.0))) |> ignore
      for label in roving_labels {
        r.box(fn(b) {
          tool_node(
            b,
            fn() { { icon: "copy", label, on: false, disabled: false } },
            fn() { page_viewer_ink() },
            Is(tool_side / 2.0),
            fn() {  },
            tip=tips,
          )
          |> ignore
        })
        |> ignore
      }
    })
    |> ignore
    // (words under where the tips come, across the row)
    root.box(fn(u) {
      u.over(Is(true)).offset(Is((0.0, wide_at.1 + 2.0))).width(Is(Some(600.0))) |> ignore
      words_node(u, fn() { "四十分钟前 四十分钟前 四十分钟前 四十分钟前 四十分钟前 四十分钟前 四十分钟前 四十分钟前" }, fn() {
        u13_value
      })
      |> ignore
    })
    |> ignore
    layer.val = Some(root.box(fn(l) { l.over(Is(true)) |> ignore }))
  })
  t.draw()
  let (x, y) = roving_tool_at(t, 0)
  t.move_to(x, y)
  t.run_for(tip_delay_ms + tip_settled_ms)
  let rest = t.words_over_now().filter(fn(p) { p.contains(roving_labels[1]) })
  let (x, y) = roving_tool_at(t, 1)
  t.move_to(x, y)
  let over : Array[String] = []
  for _ in 0..<12 {
    t.run_for(tip_hand_step_ms * 4.0)
    for p in t.words_over_now() {
      if p.contains(roving_labels[1]) {
        over.push("\{t.time()}: \{p}")
      }
    }
  }
  assert_eq((rest, over), ([], []))
}
