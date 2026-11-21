// Rows together in a panel's body (a card of the panel's) as nodes (group_node), two rows that turn something on or
// off, the last of what a dialog holds (panel_card_last_node). Check the row and switch layout across panel types.

///|
/// What a panel holding rows together on a card draws at rest, every rectangle and every word (each where and how big,
/// to a thousandth of a point), in order, on a window `at`, opened by
/// its 打开 (`pressed`: a sheet a press opened, a small panel beside it) or by nothing (a sheet, a dialog in the middle
/// of the window). Closed after, gone.
fn group_panel_drawn(at : (Int, Double, Double), pressed : Bool) -> Array[String] raise {
  let open = fn(from : Anchor) {
    let from = if pressed { from } else { Unanchored }
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
    #|rect 40,40 310x36 3907312895
    #|rect 0,0 390x844 71
    #|rect 176,559 38x5 841819172
    #|rect 16,652 358x168 606546701
    #|rect 284,684 64x28 2021161011
    #|rect 286,686 40x24 4294967295
    #|rect 284,760 64x28 3428463871
    #|rect 306,762 40x24 4294967295
    #|words 一组@24,576 32x24 a1
    #|words 打开@180,47 30x22 a1
    #|words 它说的话@24,610 342x18 a1
    #|words 第一个开关@40,687 232x22 a1
    #|words 第二个开关@40,763 232x22 a1
    #|sheet opened by a press:
    #|rect 40,40 310x36 3907312895
    #|rect 0,0 390x844 71
    #|rect 176,569 38x5 841819172
    #|rect 16,652 358x168 606546701
    #|rect 284,684 64x28 2021161011
    #|rect 286,686 40x24 4294967295
    #|rect 284,760 64x28 3428463871
    #|rect 306,762 40x24 4294967295
    #|words 一组@24,586 32x24 a1
    #|words 打开@180,47 30x22 a1
    #|words 它说的话@24,620 342x18 a1
    #|words 第一个开关@40,687 232x22 a1
    #|words 第二个开关@40,763 232x22 a1
    #|sheet opened by a press, with a mouse:
    #|rect 40,40 310x36 3907312895
    #|rect 0,0 390x844 71
    #|rect 176,585 38x5 841819172
    #|rect 16,668 358x152 606546701
    #|rect 312,699 36x22 2021161011
    #|rect 314,701 22.5x18 4294967295
    #|rect 312,767 36x22 3428463871
    #|rect 323.5,769 22.5x18 4294967295
    #|words 一组@24,602 32x24 a1
    #|words 打开@182,48 26x20 a1
    #|words 它说的话@24,636 342x18 a1
    #|words 第一个开关@40,699 260x22 a1
    #|words 第二个开关@40,767 260x22 a1
    #|small panel:
    #|rect 40,40 720x36 3907312895
    #|rect 40,82 296x228 4294967295
    #|rect 46,150 284x126 4294967295
    #|rect 270,173 36x22 2021161011
    #|rect 272,175 22.5x18 4294967295
    #|rect 270,231 36x22 3428463871
    #|rect 281.5,233 22.5x18 4294967295
    #|rect 40,82 296x228 0
    #|words 一组@62,94 252x20 a1
    #|words 打开@387,48 26x20 a1
    #|words 它说的话@62,118 252x18 a1
    #|words 第一个开关@68,174 186x20 a1
    #|words 第二个开关@68,232 186x20 a1
    #|dialog:
    #|rect 40,40 720x36 3907312895
    #|rect 0,0 800x600 320215859
    #|rect 140,166.5 520x267 4294967295
    #|rect 156,289.5 488x128 606546701
    #|rect 582,314.5 36x22 2021161011
    #|rect 584,316.5 22.5x18 4294967295
    #|rect 582,370.5 36x22 3428463871
    #|rect 593.5,372.5 22.5x18 4294967295
    #|rect 140,166.5 520x267 0
    #|words 打开@387,48 26x20 a1
    #|words 一组@164,192.5 44x30 a1
    #|words 它说的话@164,241.5 472x18 a1
    #|words 第一个开关@180,315.5 386x20 a1
    #|words 第二个开关@180,371.5 386x20 a1


  ))
}
