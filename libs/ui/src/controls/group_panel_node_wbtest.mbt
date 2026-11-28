// Rows together in a panel's body (a card of the panel's) as nodes (group_node), two rows that turn something on or
// off, the last of what a dialog holds (panel_card_last_node). Check the row and switch layout across panel types.

///|
/// What a panel holding rows together on a card draws at rest, every rectangle and every word (each where and how big,
/// to a thousandth of a point), in order, on a window `at`, opened by
/// its 打开 (`pressed`: a sheet a press opened, a small panel beside it) or by nothing (a sheet, a dialog in the middle
/// of the window). Closed after, gone.
fn group_panel_drawn(at : (Int, Double, Double), pressed : Bool) -> Array[String] raise {
  let open = fn(from : Anchor) {
    let from = if pressed {
      if layout(at.1) is Small { Anchor::At(40.0, at.2 - 80.0, 60.0, 32.0) } else { from }
    } else {
      Unanchored
    }
    panel_nodes("一组", from~, fn(v, _) {
      v.box(fn(b) {
        style_node(b, fn() { panel_words_in_node(b) })
        words_node(b, fn() { "它说的话" }, fn() { secondary }) |> ignore
      })
      |> ignore
      v.box(fn(b) {
        style_node(b, fn() { group_panel_block.then(panel_card_last_node(b)) })
        group_node(b, fn(g) {
          switch_row_node(g, fn() { "第一个开关" }, fn() { false }, fn(_) {  })
          switch_row_node(g, fn() { "第二个开关" }, fn() { true }, fn(_) {  })
        })
      })
      |> ignore
    })
  }
  presenters_reset()
  let (platform, w, h) = at
  let t = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=presented_tree(presenting_view(open)),
    w~,
    h~,
    platform~,
  )
  t.check_looks(false)
  t.draw()
  t.tap_text("打开")
  t.run_for(@ui.move_most_ms)
  t.leave()
  t.draw()
  let k = fn(v : Double) { (v * 1000.0).round() / 1000.0 }
  let drawn = t.drawn_rects().map(fn(r) { "rect \{k(r.0)},\{k(r.1)} \{k(r.2)}x\{k(r.3)} \{r.4}" })
  let words = t.words().map(fn(w) { "words \{w.0}@\{k(w.1)},\{k(w.2)} \{k(w.3)}x\{k(w.4)} a\{w.5}" })
  // (the old view's words and the tree's are told in their own orders)
  words.sort()
  close_all_presented()
  t.run_for(@ui.move_most_ms)
  assert_false(presented_drawn(), msg="closed")
  drawn + words
}

///|
/// The block the rows stand in: 14 over it (composer_ref's ref_block).
// kept across runs: a value (no field of it changes)
let group_panel_block : @ui.Style = @ui.css("w=Full gap=S2 pt=S3_5")

///|
test "rows together in a panel's body as nodes: a sheet opened by nothing and by a press, with a finger and with a mouse, a small panel beside what opened it, a dialog in the middle of the window" {
  let seen : Array[String] = []
  for screen in [
    ("sheet opened by nothing", phone, false),
    ("sheet opened by a press", phone, true),
    ("sheet opened by a press, with a mouse", (0, 390.0, 844.0), true),
    ("small panel", (0, 800.0, 600.0), true),
    ("dialog", (0, 800.0, 600.0), false),
  ] {
    let (about, at, pressed) = screen
    seen.push("\{about}:")
    seen.append(group_panel_drawn(at, pressed))
  }
  inspect(seen.join("\n"), content=(
    #|sheet opened by nothing:
    #|rect 40,40 310x32 3907312895
    #|rect 0,0 390x844 71
    #|rect 166,546 58x4 606546752
    #|rect 22,654 346x168 606546701
    #|rect 279,686 63x28 2021161011
    #|rect 281,688 37x24 4294967295
    #|rect 279,762 63x28 3428463871
    #|rect 303,764 37x24 4294967295
    #|words 打开@180,45 30x22 a1
    #|words 一组@178,567 34x22 a1
    #|words 它说的话@30,612 330x18 a1
    #|words 第一个开关@46,689 221x22 a1
    #|words 第二个开关@46,765 221x22 a1
    #|sheet opened by a press:
    #|rect 40,40 310x32 3907312895
    #|rect 0,0 390x844 71
    #|rect 166,556 58x4 606546752
    #|rect 22,654 346x168 606546701
    #|rect 279,686 63x28 2021161011
    #|rect 281,688 37x24 4294967295
    #|rect 279,762 63x28 3428463871
    #|rect 303,764 37x24 4294967295
    #|words 打开@180,45 30x22 a1
    #|words 一组@178,577 34x22 a1
    #|words 它说的话@30,622 330x18 a1
    #|words 第一个开关@46,689 221x22 a1
    #|words 第二个开关@46,765 221x22 a1
    #|sheet opened by a press, with a mouse:
    #|rect 40,40 310x32 3907312895
    #|rect 0,0 390x844 71
    #|rect 166,572 58x4 606546752
    #|rect 22,670 346x152 606546701
    #|rect 279,698 63x28 2021161011
    #|rect 281,700 37x24 4294967295
    #|rect 279,766 63x28 3428463871
    #|rect 303,768 37x24 4294967295
    #|words 打开@182,46 26x20 a1
    #|words 一组@178,593 34x22 a1
    #|words 它说的话@30,638 330x18 a1
    #|words 第一个开关@46,701 221x22 a1
    #|words 第二个开关@46,769 221x22 a1
    #|small panel:
    #|rect 40,40 720x32 3907312895
    #|rect 46,146 284x126 4294967295
    #|rect 256,169 50x22 2021161011
    #|rect 258,171 29.365x18 4294967295
    #|rect 256,227 50x22 3428463871
    #|rect 274.635,229 29.365x18 4294967295
    #|words 一组@62,90 252x20 a1
    #|words 打开@387,46 26x20 a1
    #|words 它说的话@62,114 252x18 a1
    #|words 第一个开关@68,170 172x20 a1
    #|words 第二个开关@68,228 172x20 a1
    #|dialog:
    #|rect 40,40 720x32 3907312895
    #|rect 0,0 800x600 320215859
    #|rect 156,291 488x128 606546701
    #|rect 568,316 50x22 2021161011
    #|rect 570,318 29.365x18 4294967295
    #|rect 568,372 50x22 3428463871
    #|rect 586.635,374 29.365x18 4294967295
    #|words 打开@387,46 26x20 a1
    #|words 一组@164,192 34x22 a1
    #|words 它说的话@164,243 472x18 a1
    #|words 第一个开关@180,317 372x20 a1
    #|words 第二个开关@180,373 372x20 a1







  ))
}
