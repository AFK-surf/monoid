// A panel of the presenters' opened by nothing a share of the window tall (@sf.panel_nodes `from` Unanchored, `tall`), a
// dialog in the middle of the window, on 大屏, as it was when the old contract was measured on main beside it. What it
// holds fills its share; one with a list as tall as what it holds up to its share (`hugs`); no taller than the window
// leaves it.

///|
/// A body of a list of `rows` rows (each about 40), as a panel a share of the window tall holds one.
fn tall_list_body(rows : @signals.Signal[Int]) -> (@view.View, () -> Unit) -> Unit {
  fn(v, _close) {
    @sf.panel_list_node(v, fn() { Array::makei(rows.get(), fn(i) { i }) }, fn(b, i) {
      @sf.words_node(b, fn() { "第\{i}行" }, fn() { @sf.paragraph }) |> ignore
    }, est=40.0)
    |> ignore
  }
}

///|
/// Where a tall centred panel's dialog is, its first row, the last row shown in it, after the wheel over its middle
/// its first row, and after the wheel as far down as it goes whether its last row of `n` is drawn whole between its title
/// and its foot (all of what it holds reached, nothing of it under its foot).
fn tall_said(t : @ui.Tester, n : Int) -> String {
  let w = fn(s : String) { t.words().filter(fn(x) { x.0 == s }).map(fn(x) { tenth4((x.1, x.2, x.3, x.4)) }) }
  guard t.query(Dialog, label="面板") is Some(d) else { return "none" }
  let d = d.rect
  let ok = t.query(Button, label="好的").map(fn(s) { s.rect })
  // (the last row drawn whole between its title's foot and its foot's button's top: a sample of where its rows end,
  // not what its body's own view cuts)
  let over = t.words().filter(fn(x) { x.0 == "面板" }).map(fn(x) { x.2 + x.4 }).last().unwrap_or(d.1)
  let under = ok.map(fn(r) { r.1 }).unwrap_or(d.1 + d.3)
  let between = t.words().filter(fn(x) { x.0.has_prefix("第") && x.2 >= over && x.2 + x.4 <= under })
  let last = between.last().map(fn(x) { x.0 })
  let before = "dialog \{@ui.rect_text(tenth4(d))} row0 \{@ui.list_text(w("第0行").map(@ui.rect_text))} last between \{@ui.some_text(last)} ok \{@ui.some_text(ok.map(tenth4).map(@ui.rect_text))}"
  t.wheel(d.0 + d.2 / 2.0, d.1 + d.3 / 2.0, 120.0)
  t.run_for(@ui.move_most_ms)
  let after = "row0 \{@ui.list_text(w("第0行").map(@ui.rect_text))}"
  t.wheel(d.0 + d.2 / 2.0, d.1 + d.3 / 2.0, -240.0)
  t.run_for(@ui.move_most_ms)
  let far = 60.0 * n.to_double() + 2000.0
  t.wheel(d.0 + d.2 / 2.0, d.1 + d.3 / 2.0, far)
  t.run_for(@ui.move_most_ms)
  // (seen whole: between its title and its foot, each of its glyphs drawn (alpha) within the straight edges it is cut
  // to, its clip and its outer one where it has one (scene.mbt 16-19, 40-43), as panel_reach_said reads them; none
  // drawn: not seen)
  let drawn = t.drawn_instances()
  let end = t.words().filter(fn(x) { x.0 == "第\{n - 1}行" }).map(fn(x) {
    let glyphs = drawn.filter(fn(d) {
      d[5] == 1.0 && d[11] > 0.0 && d[0] >= x.1 - 0.01 && d[0] < x.1 + x.3 && d[1] >= x.2 - 0.01 && d[1] < x.2 + x.4
    })
    x.2 >= over &&
    x.2 + x.4 <= under + 0.01 &&
    glyphs.length() > 0 &&
    glyphs.iter().all(fn(d) {
      let outer = d[44] > 0.0 || d[45] > 0.0 || d[46] > 0.0 || d[47] > 0.0
      let (y0, y1) = (dmax(d[17], if outer { d[41] } else { d[1] }), dmin(d[19], if outer { d[43] } else { d[1] + d[3] }))
      let (x0, x1) = (dmax(d[16], if outer { d[40] } else { d[0] }), dmin(d[18], if outer { d[42] } else { d[0] + d[2] }))
      d[1] >= y0 - 0.01 && d[1] + d[3] <= y1 + 0.01 && d[0] >= x0 - 0.01 && d[0] + d[2] <= x1 + 0.01
    })
  })
  t.wheel(d.0 + d.2 / 2.0, d.1 + d.3 / 2.0, -far)
  t.run_for(@ui.move_most_ms)
  "\{before} | wheel: \{after} | end: \{@ui.list_text(end)}"
}

///|
test "panel centred a share of the window tall, 大屏 keyboard and mouse: a column, a list of few rows, of many, in a tall window and a short one, a share taller than the dialog may be, with what it says; its list grown, then fewer again: where it is, what the wheel scrolls, its last row seen at its end, drawn by the window's tree" {
  let out = []
  let drawn = []
  for kind in ["column 800", "column 500", "few 800", "many 800", "many 500", "deep 500", "says 800", "grown 800"] {
    let h = if kind.has_suffix("500") { 500.0 } else { 800.0 }
    let t = menu_tester(1280.0, h, 0)
    let foot = fn(v : @view.View, close : () -> Unit) { @sf.button_node(v, fn() { "好的" }, close, tone=Primary) |> ignore }
    let rows = @signals.signal(if kind.has_prefix("many") || kind.has_prefix("says") || kind.has_prefix("deep") { 60 } else { 3 })
    match kind {
      "column 800" | "column 500" => @sf.panel_nodes("面板", panel_column_body(@signals.signal(40)), from=Unanchored, tall=0.5, foot~)
      "says 800" => @sf.panel_nodes("面板", tall_list_body(rows), from=Unanchored, tall=0.8, hugs=true, description="说明的话", foot~)
      // (a share taller than the dialog may be in the window: what it holds held shorter than it asks)
      "deep 500" => @sf.panel_nodes("面板", tall_list_body(rows), from=Unanchored, tall=0.95, hugs=true, foot~)
      _ => @sf.panel_nodes("面板", tall_list_body(rows), from=Unanchored, tall=0.8, hugs=true, foot~)
    }
    t.run_for(@ui.move_most_ms)
    out.push("\{kind}: \{tall_said(t, if kind.has_prefix("column") { 40 } else { rows.get() })}")
    // (drawn by the window's tree)
    drawn.push(tree_said(Dialog, "面板") is Some(_))
    if kind == "grown 800" {
      rows.set(60)
      t.run_for(@ui.move_most_ms)
      out.push("\{kind} to 60: \{tall_said(t, 60)}")
      rows.set(5)
      t.run_for(@ui.move_most_ms)
      out.push("\{kind} to 5: \{tall_said(t, 5)}")
    }
  }
  assert_true(drawn.iter().all(fn(d) { d }))
  debug_inspect(out, content=(
    #|[
    #|  "column 800: dialog (380, 169.5, 520, 461) row0 [(404, 244.5, 472, 22)] last between Some(第13行) ok Some((820, 572.5, 54, 32)) | wheel: row0 [(404, 124.5, 472, 22)] | end: [true]",
    #|  "column 500: dialog (380, 94.5, 520, 311) row0 [(404, 169.5, 472, 22)] last between Some(第7行) ok Some((820, 347.5, 54, 32)) | wheel: row0 [(404, 49.5, 472, 22)] | end: [true]",
    #|  "few 800: dialog (380, 288.5, 520, 223) row0 [(396, 363.5, 488, 22)] last between Some(第2行) ok Some((820, 453.5, 54, 32)) | wheel: row0 [(396, 363.5, 488, 22)] | end: [true]",
    #|  "many 800: dialog (380, 49.5, 520, 701) row0 [(396, 124.5, 488, 22)] last between Some(第24行) ok Some((820, 692.5, 54, 32)) | wheel: row0 [] | end: [true]",
    #|  "many 500: dialog (380, 24, 520, 452) row0 [(396, 99, 488, 22)] last between Some(第13行) ok Some((820, 418, 54, 32)) | wheel: row0 [] | end: [true]",
    #|  "deep 500: dialog (380, 24, 520, 452) row0 [(396, 99, 488, 22)] last between Some(第13行) ok Some((820, 418, 54, 32)) | wheel: row0 [] | end: [true]",
    #|  "says 800: dialog (380, 36.5, 520, 727) row0 [(396, 137.5, 488, 22)] last between Some(第24行) ok Some((820, 705.5, 54, 32)) | wheel: row0 [] | end: [true]",
    #|  "grown 800: dialog (380, 288.5, 520, 223) row0 [(396, 363.5, 488, 22)] last between Some(第2行) ok Some((820, 453.5, 54, 32)) | wheel: row0 [(396, 363.5, 488, 22)] | end: [true]",
    #|  "grown 800 to 60: dialog (380, 49.5, 520, 701) row0 [(396, 124.5, 488, 22)] last between Some(第24行) ok Some((820, 692.5, 54, 32)) | wheel: row0 [] | end: [true]",
    #|  "grown 800 to 5: dialog (380, 266.5, 520, 267) row0 [(396, 341.5, 488, 22)] last between Some(第4行) ok Some((820, 475.5, 54, 32)) | wheel: row0 [(396, 341.5, 488, 22)] | end: [true]",
    #|]

  ))
}
