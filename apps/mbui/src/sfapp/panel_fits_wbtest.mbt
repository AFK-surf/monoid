// A panel of the presenters' as wide as what it holds (@sf.panel_nodes' `fits`) on 中屏 and 大屏: as it was when the old
// contract was measured on main beside it (a4c845604).

///|
/// Where what a fits panel shows is: its dialog, its title, its words, its foot's button, what is at its head's end.
fn fits_said(t : @ui.Tester, words : String) -> String {
  let r = fn(role : @ui.Role, label : String) { t.query(role, label~).map(fn(s) { tenth4(s.rect) }) }
  let w = fn(s : String) { t.words().filter(fn(x) { x.0 == s }).map(fn(x) { tenth4((x.1, x.2, x.3, x.4)) }) }
  "dialog \{@ui.some_text(r(Dialog, "面板").map(@ui.rect_text))} title \{@ui.list_text(w("面板").map(@ui.rect_text))} words \{@ui.list_text(w(words).map(@ui.rect_text))} button \{@ui.some_text(r(Button, "好的").map(@ui.rect_text))} end \{@ui.some_text(r(Button, "尾").map(@ui.rect_text))}"
}

///|
test "panel fits, 大屏 keyboard and mouse: as wide as its words as they change; its foot, a narrower most; a column of its own, the window short of it: drawn by the window's tree" {
  let out = []
  let drawn = []
  let long = "一行很长很长的话，比面板最宽的时候还要宽很多很多，好看它怎么折行和怎么定宽度"
  // (its words changing while it is open: short, long, middling, short again)
  for kind in ["plain", "foot", "narrow"] {
    let t = menu_tester(1280.0, 800.0, 0)
    let words = @signals.signal("短短的")
    let w = if kind == "narrow" { 200.0 } else { 400.0 }
    match kind {
      "foot" =>
        @sf.panel_nodes(
          "面板",
          fits_words_body(words),
          from=At(600.0, 100.0, 0.0, 0.0),
          fits=true,
          w~,
          foot=fn(v, close) { @sf.button_node(v, fn() { "好的" }, close, tone=Primary) |> ignore },
        )
      _ => @sf.panel_nodes("面板", fits_words_body(words), from=At(600.0, 100.0, 0.0, 0.0), fits=true, w~)
    }
    t.run_for(@ui.move_most_ms)
    for s in ["短短的", long, "中等长度的一句话", "短短的"] {
      words.set(s)
      t.run_for(@ui.move_most_ms)
      out.push("\{kind} \{s.length()}: \{fits_said(t, s)}")
      drawn.push(tree_said(Dialog, "面板") is Some(_))
    }
  }
  // (a column of its own in it, the window short of it)
  let t = menu_tester(1280.0, 500.0, 0)
  @sf.panel_nodes("面板", panel_column_body(@signals.signal(40)), from=At(600.0, 100.0, 0.0, 0.0), fits=true, w=400.0)
  t.run_for(@ui.move_most_ms)
  let d = t.get(Dialog, label="面板").rect
  let row0 = fn() { t.words().filter(fn(x) { x.0 == "第0行" }).map(fn(x) { tenth4((x.1, x.2, x.3, x.4)) }) }
  let before = "column: dialog \{@ui.rect_text(tenth4(d))} row0 \{@ui.list_text(row0().map(@ui.rect_text))}"
  t.wheel(d.0 + d.2 / 2.0, d.1 + 120.0, 120.0)
  t.run_for(@ui.move_most_ms)
  out.push("\{before} | wheel: \{@ui.list_text(row0().map(@ui.rect_text))}")
  drawn.push(tree_said(Dialog, "面板") is Some(_))
  assert_eq(drawn, Array::make(drawn.length(), true))
  debug_inspect(out, content=(
    #|[
    #|  "plain 3: dialog Some((600, 106, 58, 64)) title [(616, 118, 26, 20)] words [(606, 142, 46, 22)] button None end None",
    #|  "plain 38: dialog Some((600, 106, 400, 86)) title [(616, 118, 368, 20)] words [(606, 142, 388, 44)] button None end None",
    #|  "plain 8: dialog Some((600, 106, 124, 64)) title [(616, 118, 92, 20)] words [(606, 142, 112, 22)] button None end None",
    #|  "plain 3: dialog Some((600, 106, 58, 64)) title [(616, 118, 26, 20)] words [(606, 142, 46, 22)] button None end None",
    #|  "foot 3: dialog Some((600, 106, 70, 108)) title [(616, 118, 38, 20)] words [(606, 142, 58, 22)] button Some((606, 172, 58, 36)) end None",
    #|  "foot 38: dialog Some((600, 106, 400, 130)) title [(616, 118, 368, 20)] words [(606, 142, 388, 44)] button Some((936, 194, 58, 36)) end None",
    #|  "foot 8: dialog Some((600, 106, 124, 108)) title [(616, 118, 92, 20)] words [(606, 142, 112, 22)] button Some((660, 172, 58, 36)) end None",
    #|  "foot 3: dialog Some((600, 106, 70, 108)) title [(616, 118, 38, 20)] words [(606, 142, 58, 22)] button Some((606, 172, 58, 36)) end None",
    #|  "narrow 3: dialog Some((600, 106, 58, 64)) title [(616, 118, 26, 20)] words [(606, 142, 46, 22)] button None end None",
    #|  "narrow 38: dialog Some((600, 106, 200, 108)) title [(616, 118, 168, 20)] words [(606, 142, 188, 66)] button None end None",
    #|  "narrow 8: dialog Some((600, 106, 124, 64)) title [(616, 118, 92, 20)] words [(606, 142, 112, 22)] button None end None",
    #|  "narrow 3: dialog Some((600, 106, 58, 64)) title [(616, 118, 26, 20)] words [(606, 142, 46, 22)] button None end None",
    #|  "column: dialog (600, 90, 58, 402) row0 [(606, 126, 46, 22)] | wheel: [(606, 6, 46, 22)]",
    #|]
  ))
}

///|
test "panel fits, the model's (model_pop): where it is, its models and how hard it thinks, another effort picked: drawn by the window's tree" {
  let out = []
  let drawn = []
  for mode in ["newchat-model", "newchat-tall-model", "newchat-crowded-model"] {
    let t = model_pop(mode)
    let r = fn(role : @ui.Role, label : String) { t.query(role, label~).map(fn(s) { tenth4(s.rect) }) }
    out.push("\{mode}: dialog \{@ui.some_text(t.query(Dialog).map(fn(s) { tenth4(s.rect) }).map(@ui.rect_text))} opus \{@ui.some_text(r(Button, "Opus 5.5").map(@ui.rect_text))} high \{@ui.some_text(r(Radio, "高").map(@ui.rect_text))}")
    // (the row it runs on, the configuration picked exactly, wholly in view as it opens: Opus above it a model scrolled
    // past, not the one picked)
    let runs_on = if mode == "newchat-model" { "Opus 5.5 · 高" } else { "DeepSeek V4.1 Flash · DSH · 高" }
    let on = t.get(Button, label=runs_on)
    assert_true(wholly_in_view(t, on.rect), msg="\{mode}: \{runs_on} at \{Repr(on.rect)} out of view")
    drawn.push(tree_said(Dialog, t.query(Dialog).map(fn(s) { s.label }).unwrap_or("")) is Some(_))
    if mode == "newchat-crowded-model" {
      for label in ["低", "最高"] {
        t.click(Radio, label~)
        t.run_for(squeeze_opening)
        out.push("\{mode} \{label}: dialog \{@ui.some_text(t.query(Dialog).map(fn(s) { tenth4(s.rect) }).map(@ui.rect_text))} high \{@ui.some_text(r(Radio, "高").map(@ui.rect_text))}")
      }
    }
  }
  debug_inspect(out, content=(
    #|[
    #|  "newchat-model: dialog Some((650, 136, 340, 390)) opus Some((656, 172, 188, 36)) high Some((885, 246, 99, 36))",
    #|  "newchat-tall-model: dialog Some((650, 62, 520, 464)) opus Some((656, -50, 381, 36)) high Some((1078, 209, 86, 36))",
    #|  "newchat-crowded-model: dialog Some((650, 75.5, 379, 450.5)) opus Some((656, 27.5, 254, 36)) high Some((951, 185.5, 72, 36))",
    #|  "newchat-crowded-model 低: dialog Some((650, 75.5, 379, 450.5)) high Some((951, 185.5, 72, 36))",
    #|  "newchat-crowded-model 最高: dialog Some((650, 75.5, 379, 450.5)) high Some((951, 185.5, 72, 36))",
    #|]
  ))
  assert_eq(drawn, [true, true, true])
}
