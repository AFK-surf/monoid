// The library's filter pill, count chip and one-of rows (filter_pill_node.mbt): the pill's × clearing what is picked
// and gone with it; a chip chosen read out selected; the rows one radio group, Tab stopping once, ↑ ↓ picking along it.

///|
/// A window with keyboard and mouse holding what `make` makes after a node "别处" that takes the focus.
fn pill_case(make : (@view.View) -> Unit) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=400.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(e) {
      e
      .width(Is(Some(40.0)))
      .height(Is(Some(40.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="别处"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    make(root)
  })
  t.draw()
  t
}

///|
test "a filter pill: pressed it opens; picked, its × clears it and goes with it" {
  let picked = @signals.signal("Office")
  let opened = Ref(0)
  let t = pill_case(fn(root) {
    filter_pill_node(
      root,
      fn() { if picked.get() == "" { "选择" } else { picked.get() } },
      fn(_) { opened.val += 1 },
      picked=fn() { picked.get() != "" },
      clear=fn() { picked.set("") },
      clear_label=fn() { "清除" },
    )
    |> ignore
  })
  t.click(Button, label="Office")
  t.draw()
  assert_eq(opened.val, 1)
  t.click(Button, label="清除")
  t.run_for(@ui.move_most_ms)
  assert_eq(picked.get(), "")
  assert_eq(t.all(Button, label="清除").length(), 0)
  assert_eq(t.all(Button, label="选择").length(), 1)
}

///|
test "count chips to choose between: the one chosen read out selected, a press choosing another" {
  let now = @signals.signal("A")
  let t = pill_case(fn(root) {
    for name in ["A", "B"] {
      count_chip_node(root, fn() { name }, fn(_) { now.set(name) }, count=fn() { "3/4" }, chosen=fn() { now.get() == name }, dot=fn() {
        "online"
      })
      |> ignore
    }
  })
  assert_eq(t.all(Button, selected=true).map(fn(s) { s.label }), ["A 3/4"])
  t.click(Button, label="B 3/4")
  t.draw()
  assert_eq(now.get(), "B")
  assert_eq(t.all(Button, selected=true).map(fn(s) { s.label }), ["B 3/4"])
}

///|
test "one-of rows: one radio group, Tab stopping at the one picked alone, ↓ ↑ picking along it round from its ends" {
  let now = @signals.signal("medium")
  let told = []
  let t = pill_case(fn(root) {
    radio_rows_node(root, fn() { "思考程度" }, fn() { [("low", "低"), ("medium", "中"), ("high", "高")] }, fn() { now.get() }, fn(v) {
      told.push(v)
      now.set(v)
    }, fn(b, words, _) { words_node(b, words, fn() { paragraph }) |> ignore })
    |> ignore
  })
  assert_eq(t.all(RadioGroup, label="思考程度").length(), 1)
  assert_eq(t.all(Radio).length(), 3)
  t.act(Button, Focus, label="别处")
  t.tab()
  assert_eq(t.focused().map(fn(s) { s.label }), Some("中"))
  t.key(@ui.key_code_down)
  t.draw()
  t.key(@ui.key_code_down)
  t.draw()
  t.key(@ui.key_code_up)
  t.draw()
  assert_eq(told, ["high", "low", "high"])
  assert_eq(t.all(Radio, checked=On).map(fn(s) { s.label }), ["高"])
  t.tab()
  assert_true(t.focused().map(fn(s) { s.role != Radio }).unwrap_or(true), msg=t.focus_said())
}
