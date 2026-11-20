// A dialog in the middle of the window a share of it tall whose body is nodes (panel_nodes' `tall`, not `hugs`): a list
// filling it (panel_list_node's `fills`) and a button at its foot, on windows 600, 800 and 1000 tall; the dialog's top,
// its height, its foot's button and the list's first row where they stood when they stood where the old view's did, at
// rest and at each moment of its way in. The list's rows are link_row_node's: where the first row's words stand across
// at rest is theirs, the rows' rule in a panel's body (panel_row_at, panel_parts_node.mbt), not the dialog's; a change to
// how far in a row's words stand there fails this too.

///|
/// What the dialog stood as on a window 1200 by `h`, opened by nothing: its dialog's place and size, its button's, its
/// first row's words, at each of `moments` after 打开 is pressed (its way in) and at rest.
fn tall_dialog_stood(h : Double) -> Array[String] {
  let n = 40
  let open = fn(_from : Anchor) {
    panel_nodes(
      "很长的单子",
      from=Unanchored,
      tall=0.86,
      foot=fn(v, _) { button_node(v, fn() { "完成" }, fn() {  }, tone=Primary) |> ignore },
      fn(v, _) {
        panel_list_node(
          v,
          fn() { Array::makei(n, fn(i) { i }) },
          fn(b, i) { link_row_node(b, fn() { "第 \{i} 行" }, fn() {  }, note=fn() { "说明" }) },
          est=60.0,
          fills=true,
        )
        |> ignore
      },
    )
  }
  presenters_reset()
  let t = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=presented_tree(presenting_view(open)),
    w=1200.0,
    h~,
    platform=0,
  )
  t.check_looks(false)
  t.draw()
  let k = fn(v : Double) { (v * 1000.0).round() / 1000.0 }
  let rect = fn(r : (Double, Double, Double, Double)) { "\{k(r.0)},\{k(r.1)} \{k(r.2)}x\{k(r.3)}" }
  let stood : Array[String] = []
  let at = fn(when : String) {
    let dialog = t.all(Dialog, label="很长的单子").map(fn(s) { rect(s.rect) })
    let done = t.all(Button, label="完成").map(fn(s) { rect(s.rect) })
    let first = t.words().filter(fn(w) { w.0 == "第 0 行" }).map(fn(w) { "\{k(w.1)},\{k(w.2)} a\{k(w.5)}" })
    stood.push("\{when}: dialog \{@ui.list_text(dialog)} 完成 \{@ui.list_text(done)} first row \{@ui.list_text(first)}")
  }
  t.tap_text("打开")
  let from = t.time()
  for ms in [0.0, 40.0, 80.0, 120.0, 160.0, 200.0, 280.0, 360.0] {
    t.run_for(from + ms - t.time())
    at("\{ms}")
  }
  t.run_for(@ui.move_most_ms)
  t.leave()
  t.draw()
  at("at rest")
  stood
}

///|
test "a dialog in the middle of the window a share of it tall, holding nodes: its height and its foot where they stood beside the old one's, on windows 600, 800 and 1000 tall, at rest and on its way in" {
  let seen : Array[String] = []
  for h in [600.0, 800.0, 1000.0] {
    seen.push("\{h} tall:")
    seen.append(tall_dialog_stood(h))
  }
  inspect(seen.join("\n"), content=(
    #|600 tall:
    #|0: dialog [345.2,35.52 509.6x540.96] 完成 [774.44,517.68 56.84x35.28] first row [368.72,118.82 a0]
    #|40: dialog [341.882,28.169 516.237x548.005] 完成 [776.712,516.608 57.58x35.739] first row [365.708,112.553 a0.276]
    #|80: dialog [340.632,25.4 518.736x550.658] 完成 [777.567,516.204 57.859x35.912] first row [364.574,110.194 a0.757]
    #|120: dialog [340.201,24.446 519.597x551.572] 完成 [777.862,516.065 57.955x35.972] first row [364.183,109.38 a0.923]
    #|160: dialog [340.039,24.087 519.921x551.916] 完成 [777.973,516.013 57.991x35.995] first row [364.036,109.075 a0.985]
    #|200: dialog [340,24 520x552] 完成 [778,516 58x36] first row [364,109 a1]
    #|280: dialog [340,24 520x552] 完成 [778,516 58x36] first row [364,109 a1]
    #|360: dialog [340,24 520x552] 完成 [778,516 58x36] first row [364,109 a1]
    #|at rest: dialog [340,24 520x552] 完成 [778,516 58x36] first row [364,109 a1]
    #|800 tall:
    #|0: dialog [345.2,38.01 509.6x735.98] 完成 [774.44,715.19 56.84x35.28] first row [368.72,121.31 a0]
    #|40: dialog [341.882,29.389 516.237x745.565] 完成 [776.712,715.388 57.58x35.739] first row [365.708,113.773 a0.276]
    #|80: dialog [340.632,26.142 518.736x749.174] 完成 [777.567,715.462 57.859x35.912] first row [364.574,110.936 a0.757]
    #|120: dialog [340.201,25.023 519.597x750.418] 完成 [777.862,715.488 57.955x35.972] first row [364.183,109.958 a0.923]
    #|160: dialog [340.039,24.603 519.921x750.886] 完成 [777.973,715.498 57.991x35.995] first row [364.036,109.59 a0.985]
    #|200: dialog [340,24.5 520x751] 完成 [778,715.5 58x36] first row [364,109.5 a1]
    #|280: dialog [340,24.5 520x751] 完成 [778,715.5 58x36] first row [364,109.5 a1]
    #|360: dialog [340,24.5 520x751] 完成 [778,715.5 58x36] first row [364,109.5 a1]
    #|at rest: dialog [340,24.5 520x751] 完成 [778,715.5 58x36] first row [364,109.5 a1]
    #|1000 tall:
    #|0: dialog [345.2,53.73 509.6x904.54] 完成 [774.44,899.47 56.84x35.28] first row [368.72,137.03 a0]
    #|40: dialog [341.882,44.011 516.237x916.32] 完成 [776.712,900.765 57.58x35.739] first row [365.708,128.396 a0.276]
    #|80: dialog [340.632,40.351 518.736x920.756] 完成 [777.567,901.253 57.859x35.912] first row [364.574,125.145 a0.757]
    #|120: dialog [340.201,39.09 519.597x922.285] 完成 [777.862,901.421 57.955x35.972] first row [364.183,124.024 a0.923]
    #|160: dialog [340.039,38.616 519.921x922.86] 完成 [777.973,901.485 57.991x35.995] first row [364.036,123.603 a0.985]
    #|200: dialog [340,38.5 520x923] 完成 [778,901.5 58x36] first row [364,123.5 a1]
    #|280: dialog [340,38.5 520x923] 完成 [778,901.5 58x36] first row [364,123.5 a1]
    #|360: dialog [340,38.5 520x923] 完成 [778,901.5 58x36] first row [364,123.5 a1]
    #|at rest: dialog [340,38.5 520x923] 完成 [778,901.5 58x36] first row [364,123.5 a1]
  ))
}

///|
test "a tall dialog's panel_list_node scrollbar hugs the dialog's right edge within scroll_bar_inset" {
  let open = fn(_from : Anchor) {
    panel_nodes(
      "很长的单子",
      from=Unanchored,
      tall=0.86,
      foot=fn(v, _) { button_node(v, fn() { "完成" }, fn() {  }, tone=Primary) |> ignore },
      fn(v, _) {
        panel_list_node(
          v,
          fn() { Array::makei(40, fn(i) { i }) },
          fn(b, i) { link_row_node(b, fn() { "第 \{i} 行" }, fn() {  }, note=fn() { "说明" }) },
          est=60.0,
          fills=true,
        )
        |> ignore
      },
    )
  }
  presenters_reset()
  let t = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=presented_tree(presenting_view(open)),
    w=1200.0,
    h=800.0,
    platform=0,
  )
  t.check_looks(false)
  t.draw()
  t.tap_text("打开")
  t.run_for(@ui.move_most_ms)
  let dialog = t.all(Dialog, label="很长的单子")[0].rect
  let dialog_right = dialog.0 + dialog.2
  t.wheel(dialog.0 + dialog.2 / 2.0, dialog.1 + dialog.3 / 2.0, 200.0)
  t.run_for(@ui.move_most_ms)
  let thumbs = t
    .drawn_order()
    .filter(fn(d) { d.0 == 0 && d.3 == @ui.scroll_bar_size && d.1 > dialog.0 && d.1 < dialog_right && d.5 > 0.0 })
  assert_eq(thumbs.length(), 1, msg="dialog scrollbar thumb count: \{Repr(thumbs)}")
  let thumb_right = thumbs[0].1 + thumbs[0].3
  assert_true(
    (thumb_right - (dialog_right - @ui.scroll_bar_inset)).abs() <= 0.01,
    msg="thumb_right=\{thumb_right} expected=\{dialog_right - @ui.scroll_bar_inset}",
  )
}
