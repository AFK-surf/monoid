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
    #|0: dialog [345.2,35.52 509.6x540.96] 完成 [780.32,523.56 52.92x31.36] first row [368.72,121.76 a0]
    #|40: dialog [341.882,28.169 516.237x548.005] 完成 [782.668,522.564 53.609x31.768] first row [365.708,115.532 a0.276]
    #|80: dialog [340.632,25.4 518.736x550.658] 完成 [783.553,522.19 53.869x31.922] first row [364.574,113.186 a0.757]
    #|120: dialog [340.201,24.446 519.597x551.572] 完成 [783.857,522.06 53.958x31.975] first row [364.183,112.378 a0.923]
    #|160: dialog [340.039,24.087 519.921x551.916] 完成 [783.972,522.012 53.992x31.995] first row [364.036,112.074 a0.985]
    #|200: dialog [340,24 520x552] 完成 [784,522 54x32] first row [364,112 a1]
    #|280: dialog [340,24 520x552] 完成 [784,522 54x32] first row [364,112 a1]
    #|360: dialog [340,24 520x552] 完成 [784,522 54x32] first row [364,112 a1]
    #|at rest: dialog [340,24 520x552] 完成 [784,522 54x32] first row [364,112 a1]
    #|800 tall:
    #|0: dialog [345.2,39.48 509.6x733.04] 完成 [780.32,719.6 52.92x31.36] first row [368.72,125.72 a0]
    #|40: dialog [341.882,30.878 516.237x742.587] 完成 [782.668,719.855 53.609x31.768] first row [365.708,118.241 a0.276]
    #|80: dialog [340.632,27.639 518.736x746.182] 完成 [783.553,719.951 53.869x31.922] first row [364.574,115.425 a0.757]
    #|120: dialog [340.201,26.522 519.597x747.42] 完成 [783.857,719.985 53.958x31.975] first row [364.183,114.454 a0.923]
    #|160: dialog [340.039,26.102 519.921x747.886] 完成 [783.972,719.997 53.992x31.995] first row [364.036,114.089 a0.985]
    #|200: dialog [340,26 520x748] 完成 [784,720 54x32] first row [364,114 a1]
    #|280: dialog [340,26 520x748] 完成 [784,720 54x32] first row [364,114 a1]
    #|360: dialog [340,26 520x748] 完成 [784,720 54x32] first row [364,114 a1]
    #|at rest: dialog [340,26 520x748] 完成 [784,720 54x32] first row [364,114 a1]
    #|1000 tall:
    #|0: dialog [345.2,55.2 509.6x901.6] 完成 [780.32,903.88 52.92x31.36] first row [368.72,141.44 a0]
    #|40: dialog [341.882,45.5 516.237x913.342] 完成 [782.668,905.233 53.609x31.768] first row [365.708,132.863 a0.276]
    #|80: dialog [340.632,41.848 518.736x917.763] 完成 [783.553,905.742 53.869x31.922] first row [364.574,129.634 a0.757]
    #|120: dialog [340.201,40.589 519.597x919.287] 完成 [783.857,905.918 53.958x31.975] first row [364.183,128.521 a0.923]
    #|160: dialog [340.039,40.115 519.921x919.86] 完成 [783.972,905.984 53.992x31.995] first row [364.036,128.102 a0.985]
    #|200: dialog [340,40 520x920] 完成 [784,906 54x32] first row [364,128 a1]
    #|280: dialog [340,40 520x920] 完成 [784,906 54x32] first row [364,128 a1]
    #|360: dialog [340,40 520x920] 完成 [784,906 54x32] first row [364,128 a1]
    #|at rest: dialog [340,40 520x920] 完成 [784,906 54x32] first row [364,128 a1]


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
