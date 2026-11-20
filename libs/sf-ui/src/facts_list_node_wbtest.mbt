// The library's facts list (facts_list_node.mbt): its labels in one column as wide as the widest, a fact shown and
// let go of alone, a value of several lines with its label on its first line.

///|
/// A window with keyboard and mouse holding what `make` makes after a node "别处" that takes the focus, its words at
/// `scale` of their size.
fn u5_case(make : (@view.View) -> Unit, scale? : Double = 1.0) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=400.0, platform=0)
  t.check_looks(false)
  if scale != 1.0 {
    t.set_font_scale(scale)
  }
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
// kept across runs: a value (no field of it changes)
let u5_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let u5_words_wrap : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg)

///|
test "a facts list: its values start in one column past the widest label; a fact let go of alone and shown again" {
  let shown = @signals.signal(true)
  let t = u5_case(fn(root) {
    facts_list_node(root, ["来源", "一个很长很长的标签"], fn(list) {
      fact_row_node(list, "来源", fn(v) { words_node(v, fn() { "Slack" }, fn() { u5_words }) |> ignore })
      fact_row_node(list, "一个很长很长的标签", show=fn() { shown.get() }, fn(v) {
        words_node(v, fn() { "三分钟前" }, fn() { u5_words }) |> ignore
      })
    })
    |> ignore
  })
  let (sx, _, _, _) = t.rect_of("Slack").unwrap()
  let (tx, _, _, _) = t.rect_of("三分钟前").unwrap()
  let (lx, _, lw, _) = t.rect_of("一个很长很长的标签").unwrap()
  assert_eq(sx, tx)
  assert_true(sx >= lx + lw, msg="\{sx} \{lx} \{lw}")
  shown.set(false)
  t.run_for(@ui.move_most_ms)
  assert_true(t.rect_of("三分钟前") is None)
  assert_true(t.rect_of("Slack") is Some(_))
  shown.set(true)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.rect_of("三分钟前").map(fn(r) { r.0 }), Some(sx))
  assert_eq(t.audit(), [])
}

///|
test "a facts list: a value of several lines starts at its row's top, its label on its first line" {
  let t = u5_case(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(220.0))) |> ignore
      facts_list_node(b, ["说明"], fn(list) {
        fact_row_node(list, "说明", fn(v) {
          words_node(v, fn() { "第一行的话 第二行的话 第三行的话 第四行的话" }, fn() { u5_words_wrap })
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          |> ignore
        })
      })
      |> ignore
    })
    |> ignore
  })
  let (_, _, ly, _, lh, _) = t.words().filter(fn(w) { w.0 == "说明" })[0]
  let (_, _, vy, _, vh, _) = t.words().filter(fn(w) { w.0.has_prefix("第一行") })[0]
  // (one line of each as tall: the value of several, its first line where the label's is)
  assert_true(vh > lh * 1.5, msg="\{vh} \{lh}")
  assert_true((ly - vy).abs() <= 1.0, msg="\{ly} \{vy}")
}
