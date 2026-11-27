///|
/// A Markdown document of a long paragraph and a five-column table of long cells, as the core parts it (markdown's
/// nodes: offsets into the whole text), in one block.
fn wide_doc() -> Book {
  let para = "This report walks through every field of the export, one by one, so that whoever reads it later knows what each column holds, where it comes from and what to check when a value looks wrong; it is long on purpose."
  let heads = ["Field", "Source", "Meaning", "Checks", "Notes"]
  let cell = "a long cell of words that wraps to many lines when squeezed into a narrow column"
  let text = StringBuilder()
  let at = fn() { text.to_string().length() }
  let p0 = at()
  text.write_string(para)
  let p1 = at()
  text.write_string("\n\n|")
  let head_cells : Array[Json] = []
  for h in heads {
    text.write_string(" ")
    let s = at()
    text.write_string(h)
    head_cells.push(["th", [[s, at()]]])
    text.write_string(" |")
  }
  text.write_string("\n|---|---|---|---|---|\n")
  let rows : Array[Json] = [["tr", Json::array(head_cells)]]
  for r in 0..<3 {
    text.write_string("|")
    let cells : Array[Json] = []
    for c in 0..<5 {
      text.write_string(" ")
      let s = at()
      text.write_string("\{heads[c]} \{r} \{cell}")
      cells.push(["td", [[s, at()]]])
      text.write_string(" |")
    }
    text.write_string("\n")
    rows.push(["tr", Json::array(cells)])
  }
  let words = text.to_string()
  let table : Json = [
    "table",
    Json::array(rows),
    { "align": [Json::null(), Json::null(), Json::null(), Json::null(), Json::null()], "md": "", "csv": "" },
  ]
  let nodes : Array[Json] = [["p", [[p0, p1]]], table]
  {
    title: "export",
    id: 75,
    text: words,
    chunks: [words],
    starts: [0],
    parts: [nodes],
    length: words.length(),
    chapters: [],
    heads: Map([]),
    encoding: "UTF-8",
    truncated: false,
    markdown: true,
  }
}

///|
/// The document read over a window `w` by `h` wide on `platform`: its paragraph's lines and its table's cells' lines
/// as drawn, and what the audit finds.
fn wide_doc_read(key : String, w : Double, h : Double, platform : Int) -> (Array[@ui.TextRun], Array[@ui.TextRun], Array[String]) {
  let book = wide_doc()
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h~, platform~)
  let r = reading_for(key)
  r.asked = true
  r.book.set(Some(book))
  set_viewer_host(viewer_host_default())
  let file = blob_file(@utf8.encode(book.text), "export.md", book.text.length().to_double(), save=fn() {  })
  @ui.set_view_app(fn(root) {
    reader_node(root, key, file, markdown=true, back_label=fn() { "返回" }, on_back=fn() {  }) |> ignore
  })
  t.draw()
  let runs = t.text_runs()
  let para = runs.filter(fn(l) { l.top < h && (l.text.contains("report") || l.text.contains("column holds") || l.text.contains("on purpose")) })
  let cells = runs.filter(fn(l) { l.text.contains("cell") || l.text.contains("wraps") || l.text.contains("squeezed") })
  let faults = t.audit()
  reader_let_go(key)
  (para, cells, faults)
}

///|
fn runs_from(runs : Array[@ui.TextRun]) -> Double {
  runs.fold(init=@double.infinity, fn(a, l) { dmin(a, l.x0) })
}

///|
fn runs_to(runs : Array[@ui.TextRun]) -> Double {
  runs.fold(init=0.0, fn(a, l) { dmax(a, l.x1) })
}

///|
test "a Markdown document over a wide window reads in a document's column, its wide table out to the window's edge" {
  let (para, cells, faults) = wide_doc_read("reader-wide-1440", 1440.0, 900.0, 0)
  assert_true(para.length() > 0 && cells.length() > 0, msg="para \{para.length()} cells \{cells.length()}")
  let s = reader_style_default
  let size = s.size.to_double()
  // its paragraph's lines a document's measure: wider than a novel's 34em, no wider than 48em
  let para_w = runs_to(para) - runs_from(para)
  assert_true(para_w > desk_column_ems * size, msg="paragraph \{para_w} wide, a novel's column \{desk_column_ems * size}")
  assert_true(para_w <= doc_column_ems * size + 0.5, msg="paragraph \{para_w} wide, at most \{doc_column_ems * size}")
  // the column in the window's middle
  let column = doc_column_ems * size + 2.0 * s.margin.to_double()
  let column_from = (1440.0 - column) / 2.0 + s.margin.to_double()
  assert_true((runs_from(para) - column_from).abs() < 1.0, msg="paragraph from \{runs_from(para)}, its column's \{column_from}")
  // the table from where the words start, out past the column toward the window's edge (its margin and its copy key's
  // room kept), not scrolled
  assert_true((runs_from(cells) - runs_from(para)).abs() < 16.0, msg="table from \{runs_from(cells)}, the words from \{runs_from(para)}")
  let column_to = column_from + doc_column_ems * size
  assert_true(runs_to(cells) > column_to + 120.0, msg="table to \{runs_to(cells)}, the column to \{column_to}")
  assert_true(runs_to(cells) <= 1440.0 - s.margin.to_double() - table_key_room + 0.5, msg="table to \{runs_to(cells)}")
  assert_eq(faults, [])
}

///|
test "a plain text keeps a novel's column over a wide window while a Markdown document takes a document's" {
  assert_true(doc_column_ems > desk_column_ems)
  // (the column's room by the kind of text: reader_node's ems)
  let _t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=1440.0, h=900.0)
  let r = reading_for("reader-wide-bleed")
  let style = fn() { reader_style_default }
  let wide = fn() { true }
  let s = reader_style_default
  let novel = reader_bleed(r, fn() { Some(desk_column_ems) }, wide, style, fn() { 1440.0 })
  let doc = reader_bleed(r, fn() { Some(doc_column_ems) }, wide, style, fn() { 1440.0 })
  assert_true(novel > doc && doc > 0.0, msg="novel \{novel}, doc \{doc}")
  let column = doc_column_ems * s.size.to_double() + 2.0 * s.margin.to_double()
  assert_true((doc - (1440.0 - column) / 2.0).abs() < 0.01, msg="doc \{doc}")
  // none where the column fills the row
  assert_true(reader_bleed(r, fn() { Some(doc_column_ems) }, wide, style, fn() { 390.0 }) < table_key_room)
  // none where the column is as wide as the row (the layout's 铺满)
  // (but for the hair either side the row keeps: reader_middle_grows)
  assert_true(reader_bleed(r, fn() { None }, wide, style, fn() { 1440.0 }) < 2.0)
  reader_let_go("reader-wide-bleed")
}

///|
test "a Markdown document on a narrow screen keeps its words inside the window, its table from where they start" {
  let (para, cells, faults) = wide_doc_read("reader-wide-390", 390.0, 844.0, 2)
  assert_true(para.length() > 0 && cells.length() > 0, msg="para \{para.length()} cells \{cells.length()}")
  let margin = reader_style_default.margin.to_double()
  assert_true(runs_from(para) >= margin - 0.5, msg="paragraph from \{runs_from(para)}")
  assert_true(runs_to(para) <= 390.0 - margin + 0.5, msg="paragraph to \{runs_to(para)}")
  assert_true((runs_from(cells) - runs_from(para)).abs() < 16.0, msg="table from \{runs_from(cells)}, the words from \{runs_from(para)}")
  assert_eq(faults, [])
}

///|
test "the layout's width: standard keeps a novel's 34em and a document's 48em, wide 48em and 64em, full none" {
  assert_eq(reader_column_ems(false, "standard"), Some(desk_column_ems))
  assert_eq(reader_column_ems(true, "standard"), Some(doc_column_ems))
  assert_eq(reader_column_ems(false, "wide"), Some(wide_text_ems))
  assert_eq(reader_column_ems(true, "wide"), Some(wide_doc_ems))
  assert_eq(reader_column_ems(false, "full"), None)
  assert_eq(reader_column_ems(true, "full"), None)
  // (a width the core never says: the standard column)
  assert_eq(reader_column_ems(true, "huge"), Some(doc_column_ems))
  assert_eq(reader_style_default.width, "standard")
}

///|
test "a Markdown document's column follows the layout's width as it is changed: 48em, then 64em, then the whole row" {
  let key = "reader-wide-width"
  let book = wide_doc()
  let w = 1440.0
  let h = 900.0
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h~, platform=0)
  let r = reading_for(key)
  r.asked = true
  r.book.set(Some(book))
  set_viewer_host(viewer_host_default())
  let file = blob_file(@utf8.encode(book.text), "export.md", book.text.length().to_double(), save=fn() {  })
  @ui.set_view_app(fn(root) {
    reader_node(root, key, file, markdown=true, back_label=fn() { "返回" }, on_back=fn() {  }) |> ignore
  })
  t.draw()
  let s = reader_style_default
  let size = s.size.to_double()
  let margin = s.margin.to_double()
  let read = fn() {
    let runs = t.text_runs()
    let para = runs.filter(fn(l) { l.top < h && (l.text.contains("report") || l.text.contains("column holds") || l.text.contains("on purpose")) })
    let cells = runs.filter(fn(l) { l.text.contains("cell") || l.text.contains("wraps") || l.text.contains("squeezed") })
    (para, cells)
  }
  let (para, _) = read()
  let standard_w = runs_to(para) - runs_from(para)
  assert_true(standard_w <= doc_column_ems * size + 0.5, msg="standard: \{standard_w}")
  // 宽: a document's 64em, wider than the standard 48em; its table still out past it
  @ui.view_tree().unwrap().event(t.time(), fn() { (viewer_host().set_reader_style)(Width("wide")) })
  t.draw()
  let (para, cells) = read()
  let wide_w = runs_to(para) - runs_from(para)
  assert_true(wide_w > doc_column_ems * size && wide_w <= wide_doc_ems * size + 0.5, msg="wide: \{wide_w}")
  let column_from = (w - (wide_doc_ems * size + 2.0 * margin)) / 2.0 + margin
  assert_true((runs_from(para) - column_from).abs() < 1.0, msg="wide from \{runs_from(para)}, its column's \{column_from}")
  assert_true(runs_to(cells) > column_from + wide_doc_ems * size + 40.0, msg="wide table to \{runs_to(cells)}")
  assert_true(runs_to(cells) <= w - margin - table_key_room + 0.5, msg="wide table to \{runs_to(cells)}")
  assert_eq(t.audit(), [])
  // 铺满: the whole row less the margins, its table within it
  @ui.view_tree().unwrap().event(t.time(), fn() { (viewer_host().set_reader_style)(Width("full")) })
  t.draw()
  let (para, cells) = read()
  let full_w = runs_to(para) - runs_from(para)
  assert_true(full_w > wide_doc_ems * size && full_w <= w - 2.0 * margin + 0.5, msg="full: \{full_w}")
  assert_true((runs_from(para) - margin).abs() < 2.0, msg="full from \{runs_from(para)}")
  assert_true((runs_from(cells) - runs_from(para)).abs() < 16.0, msg="full table from \{runs_from(cells)}")
  assert_true(runs_to(cells) <= w - margin + 0.5, msg="full table to \{runs_to(cells)}")
  assert_eq(t.audit(), [])
  reader_let_go(key)
  (viewer_host().set_reader_style)(Width("standard"))
}
