// A panel of the presenters' opened by nothing (@sf.panel_nodes `from` Unanchored), a dialog in the middle of the
// window, on 中屏 and 大屏: as it was when the old contract was measured on main beside it (a4c845604).

///|
/// Where what a centred panel shows is: its dialog, its title, what it says, its words, its button(s), its close
/// button, the focus.
fn centred_said(t : @ui.Tester) -> String {
  let r = fn(role : @ui.Role, label : String) { t.query(role, label~).map(fn(s) { tenth4(s.rect) }) }
  let w = fn(s : String) { t.words().filter(fn(x) { x.0 == s }).map(fn(x) { tenth4((x.1, x.2, x.3, x.4)) }) }
  "dialog \{@ui.some_text(t.query(Dialog).map(fn(s) { (s.label, tenth4(s.rect)) }).map(fn(d) { "(\{d.0}, \{@ui.rect_text(d.1)})" }))} title \{@ui.list_text(w("面板").map(@ui.rect_text))} says \{@ui.list_text(w("说明的话").map(@ui.rect_text))} words \{@ui.list_text(w("面板里的话，长一些，好看它怎么折行").map(@ui.rect_text))} ok \{@ui.some_text(r(Button, "好的").map(@ui.rect_text))} close \{@ui.some_text(r(Button, "关闭").map(@ui.rect_text))} focus \{@ui.some_text(t.focused().map(fn(s) { "\{s.role} \{s.label}" }))}"
}

///|
test "panel centred, 大屏 keyboard and mouse: plain, with what it says, a foot of its own, wide, untitled, a share of the window tall in a tall window and a short one: where it is and what it shows, drawn by the window's tree" {
  let out = []
  let drawn = []
  for kind in ["plain", "says", "foot", "wide", "untitled", "tall 800", "tall 500"] {
    let h = if kind == "tall 500" { 500.0 } else { 800.0 }
    let t = menu_tester(1280.0, h, 0)
    let foot = fn(v : @view.View, close : () -> Unit) { @sf.button_node(v, fn() { "好的" }, close, tone=Primary) |> ignore }
    match kind {
      "plain" => @sf.panel_nodes("面板", panel_test_body([]), from=Unanchored)
      "says" => @sf.panel_nodes("面板", panel_test_body([]), from=Unanchored, description="说明的话")
      "foot" => @sf.panel_nodes("面板", fits_words_body(@signals.signal("面板里的话，长一些，好看它怎么折行")), from=Unanchored, foot~)
      "wide" => @sf.panel_nodes("面板", panel_test_body([]), from=Unanchored, wide=true)
      "untitled" => @sf.panel_nodes("", panel_test_body([]), from=Unanchored)
      _ => @sf.panel_nodes("面板", panel_column_body(@signals.signal(40)), from=Unanchored, tall=0.5, foot~)
    }
    t.run_for(@ui.move_most_ms)
    let said = centred_said(t)
    let rows = t.words().filter(fn(x) { x.0 == "第0行" }).map(fn(x) { tenth4((x.1, x.2, x.3, x.4)) })
    out.push("\{kind}: \{said} row0 \{@ui.list_text(rows.map(@ui.rect_text))}")
    // (said a dialog titled as it is: an untitled one says no label of its own, read out by what it holds)
    drawn.push(t.query(Dialog).map(fn(_) { tree_said(Dialog, if kind == "untitled" { "" } else { "面板" }) is Some(_) }))
  }
  debug_inspect(out, content=(
    #|[
    #|  "plain: dialog Some((面板, (380, 314.5, 520, 171))) title [(404, 340.5, 44, 30)] says [] words [(404, 389.5, 472, 22)] ok Some((406, 427.5, 468, 32)) close Some((842, 340.5, 32, 32)) focus None row0 []",
    #|  "says: dialog Some((面板, (380, 301.5, 520, 197))) title [(404, 327.5, 44, 30)] says [(404, 364.5, 472, 20)] words [(404, 402.5, 472, 22)] ok Some((406, 440.5, 468, 32)) close Some((842, 327.5, 32, 32)) focus None row0 []",
    #|  "foot: dialog Some((面板, (380, 310.5, 520, 179))) title [(404, 336.5, 44, 30)] says [] words [(404, 385.5, 472, 22)] ok Some((820, 431.5, 54, 32)) close Some((842, 336.5, 32, 32)) focus None row0 []",
    #|  "wide: dialog Some((面板, (320, 314.5, 640, 171))) title [(344, 340.5, 44, 30)] says [] words [(344, 389.5, 592, 22)] ok Some((346, 427.5, 588, 32)) close Some((902, 340.5, 32, 32)) focus None row0 []",
    #|  "untitled: dialog Some((关闭 面板里的话，长一些，好看它怎么折行 好的, (380, 323, 520, 154))) title [] says [] words [(404, 381, 472, 22)] ok Some((406, 419, 468, 32)) close Some((842, 349, 32, 32)) focus None row0 []",
    #|  "tall 800: dialog Some((面板, (380, 169.5, 520, 461))) title [(404, 195.5, 44, 30)] says [] words [] ok Some((820, 572.5, 54, 32)) close Some((842, 195.5, 32, 32)) focus None row0 [(404, 244.5, 472, 22)]",
    #|  "tall 500: dialog Some((面板, (380, 94.5, 520, 311))) title [(404, 120.5, 44, 30)] says [] words [] ok Some((820, 347.5, 54, 32)) close Some((842, 120.5, 32, 32)) focus None row0 [(404, 169.5, 472, 22)]",
    #|]

  ))
  assert_eq(drawn, [Some(true), Some(true), Some(true), Some(true), Some(true), Some(true), Some(true)])
}

///|
test "panel centred, 大屏 keyboard and mouse: closed by its close button, by Escape, by a press outside it, by its own button: presenting no more, its gone told, the focus back where it was" {
  let out = []
  for how in ["close", "escape", "outside", "own", "untitled close pressed"] {
    let t = menu_tester(1280.0, 800.0, 0)
    let gone = Ref(0)
    let said : Array[String] = []
    @sf.panel_nodes(if how == "untitled close pressed" { "" } else { "面板" }, panel_test_body(said), from=Unanchored, gone=fn() { gone.val = gone.val + 1 })
    t.run_for(@ui.move_most_ms)
    match how {
      "close" => t.click(Button, label="关闭")
      // (pressed where it is drawn, over the corner of what the panel holds)
      "untitled close pressed" => {
        let (x, y, w, h) = t.get(Button, label="关闭").rect
        t.tap(x + w / 2.0, y + h / 2.0)
      }
      "escape" => t.key(@ui.key_escape)
      "outside" => t.tap(100.0, 700.0)
      _ => t.click(Button, label="好的")
    }
    // (the frame it is closed in, and midway through its way out)
    let at_close = t.focused().map(fn(s) { "\{s.role} \{s.label}" })
    t.run_for(@motion.pop_out_ms / 2.0)
    let midway = t.focused().map(fn(s) { "\{s.role} \{s.label}" })
    t.run_for(@ui.move_most_ms)
    out.push("\{how}: focus closed \{@ui.some_text(at_close)} midway \{@ui.some_text(midway)} then presenting \{@sf.presenting()} gone \{gone.val} said \{@ui.list_text(said)} focus \{@ui.some_text(t.focused().map(fn(s) { "\{s.role} \{s.label}" }))}")
  }
  debug_inspect(out, content=(
    #|[
    #|  "close: focus closed Some(TextField 发消息) midway Some(TextField 发消息) then presenting false gone 1 said [] focus Some(TextField 发消息)",
    #|  "escape: focus closed Some(TextField 发消息) midway Some(TextField 发消息) then presenting false gone 1 said [] focus Some(TextField 发消息)",
    #|  "outside: focus closed Some(TextField 发消息) midway Some(TextField 发消息) then presenting false gone 1 said [] focus Some(TextField 发消息)",
    #|  "own: focus closed Some(TextField 发消息) midway Some(TextField 发消息) then presenting false gone 0 said [ok] focus Some(TextField 发消息)",
    #|  "untitled close pressed: focus closed Some(TextField 发消息) midway Some(TextField 发消息) then presenting false gone 1 said [] focus Some(TextField 发消息)",
    #|]

  ))
}

///|
test "panel centred, 大屏 keyboard and mouse: untitled saying something; what it holds there, then nothing, a foot of its own under it; words at its foot on a panel's words' line" {
  let out = []
  let w = fn(t : @ui.Tester, s : String) { t.words().filter(fn(x) { x.0 == s }).map(fn(x) { tenth4((x.1, x.2, x.3, x.4)) }) }
  let dialog = fn(t : @ui.Tester) { t.query(Dialog).map(fn(s) { (s.label, tenth4(s.rect)) }) }
  // (untitled, saying something)
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("", panel_test_body([]), from=Unanchored, description="说明的话")
  t.run_for(@ui.move_most_ms)
  out.push("untitled says: \{centred_said(t)}")
  // (what it holds there, then nothing; its foot of its own words on a panel's words' line)
  let t = menu_tester(1280.0, 800.0, 0)
  let holds = @signals.signal(true)
  @sf.panel_nodes(
    "面板",
    fn(v, _) {
      v.show(fn() { holds.get() }, fn(h) {
        @sf.words_node(h, fn() { "面板里的话，长一些，好看它怎么折行" }, fn() { @sf.paragraph }) |> ignore
      })
    },
    from=Unanchored,
    foot=fn(v, close) {
      v.box(fn(b) {
        @sf.style_node(b, fn() { @sf.panel_words_in_node(b) })
        @sf.words_node(b, fn() { "脚注" }, fn() { @sf.paragraph }) |> ignore
      })
      |> ignore
      @sf.button_node(v, fn() { "好的" }, close, tone=Primary) |> ignore
    },
  )
  t.run_for(@ui.move_most_ms)
  out.push("holds: dialog \{@ui.some_text(dialog(t).map(fn(d) { "(\{d.0}, \{@ui.rect_text(d.1)})" }))} words \{@ui.list_text(w(t, "面板里的话，长一些，好看它怎么折行").map(@ui.rect_text))} foot words \{@ui.list_text(w(t, "脚注").map(@ui.rect_text))} ok \{@ui.some_text(t.query(Button, label="好的").map(fn(s) { tenth4(s.rect) }).map(@ui.rect_text))}")
  holds.set(false)
  t.run_for(@ui.move_most_ms)
  out.push("holds nothing: dialog \{@ui.some_text(dialog(t).map(fn(d) { "(\{d.0}, \{@ui.rect_text(d.1)})" }))} foot words \{@ui.list_text(w(t, "脚注").map(@ui.rect_text))} ok \{@ui.some_text(t.query(Button, label="好的").map(fn(s) { tenth4(s.rect) }).map(@ui.rect_text))}")
  debug_inspect(out, content=(
    #|[
    #|  "untitled says: dialog Some((关闭 说明的话 面板里的话，长一些，好看它怎么折行 好的, (380, 310, 520, 180))) title [] says [(404, 340, 472, 20)] words [(404, 394, 472, 22)] ok Some((406, 432, 468, 32)) close Some((842, 336, 32, 32)) focus None",
    #|  "holds: dialog Some((面板, (380, 310.5, 520, 179))) words [(404, 385.5, 472, 22)] foot words [(784, 436.5, 28, 22)] ok Some((820, 431.5, 54, 32))",
    #|  "holds nothing: dialog Some((面板, (380, 330, 520, 140))) foot words [(784, 417, 28, 22)] ok Some((820, 412, 54, 32))",
    #|]

  ))
}

///|
test "panel centred, 大屏 keyboard and mouse: untitled, what it holds reaching under its close button with a ground and a press of its own: the close button drawn under it as main has it, pressed where it is drawn closing the panel, what it holds not (on main, a4c845604, the press taken by what scrolls what it holds)" {
  let t = menu_tester(1280.0, 800.0, 0)
  let under = Ref(0)
  let gone = Ref(0)
  @sf.panel_nodes(
    "",
    fn(v, _) {
      // (in the dialog's corners, round as a row there is: the ladder's 18, 24 in from its 42)
      v.box(fn(b) {
        b
        .height(Is(Some(60.0)))
        .ground(Is(0x336699FFL))
        .radius(Is(@sf.row_corner))
        .says(Is(Some(@view.said(Button, label="底下"))))
        .presses(Is(true))
        .on_press(fn() { under.val = under.val + 1 })
        |> ignore
      })
      |> ignore
    },
    from=Unanchored,
    gone=fn() { gone.val = gone.val + 1 },
  )
  t.run_for(@ui.move_most_ms)
  let (x, y, w, h) = t.get(Button, label="关闭").rect
  // (in the order drawn: the last of what the close button draws within its box (its mark, whatever ground it has),
  // and the ground of what the panel holds under it)
  let order = t.drawn_order()
  let under_at = order.search_by(fn(d) { d.0 == 0 && d.3 > 300.0 && (d.4 - 60.0).abs() < 0.01 })
  let mut close_at : Int? = None
  for i, d in order {
    if d.1 >= x - 0.01 && d.2 >= y - 0.01 && d.1 + d.3 <= x + w + 0.01 && d.2 + d.4 <= y + h + 0.01 {
      close_at = Some(i)
    }
  }
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  // (both drawn: whether the close button is drawn after what is under it)
  let after = match (under_at, close_at) {
    (Some(u), Some(c)) => Some(c > u)
    _ => None
  }
  // (drawn before it, under it, as on main (646 and 647); the press there closing it, on main closing nothing: Some(false),
  // true, 0, 0)
  assert_eq((after, @sf.presenting(), gone.val, under.val), (Some(false), false, 1, 0))
}

///|
test "panel centred, 大屏 keyboard and mouse: untitled, Tab pressed twice: read out as focused, its button each time" {
  let t = menu_tester(1280.0, 800.0, 0)
  @sf.panel_nodes("", panel_test_body([]), from=Unanchored)
  t.run_for(@ui.move_most_ms)
  let out = []
  for _ in 0..<2 {
    t.key(@ui.key_tab)
    t.run_for(@ui.move_most_ms)
    out.push(t.focused().map(fn(s) { "\{s.role} \{s.label}" }))
  }
  // (on its button, its one stop (its close button none: tab_stop), and there it stays)
  assert_eq(out, [Some("Button 好的"), Some("Button 好的")])
}
