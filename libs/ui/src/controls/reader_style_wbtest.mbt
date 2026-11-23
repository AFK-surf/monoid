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

///|
test "reader desk controls: 1.0x keeps exact heights; 2.0x grows with zero fixed_outgrown or squeeze_faults" {
  // 1. reader_layout_docked: desk_swatch_off/on, desk_size_row, desk_size_key_box
  let tr = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=900.0, h=700.0, platform=0)
  tr.check_looks(false)
  set_viewer_host(viewer_host_default())
  @ui.set_view_app(
    fn(root) {
      reader_layout_docked(root, fn() {  })
    },
    theme=ui_theme_now,
  )
  tr.draw()
  let size_word = t("web-pages.drive.reader.size")
  let smaller_label = t("web-pages.drive.reader.less", args=[("what", size_word)])
  let bigger_label = t("web-pages.drive.reader.more", args=[("what", size_word)])
  assert_eq(tr.get(Button, label=smaller_label).rect.3, @ui.Space::S8.px(), msg="1.0x size key height")
  assert_eq(tr.get(Button, label=bigger_label).rect.3, @ui.Space::S8.px(), msg="1.0x bigger key height")
  assert_eq(tr.fixed_outgrown(), [], msg="1.0x layout fixed_outgrown")
  tr.set_font_scale(2.0)
  tr.draw()
  let hk2 = tr.get(Button, label=smaller_label).rect.3
  assert_true(hk2 > @ui.Space::S8.px(), msg="2.0x size key height grew: \{hk2}")
  assert_eq(tr.fixed_outgrown(), [], msg="2.0x layout fixed_outgrown")
  // 2. desk_found_box, desk_find_field, desk_swatch_off, desk_size_row
  let t2 = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=400.0, platform=0)
  t2.check_looks(false)
  let mut found_v : @view.View? = None
  let mut field_v : @view.View? = None
  let mut swatch_v : @view.View? = None
  let mut size_row_v : @view.View? = None
  @ui.set_view_app(
    fn(root) {
      root.padding(Is((16.0, 16.0, 16.0, 16.0))).gap(Is(8.0)) |> ignore
      root.box(fn(b) {
        found_v = Some(b)
        style_node(b, fn() { desk_found_box })
        words_node(b, fn() { "1 / 12" }, fn() { desk_found_words }) |> ignore
      })
      |> ignore
      root.box(fn(b) {
        field_v = Some(b)
        style_node(b, fn() { desk_find_field })
        words_node(b, fn() { "查找正文" }, fn() { @ui.text_style(size=Ui, wrap=false) }) |> ignore
      })
      |> ignore
      root.box(fn(b) {
        swatch_v = Some(b)
        style_node(b, fn() { desk_swatch_off })
        words_node(b, fn() { "文" }, fn() { desk_swatch_glyph }) |> ignore
      })
      |> ignore
      root.box(fn(b) {
        size_row_v = Some(b)
        style_node(b, fn() { desk_size_row })
        b.box(fn(k) {
          style_node(k, fn() { desk_size_key_box })
          words_node(k, fn() { "A−" }, fn() { desk_size_key_words }) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  let h_of = fn(v : @view.View?) {
    let id = v.unwrap().id()
    match @ui.view_tree().unwrap().drawn().iter().find_first(fn(d) { d.id == id }) {
      Some(d) => d.h
      None => 0.0
    }
  }
  t2.draw()
  assert_eq(h_of(found_v), @ui.Space::S10.px(), msg="1.0x desk_found_box")
  assert_eq(h_of(field_v), desk_field_h, msg="1.0x desk_find_field")
  assert_eq(h_of(swatch_v), @ui.Space::S11.px(), msg="1.0x desk_swatch_off")
  assert_eq(h_of(size_row_v), desk_size_row_h, msg="1.0x desk_size_row")
  assert_eq(t2.fixed_outgrown(), [], msg="1.0x styles fixed_outgrown")
  assert_eq(t2.squeeze_faults(), [], msg="1.0x styles squeeze_faults")
  t2.set_font_scale(2.0)
  t2.draw()
  assert_true(h_of(found_v) >= @ui.Space::S10.px(), msg="2.0x desk_found_box: \{h_of(found_v)}")
  assert_true(h_of(field_v) > desk_field_h, msg="2.0x desk_find_field grew: \{h_of(field_v)}")
  assert_true(h_of(swatch_v) >= @ui.Space::S11.px(), msg="2.0x desk_swatch_off: \{h_of(swatch_v)}")
  assert_true(h_of(size_row_v) > desk_size_row_h, msg="2.0x desk_size_row grew: \{h_of(size_row_v)}")
  assert_eq(t2.fixed_outgrown(), [], msg="2.0x styles fixed_outgrown")
  assert_eq(t2.squeeze_faults(), [], msg="2.0x styles squeeze_faults")
  t2.set_font_scale(3.0)
  t2.draw()
  assert_true(h_of(found_v) > @ui.Space::S10.px(), msg="3.0x desk_found_box grew: \{h_of(found_v)}")
  assert_true(h_of(swatch_v) > @ui.Space::S11.px(), msg="3.0x desk_swatch_off grew: \{h_of(swatch_v)}")
  assert_eq(t2.fixed_outgrown(), [], msg="3.0x styles fixed_outgrown")
  assert_eq(t2.squeeze_faults(), [], msg="3.0x styles squeeze_faults")
}
