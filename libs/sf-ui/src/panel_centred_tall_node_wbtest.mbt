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
    #|0: dialog [345.2,35.52 509.6x540.96] 完成 [776.4,519.64 52.92x31.36] first row [368.72,118.82 a0]
    #|40: dialog [341.882,28.169 516.237x548.005] 完成 [778.697,518.593 53.609x31.768] first row [365.708,112.553 a0.276]
    #|80: dialog [340.632,25.4 518.736x550.658] 完成 [779.562,518.199 53.869x31.922] first row [364.574,110.194 a0.757]
    #|120: dialog [340.201,24.446 519.597x551.572] 完成 [779.861,518.064 53.958x31.975] first row [364.183,109.38 a0.923]
    #|160: dialog [340.039,24.087 519.921x551.916] 完成 [779.973,518.012 53.992x31.995] first row [364.036,109.075 a0.985]
    #|200: dialog [340,24 520x552] 完成 [780,518 54x32] first row [364,109 a1]
    #|280: dialog [340,24 520x552] 完成 [780,518 54x32] first row [364,109 a1]
    #|360: dialog [340,24 520x552] 完成 [780,518 54x32] first row [364,109 a1]
    #|at rest: dialog [340,24 520x552] 完成 [780,518 54x32] first row [364,109 a1]
    #|800 tall:
    #|0: dialog [345.2,38.99 509.6x734.02] 完成 [776.4,716.17 52.92x31.36] first row [368.72,122.29 a0]
    #|40: dialog [341.882,30.381 516.237x743.579] 完成 [778.697,716.381 53.609x31.768] first row [365.708,114.766 a0.276]
    #|80: dialog [340.632,27.14 518.736x747.179] 完成 [779.562,716.46 53.869x31.922] first row [364.574,111.933 a0.757]
    #|120: dialog [340.201,26.023 519.597x748.42] 完成 [779.861,716.487 53.958x31.975] first row [364.183,110.957 a0.923]
    #|160: dialog [340.039,25.602 519.921x748.886] 完成 [779.973,716.497 53.992x31.995] first row [364.036,110.589 a0.985]
    #|200: dialog [340,25.5 520x749] 完成 [780,716.5 54x32] first row [364,110.5 a1]
    #|280: dialog [340,25.5 520x749] 完成 [780,716.5 54x32] first row [364,110.5 a1]
    #|360: dialog [340,25.5 520x749] 完成 [780,716.5 54x32] first row [364,110.5 a1]
    #|at rest: dialog [340,25.5 520x749] 完成 [780,716.5 54x32] first row [364,110.5 a1]
    #|1000 tall:
    #|0: dialog [345.2,54.71 509.6x902.58] 完成 [776.4,900.45 52.92x31.36] first row [368.72,138.01 a0]
    #|40: dialog [341.882,45.004 516.237x914.335] 完成 [778.697,901.758 53.609x31.768] first row [365.708,129.389 a0.276]
    #|80: dialog [340.632,41.349 518.736x918.761] 完成 [779.562,902.251 53.869x31.922] first row [364.574,126.142 a0.757]
    #|120: dialog [340.201,40.089 519.597x920.286] 完成 [779.861,902.421 53.958x31.975] first row [364.183,125.023 a0.923]
    #|160: dialog [340.039,39.615 519.921x920.86] 完成 [779.973,902.484 53.992x31.995] first row [364.036,124.603 a0.985]
    #|200: dialog [340,39.5 520x921] 完成 [780,902.5 54x32] first row [364,124.5 a1]
    #|280: dialog [340,39.5 520x921] 完成 [780,902.5 54x32] first row [364,124.5 a1]
    #|360: dialog [340,39.5 520x921] 完成 [780,902.5 54x32] first row [364,124.5 a1]
    #|at rest: dialog [340,39.5 520x921] 完成 [780,902.5 54x32] first row [364,124.5 a1]

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
