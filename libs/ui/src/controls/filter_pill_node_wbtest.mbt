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
test "filter_pill_node: compact 28pt capsule with 20pt concentric ×; hover lights outer capsule without nested inner pill" {
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.row(Is(true)).lines_up(Is(Some(Start))).padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
      filter_pill_node(
        root,
        fn() { "Comma" },
        fn(_) {  },
        picked=fn() { true },
        chevron=false,
        lead=fn(b) { icon_node(b, "folder", 13.0, By(fn() { theme().p.muted })) |> ignore },
        clear=fn() {  },
        clear_label=fn() { "清除项目筛选" },
      )
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  t.run_for(@ui.move_most_ms)
  let main_btn = t.get(Button, label="Comma")
  let clear_btn = t.get(Button, label="清除项目筛选")
  assert_eq(main_btn.rect.3, 28.0, msg="filter pill height should be 28pt: \{main_btn.rect.3}")
  assert_eq(clear_btn.rect.2, 20.0, msg="clear button width should be 20pt: \{clear_btn.rect.2}")
  assert_eq(clear_btn.rect.3, 20.0, msg="clear button height should be 20pt: \{clear_btn.rect.3}")
  assert_eq(t.audit(), [], msg="rest audit")
  assert_eq(t.corner_faults(), [], msg="rest corners")
  let rest_pill = t.boxes_held().filter(fn(b) { b.border_w > 0.0 && b.h == 28.0 })
  assert_eq(rest_pill.length(), 1, msg="expected 1 outer pill box at rest")
  let pill_box = rest_pill[0]
  let rest_bg = pill_box.bg
  // Concentricity: × sits 4pt from top, bottom, and right edge of the 28pt outer capsule.
  assert_true((clear_btn.rect.1 - pill_box.y - 4.0).abs() <= 0.5, msg="top inset")
  assert_true(((pill_box.x + pill_box.w) - (clear_btn.rect.0 + clear_btn.rect.2) - 4.0).abs() <= 0.5, msg="right inset")
  // Hover primary label: outer capsule lights up and sharpens border; zero nested inner pill ground drawn.
  t.move_to(main_btn.rect.0 + main_btn.rect.2 / 2.0, main_btn.rect.1 + main_btn.rect.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.audit(), [], msg="hover label audit")
  assert_eq(t.corner_faults(), [], msg="hover label corners")
  let grounds_on_label = t.boxes_held().filter(fn(b) { (b.bg & 0xFFL) > 0L && b.w >= 16.0 && b.h >= 16.0 && b.x >= pill_box.x - 0.5 && b.x + b.w <= pill_box.x + pill_box.w + 0.5 })
  assert_eq(grounds_on_label.length(), 1, msg="hovering label must paint only the single outer capsule, never a nested inner pill")
  assert_true(grounds_on_label[0].bg != rest_bg, msg="outer capsule ground must shift on label hover")
  assert_eq(grounds_on_label[0].border_c, theme().p.line_strong, msg="outer capsule edge must sharpen to Border on label hover")
  // Hover ×: outer capsule returns to rest ground while concentric × circle lights up.
  t.move_to(clear_btn.rect.0 + clear_btn.rect.2 / 2.0, clear_btn.rect.1 + clear_btn.rect.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.audit(), [], msg="hover clear audit")
  assert_eq(t.corner_faults(), [], msg="hover clear corners")
  let pill_on_clear = t.boxes_held().filter(fn(b) { b.border_w > 0.0 && b.h == 28.0 })
  assert_eq(pill_on_clear.length(), 1)
  assert_eq(pill_on_clear[0].bg, rest_bg, msg="outer capsule ground must stay at rest when hovering ×")
  assert_eq(pill_on_clear[0].border_c, theme().p.line, msg="outer capsule edge must stay Line when hovering ×")
  let clear_lit = t.boxes_held().filter(fn(b) { (b.bg & 0xFFL) > 0L && (b.w - 20.0).abs() <= 0.5 && (b.h - 20.0).abs() <= 0.5 })
  assert_eq(clear_lit.length(), 1, msg="concentric × circle must light up when hovered")
  // 2.0x font scale grows cleanly with zero fixed_outgrown or squeeze_faults.
  t.move_to(0.0, 0.0)
  t.set_font_scale(2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.fixed_outgrown(), [], msg="2.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="2.0x squeeze_faults")
  t.set_font_scale(1.0)
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

///|
test "count_chip_small: 1.0x keeps exact 24pt; 2.0x scales height with zero fixed_outgrown or squeeze_faults" {
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.row(Is(true)).lines_up(Is(Some(Start))).padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
      count_chip_node(root, fn() { "Station" }, fn(_) {  }, look=Small, count=fn() { "3/4" }) |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  assert_eq(t.get(Button, label="Station 3/4").rect.3, @ui.Space::S6.px(), msg="1.0x height")
  assert_eq(t.fixed_outgrown(), [], msg="1.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.0x squeeze_faults")
  assert_eq(t.audit(), [], msg="1.0x audit")
  t.set_font_scale(2.0)
  t.draw()
  let h2 = t.get(Button, label="Station 3/4").rect.3
  assert_true(h2 > @ui.Space::S6.px(), msg="2.0x height grew: \{h2}")
  assert_eq(t.fixed_outgrown(), [], msg="2.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="2.0x squeeze_faults")
  assert_eq(t.audit(), [], msg="2.0x audit")
}
