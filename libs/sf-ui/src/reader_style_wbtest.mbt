///|
test "the reader's line spacing stays proportional when system text is larger" {
  let words = "第一行的小说正文\n第二行的小说正文"
  let book : Book = {
    title: "小说",
    id: 1,
    text: words,
    chunks: [words],
    starts: [0],
    parts: [],
    length: words.length(),
    chapters: [],
    heads: Map([]),
    encoding: "UTF-8",
    truncated: false,
    markdown: false,
  }
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=400.0, platform=2)
  // (after the run begins, which lets go of every reading)
  let r = reading_for("reader-system-text")
  r.asked = true
  r.book.set(Some(book))
  set_viewer_host(viewer_host_default())
  (viewer_host().set_reader_style)(Indent(false))
  let style = (viewer_host().reader_style)()
  let file = blob_file(@utf8.encode(words), "小说.txt", words.length().to_double(), save=fn() {  })
  @ui.set_view_app(fn(root) {
    reader_node(root, "reader-system-text", file, markdown=false, back_label=fn() { "返回" }, on_back=fn() {  }) |> ignore
  })
  t.set_font_scale(1.5)
  t.draw()
  let lines = t.text_runs().filter(fn(line) { line.text.contains("小说正文") })
  assert_eq(lines.length(), 2)
  let spacing = lines[1].top - lines[0].top
  let expected = @ui.sp_at(1.5, style.size.to_double()) * style.line
  assert_true((spacing - expected).abs() < 0.01, msg="spacing \{spacing}, expected \{expected}")
  reader_let_go("reader-system-text")
  (viewer_host().set_reader_style)(Indent(true))
}

///|
test "a Markdown document's line spacing follows the larger system text too" {
  let words = "第一行的小说正文\n第二行的小说正文"
  let nodes : Array[Json] = [["p", ["第一行的小说正文", ["br", []], "第二行的小说正文"]]]
  let style = reader_style_default
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=200.0, platform=2)
  @ui.set_view_app(fn(root) {
    markdown_node(root, fn() { words }, nodes=fn() { nodes }, size=fn() { style.size.to_double() }, line=fn() { style.line }, document=true)
    |> ignore
  })
  t.set_font_scale(1.5)
  t.draw()
  let lines = t.text_runs().filter(fn(line) { line.text.contains("小说正文") })
  assert_eq(lines.length(), 2)
  let spacing = lines[1].top - lines[0].top
  let expected = @ui.sp_at(1.5, style.size.to_double()) * style.line
  assert_true((spacing - expected).abs() < 0.01, msg="spacing \{spacing}, expected \{expected}")
}

///|
test "a Markdown document read follows the layout's line as it is changed, its blocks after the first apart from the one over" {
  let words = "第一行的小说正文\n第二行的小说正文\n"
  let text = words + words
  let para : Json = ["p", ["第一行的小说正文", ["br", []], "第二行的小说正文"]]
  let book : Book = {
    title: "说明",
    id: 2,
    text,
    chunks: [words, words],
    starts: [0, words.length()],
    parts: [[para], [para]],
    length: text.length(),
    chapters: [],
    heads: Map([]),
    encoding: "UTF-8",
    truncated: false,
    markdown: true,
  }
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=600.0, platform=2)
  let r = reading_for("reader-md-line")
  r.asked = true
  r.book.set(Some(book))
  set_viewer_host(viewer_host_default())
  let file = blob_file(@utf8.encode(text), "说明.md", text.length().to_double(), save=fn() {  })
  @ui.set_view_app(fn(root) {
    reader_node(root, "reader-md-line", file, markdown=true, back_label=fn() { "返回" }, on_back=fn() {  }) |> ignore
  })
  t.draw()
  let tops = fn() {
    t.text_runs().filter(fn(line) { line.text.contains("小说正文") }).map(fn(line) { line.top })
  }
  let size = (viewer_host().reader_style)().size.to_double()
  let spacing = fn() {
    let at = tops()
    at[1] - at[0]
  }
  let was = spacing()
  assert_true((was - size * 1.7).abs() < 0.01, msg="at 1.7: \{was}")
  // the second block's first line under the first's last: a line, and a paragraph's margin
  let at = tops()
  assert_eq(at.length(), 4)
  assert_true(at[2] - at[1] >= was + paragraph_after - 0.01, msg="apart: \{at[2] - at[1]}, a line \{was}")
  @ui.view_tree().unwrap().event(t.time(), fn() { (viewer_host().set_reader_style)(Line(2.2)) })
  t.draw()
  let now = spacing()
  assert_true((now - size * 2.2).abs() < 0.01, msg="at 2.2: \{now}")
  reader_let_go("reader-md-line")
  (viewer_host().set_reader_style)(Line(reader_style_default.line))
}
