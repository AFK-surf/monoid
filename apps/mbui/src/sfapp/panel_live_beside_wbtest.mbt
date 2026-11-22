// A panel beside what opened it whose title is as it is now (@sf.panel_nodes `live`): its head there or not as its title
// is (none, some, none again), the focus as it opens and where it stays, what was typed kept, beside what opened it
// under it and flipped over it, held short of what it holds by the window; as it was when the old contract was
// measured on main beside it.

///|
/// Whether a dialog titled `label` (a live one beside what opened it: its presented title, as it was opened) is drawn
/// by the window's tree.
fn live_beside_drawn() -> Bool {
  tree_said(Dialog, "") is Some(_)
}

///|
test "panel live beside what opened it, 大屏 keyboard and mouse: the focus as it opens (focus, not focus, its field given it), its title none, some, none again, typed into between: the focus kept where it was, the field the same and what was typed kept; drawn by the window's tree" {
  let out = []
  let drawn = []
  for how in ["focus", "not focus", "field"] {
    let said : Array[String] = []
    let t = menu_tester(1280.0, 800.0, 0)
    let title = @signals.signal("")
    let pf = @ui.Field::new()
    let body = fn(v : @view.View, close : () -> Unit) {
      if how == "field" {
        // (its field given the focus as it opens where it is not a sheet: panel_search_at_hand_node)
        @sf.panel_search_at_hand_node(@sf.input_node(v, pf, placeholder="填一下", label="填一下"))
      }
      panel_test_body(said)(v, close)
    }
    let live = fn() { (title.get(), "", "") }
    match how {
      "not focus" => @sf.panel_nodes("", body, from=At(600.0, 300.0, 0.0, 0.0), focus=false, live~)
      _ => @sf.panel_nodes("", body, from=At(600.0, 300.0, 0.0, 0.0), live~)
    }
    t.run_for(@ui.move_most_ms)
    let field_id = fn() { t.query(TextField, label="填一下").map(fn(s) { s.id }) }
    let first_field = field_id()
    let at = fn() {
      let d = t.query(Dialog).map(fn(s) { (s.label, tenth4(s.rect)) })
      "\{panel_focus_said(t)} dialog \{@ui.some_text(d.map(fn(d) { "(\{d.0}, \{@ui.rect_text(d.1)})" }))} field same \{field_id() == first_field} text \{pf.text()}"
    }
    let open = at()
    t.type_text("甲")
    live_frames(t, 30)
    title.set("面板")
    live_frames(t, 30)
    let titled = at()
    t.type_text("乙")
    live_frames(t, 30)
    title.set("")
    live_frames(t, 30)
    let again = at()
    drawn.push(live_beside_drawn())
    out.push("\{how}: open {\{open}} titled {\{titled}} again {\{again}}")
  }
  debug_inspect(out, content=(
    #|[
    #|  "focus: open {focused None ime (false, , 0, 0) dialog Some((面板里的话，长一些，好看它怎么折行 好的, (600, 306, 296, 68))) field same true text } titled {focused None ime (false, , 0, 0) dialog Some((面板 面板里的话，长一些，好看它怎么折行 好的, (600, 306, 296, 98))) field same true text } again {focused None ime (false, , 0, 0) dialog Some((面板里的话，长一些，好看它怎么折行 好的, (600, 306, 296, 68))) field same true text }",
    #|  "not focus: open {focused Some(TextField 发消息) ime (true, , 0, 0) dialog Some((面板里的话，长一些，好看它怎么折行 好的, (600, 306, 296, 68))) field same true text } titled {focused Some(TextField 发消息) ime (true, 甲, 1, 1) dialog Some((面板 面板里的话，长一些，好看它怎么折行 好的, (600, 306, 296, 98))) field same true text } again {focused Some(TextField 发消息) ime (true, 甲乙, 2, 2) dialog Some((面板里的话，长一些，好看它怎么折行 好的, (600, 306, 296, 68))) field same true text }",
    #|  "field: open {focused Some(TextField 填一下) ime (true, , 0, 0) dialog Some((填一下 面板里的话，长一些，好看它怎么折行 好的, (600, 306, 296, 104))) field same true text } titled {focused Some(TextField 填一下) ime (true, 甲, 1, 1) dialog Some((面板 填一下 面板里的话，长一些，好看它怎么折行 好的, (600, 306, 296, 134))) field same true text 甲} again {focused Some(TextField 填一下) ime (true, 甲乙, 2, 2) dialog Some((填一下 面板里的话，长一些，好看它怎么折行 好的, (600, 306, 296, 104))) field same true text 甲乙}",
    #|]

  ))
  assert_eq(drawn, [true, true, true])
}

///|
test "panel live beside what opened it, 大屏 keyboard and mouse: opened under what opened it, opened flipped over it for want of room below (two panels, each where it was put), its title none, some, none again (frames as the display draws them): where it is, its title and words, " {
  let out = []
  for y in [100.0, 780.0] {
    let t = menu_tester(1280.0, 800.0, 0)
    let title = @signals.signal("")
    @sf.panel_nodes(
      "",
      panel_test_body([]),
      from=At(600.0, y, 0.0, 0.0),
      live=fn() { (title.get(), "", "") },
    )
    t.run_for(@ui.move_most_ms)
    let w = fn(s : String) { t.words().filter(fn(x) { x.0 == s }).map(fn(x) { tenth4((x.1, x.2, x.3, x.4)) }) }
    for s in ["", "面板", ""] {
      title.set(s)
      live_frames(t, 30)
      let d = t.query(Dialog).map(fn(s) { (s.label, tenth4(s.rect)) })
      let line = "\{y} \{s}: dialog \{@ui.some_text(d.map(fn(d) { "(\{d.0}, \{@ui.rect_text(d.1)})" }))} title \{@ui.list_text(w("面板").map(@ui.rect_text))} words \{@ui.list_text(w("面板里的话，长一些，好看它怎么折行").map(@ui.rect_text))} button \{@ui.some_text(t.query(Button, label="好的").map(fn(s) { tenth4(s.rect) }).map(@ui.rect_text))}"
      out.push(line)
    }
  }
  debug_inspect(out, content=(
    #|[
    #|  "100 : dialog Some((面板里的话，长一些，好看它怎么折行 好的, (600, 106, 296, 68))) title [] words [(606, 112, 284, 22)] button Some((608, 134, 280, 32))",
    #|  "100 面板: dialog Some((面板 面板里的话，长一些，好看它怎么折行 好的, (600, 106, 296, 98))) title [(622, 118, 252, 20)] words [(606, 142, 284, 22)] button Some((608, 164, 280, 32))",
    #|  "100 : dialog Some((面板里的话，长一些，好看它怎么折行 好的, (600, 106, 296, 68))) title [] words [(606, 112, 284, 22)] button Some((608, 134, 280, 32))",
    #|  "780 : dialog Some((面板里的话，长一些，好看它怎么折行 好的, (600, 706, 296, 68))) title [] words [(606, 712, 284, 22)] button Some((608, 734, 280, 32))",
    #|  "780 面板: dialog Some((面板 面板里的话，长一些，好看它怎么折行 好的, (600, 676, 296, 98))) title [(622, 688, 252, 20)] words [(606, 712, 284, 22)] button Some((608, 734, 280, 32))",
    #|  "780 : dialog Some((面板里的话，长一些，好看它怎么折行 好的, (600, 706, 296, 68))) title [] words [(606, 712, 284, 22)] button Some((608, 734, 280, 32))",
    #|]

  ))
}

///|
test "panel live beside what opened it, 大屏 keyboard and mouse: held short of what it holds by the window, scrolled, its title none, some, none again (frames as the display draws them): where its rows and button are, what the wheel scrolls after" {
  let said : Array[String] = []
  let t = menu_tester(1280.0, 500.0, 0)
  let title = @signals.signal("")
  @sf.panel_nodes(
    "",
    fn(v, close) {
      for i in 0..<40 {
        @sf.words_node(v, fn() { "第\{i}行" }, fn() { @sf.paragraph }) |> ignore
      }
      @sf.button_node(v, fn() { "好的" }, fn() {
        said.push("ok")
        close()
      }, tone=Primary)
      |> ignore
    },
    from=At(600.0, 100.0, 0.0, 0.0),
    live=fn() { (title.get(), "", "") },
  )
  t.run_for(@ui.move_most_ms)
  let w = fn(s : String) { t.words().filter(fn(x) { x.0 == s }).map(fn(x) { tenth4((x.1, x.2, x.3, x.4)) }) }
  let at = fn() {
    "dialog \{@ui.some_text(t.query(Dialog).map(fn(s) { tenth4(s.rect) }).map(@ui.rect_text))} title \{@ui.list_text(w("面板").map(@ui.rect_text))} row0 \{@ui.list_text(w("第0行").map(@ui.rect_text))} row10 \{@ui.list_text(w("第10行").map(@ui.rect_text))} button \{@ui.some_text(t.query(Button, label="好的").map(fn(s) { tenth4(s.rect) }).map(@ui.rect_text))}"
  }
  let (dx, dy, dw, dh) = t.get(Dialog).rect
  t.wheel(dx + dw / 2.0, dy + dh / 2.0, 120.0)
  t.run_for(@ui.move_most_ms)
  let out = ["scrolled \{at()}"]
  for s in ["面板", ""] {
    title.set(s)
    live_frames(t, 30)
    out.push("\{s}: \{at()}")
    let (dx, dy, dw, dh) = t.get(Dialog).rect
    t.wheel(dx + dw / 2.0, dy + dh / 2.0, 120.0)
    t.run_for(@ui.move_most_ms)
    out.push("\{s} wheel: \{at()}")
  }
  debug_inspect(out, content=(
    #|[
    #|  "scrolled dialog Some((600, 8, 296, 484)) title [] row0 [(606, -106, 284, 22)] row10 [(606, 114, 284, 22)] button Some((606, 774, 284, 32))",
    #|  "面板: dialog Some((600, 8, 296, 484)) title [(622, 20, 252, 20)] row0 [(606, -76, 284, 22)] row10 [(606, 144, 284, 22)] button Some((606, 804, 284, 32))",
    #|  "面板 wheel: dialog Some((600, 8, 296, 484)) title [(622, 20, 252, 20)] row0 [(606, -196, 284, 22)] row10 [(606, 24, 284, 22)] button Some((606, 684, 284, 32))",
    #|  ": dialog Some((600, 8, 296, 484)) title [] row0 [(606, -226, 284, 22)] row10 [(606, -6, 284, 22)] button Some((606, 654, 284, 32))",
    #|  " wheel: dialog Some((600, 8, 296, 484)) title [] row0 [(606, -346, 284, 22)] row10 [(606, -126, 284, 22)] button Some((606, 534, 284, 32))",
    #|]

  ))
  // (scrolled to its end with its title shown again: its last row seen whole (its glyphs drawn within the edges they
  // are cut to), its button in the window; pressed at its middle, said and closed)
  title.set("面板")
  live_frames(t, 30)
  let (dx, dy, dw, dh) = t.get(Dialog).rect
  for _ in 0..<10 {
    t.wheel(dx + dw / 2.0, dy + dh / 2.0, 400.0)
    t.run_for(@ui.move_most_ms)
  }
  let button = t.query(Button, label="好的").map(fn(s) { tenth4(s.rect) })
  let seen = rows_seen(t)
  let bottom = "seen (\{@ui.some_text(seen.0)}, \{@ui.some_text(seen.1)}) title \{@ui.list_text(w("面板").map(@ui.rect_text))} button \{@ui.some_text(button.map(@ui.rect_text))} in window \{@ui.some_text(button.map(fn(b) { b.1 >= 0.0 && b.1 + b.3 <= 500.0 }))}"
  // (a press at its middle, where the hit test finds it: not said to it)
  let (bx, by, bw, bh) = t.get(Button, label="好的").rect
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq("said \{@ui.list_text(said)} presenting \{@sf.presenting()}", "said [ok] presenting false")
  inspect(bottom, content=(
    #|seen (Some(第20行), Some(第39行)) title [(622, 20, 252, 20)] button Some((606, 454, 284, 32)) in window Some(true)

  ))
}
