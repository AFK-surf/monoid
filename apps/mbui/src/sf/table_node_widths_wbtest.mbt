// A table as nodes (table_node) worked out once for what reads it: its columns' widths (every cell's words measured)
// once as it is made, not once for each column, cell, side and rule that reads them; nothing worked out again for what
// it does not read; a cell's link pressed where it leads as it comes to have one.

///|
/// The core's reading of a table, its head `head` and its rows `rows` (each cell its words alone), and its Markdown.
fn tw_table(head : Array[String], rows : Array[Array[String]]) -> (String, Json) {
  let cell = fn(s : String) { Json::array([Json::string("td"), Json::array([Json::string(s)])]) }
  let line = fn(cs : Array[String]) { Json::array([Json::string("tr"), Json::array(cs.map(cell))]) }
  let md_line = fn(cs : Array[String]) { "| " + cs.join(" | ") + " |" }
  let md = [md_line(head), md_line(head.map(fn(_) { "---" }))]
  for r in rows {
    md.push(md_line(r))
  }
  let all = [line(head)]
  for r in rows {
    all.push(line(r))
  }
  (md.join("\n"), Json::array([Json::array([Json::string("table"), Json::array(all)])]))
}

///|
/// A table of four columns and a head over three rows, as a chat's agent writes one.
fn tw_four() -> (String, Json) {
  tw_table(["模型", "输入", "输出", "备注"], [
    ["Opus 5.5", "$15", "$75", "最强的推理与写代码"],
    ["Sonnet 5.5", "$3", "$15", "日常的大多数事"],
    ["Haiku 5.5", "$0.8", "$4", "快而便宜，适合分类与摘要"],
  ])
}

///|
/// The frames the journal holds from its `from`th entry on: nodes made and bindings run, all of them.
fn tw_work(from : Int) -> (Int, Int) {
  let mut made = 0
  let mut bindings = 0
  for i, e in @ui.journal() {
    guard i >= from else { continue }
    match e {
      Work({ what: Frame(f), .. }) => {
        made += f.made
        bindings += f.bindings
      }
      _ => ()
    }
  }
  (made, bindings)
}

///|
test "a table of four columns made: its columns' widths worked out once, not again as what it does not read changes, again once laid out narrower" {
  let (text, tree) = tw_four()
  let other = @signals.signal(0)
  let tt = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=400.0, platform=2)
  let before = table_widths_worked.val
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) { table_node(b, fn() { text }, tree=fn() { Some(tree) }) }) |> ignore
    root.box(fn(o) { o.words(By(fn() { "其它 \{other.get()}" })) |> ignore }) |> ignore
  })
  tt.draw()
  let made = table_widths_worked.val - before
  let drawn = @ui.view_tree().unwrap().drawn().filter(fn(d) { d.words == "最强的推理与写代码" || d.words == "Haiku 5.5" }).length()
  // (what it does not read changed: nothing of it worked out again)
  other.set(1)
  tt.draw()
  tt.draw()
  let still = table_widths_worked.val - before
  // (laid out narrower: once more)
  tt.resize(320.0, 400.0)
  tt.draw()
  let narrower = table_widths_worked.val - before
  assert_eq((made, drawn, still, narrower), (1, 2, 1, 2))
}

///|
test "a table of four columns made with a finger: the nodes it makes and the bindings it runs, within its bar" {
  let (text, tree) = tw_four()
  let tt = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=400.0, platform=2)
  tt.draw()
  let from = @ui.journal().length()
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) { table_node(b, fn() { text }, tree=fn() { Some(tree) }) }) |> ignore
  })
  tt.draw()
  let (made, bindings) = tw_work(from)
  println("table of four columns: made \{made} bindings \{bindings}")
  assert_true(made <= tw_four_made && bindings <= tw_four_bindings, msg="made \{made} bindings \{bindings}")
}

///|
/// The most nodes a table of four columns (tw_four) makes and bindings it runs as it is made: a bar that only falls.
/// Counted 2026-11-16 once its columns' widths are worked out once, a cell's width and sides are one binding, its look
/// said once and how its pieces are set and their ink one, its links made only as it has one, no structure under a row
/// for its rule and no pick where it is not shown smaller: before them 68 made, 164 bindings run.
let tw_four_made : Int = 63

///|
/// See tw_four_made.
let tw_four_bindings : Int = 79

///|
test "a table's cell with no link, its words told anew with one: tapped on its link, where it leads told; before, nothing" {
  let led : Array[String] = []
  let tt = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=400.0, platform=2)
  let s = fn(w : String) { Json::string(w) }
  let el = fn(name : String, kids : Array[Json]) { Json::array([s(name), Json::array(kids)]) }
  let plain = Json::array([
    el("table", [el("tr", [el("td", [s("名")]), el("td", [s("址")])]), el("tr", [el("td", [s("文档")]), el("td", [s("见链接处")])])]),
  ])
  let link = Json::array([s("a"), Json::array([s("链接")]), Json::object({ "href": s("https://still.fail") })])
  let linked = Json::array([
    el("table", [el("tr", [el("td", [s("名")]), el("td", [s("址")])]), el("tr", [el("td", [s("文档")]), el("td", [s("见"), link, s("处")])])]),
  ])
  let tree = @signals.signal(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(a) {
      table_node(
        a,
        fn() { if tree.get() { "| 名 | 址 |\n| --- | --- |\n| 文档 | 见[链接](https://still.fail)处 |" } else { "| 名 | 址 |\n| --- | --- |\n| 文档 | 见链接处 |" } },
        tree=fn() { Some(if tree.get() { linked } else { plain }) },
        copy=false,
        on_link=fn(href) { led.push(href) },
      )
    })
    |> ignore
  })
  tt.draw()
  let at = fn() raise {
    let cell = @ui.view_tree().unwrap().drawn().filter(fn(d) { d.words == "见链接处" })
    guard cell is [d] else { fail("the cell's words drawn once by the tree: \{cell.length()}") }
    (d.x + d.w / 2.0, d.y + d.h / 2.0)
  }
  let (x, y) = at()
  tt.tap(x, y)
  tt.run_for(@ui.move_most_ms)
  let before = led.copy()
  tree.set(true)
  tt.draw()
  let (x, y) = at()
  tt.tap(x, y)
  tt.run_for(@ui.move_most_ms)
  assert_eq((before, led), ([], ["https://still.fail"]))
}
