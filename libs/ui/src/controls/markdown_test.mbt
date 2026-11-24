///|
let sample : String =
  #|## 今天的进度
  #|
  #|改好了 **布局** 和 *动画*，见 [说明](https://example.com/notes)。
  #|
  #|- 第一项，`inline code`
  #|- 第二项
  #|  1. nested one
  #|- [x] 做完的事
  #|
  #|> 引用里的一句话
  #|
  #|```sh
  #|moon test
  #|```

///|
fn md_node_tester(
  w : Double,
  h : Double,
  platform? : Int = 0,
  pad? : Double = 16.0,
  body : (@view.View) -> Unit,
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(c) { @controls.begin(c) |> ignore }, w~, h~, platform~)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@controls.ui_theme_now)
    root.lines_up(Is(None)) |> ignore
    root.box(fn(col) {
      if pad > 0.0 {
        col.padding(Is((pad, pad, pad, pad))) |> ignore
      }
      body(col)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "a message's Markdown: its blocks, their margins collapsed, links and copy" {
  let went = []
  let t = md_node_tester(390.0, 844.0, platform=2, fn(col) {
    @controls.markdown_node(col, fn() { sample }, on_link=fn(h) { went.push(h) }) |> ignore
  })
  // the heading first, its top margin dropped
  let (_, hy, _, _) = t.rect_of("今天的进度").unwrap()
  assert_eq(hy, 16.0)
  // the paragraph 6 below the heading's bottom: the heading's margin under it, a paragraph none above (the web's
  // .markdown h2 14 0 6, p 0 0 8, on every screen)
  let (_, hy2, _, hh) = t.rect_of("今天的进度").unwrap()
  let (_, py, _, ph) = t.rect_of("改好了").unwrap()
  assert_eq(py - (hy2 + hh), 6.0)
  // the list 8 below the paragraph: the paragraph's margin under it, a list none above
  let (_, ly, _, _) = t.rect_of("第一项").unwrap()
  assert_eq(ly - (py + ph), 8.0)
  // a tight list's items follow each other with no gap
  let (_, y1, _, h1) = t.rect_of("第一项").unwrap()
  let (_, y2, _, _) = t.rect_of("第二项").unwrap()
  assert_eq(y2, y1 + h1)
  assert_true(t.rect_of("nested one") is Some(_))
  assert_true(t.rect_of("引用里的一句话") is Some(_))
  t.tap_run("说明")
  assert_eq(went, ["https://example.com/notes"])
  t.tap_text("复制")
  assert_eq(t.clipboard(), "moon test")
  assert_true(t.rect_of("已复制") is Some(_))
}

///|
test "a message's Markdown dragged over and copied: beside its words, HTML keeping its heading, its list's items and their code, its block of code" {
  let t = md_node_tester(390.0, 844.0, platform=0, fn(col) {
    @ui.words_picked(col)
    @controls.markdown_node(col, fn() { sample }) |> ignore
  })
  let at = fn(s : String) { t.words().iter().find_first(fn(w) { w.0.contains(s) }) }
  guard at("今天的进度") is Some(first) && at("moon test") is Some(last) else {
    fail("not drawn: \{Repr(t.words())}")
  }
  t.drag(first.1 + 1.0, first.2 + first.4 / 2.0, last.1 + last.3 - 1.0, last.2 + last.4 / 2.0)
  t.run_for(@ui.move_most_ms)
  t.key(@ui.key_code_copy)
  let html = t.clipboard_html()
  assert_true(t.clipboard().contains("第一项，inline code"), msg=t.clipboard())
  assert_true(html.has_prefix("<h2>今天的进度</h2>"), msg=html)
  assert_true(html.contains("<strong>布局</strong>"), msg=html)
  assert_true(html.contains("<em>动画</em>"), msg=html)
  assert_true(html.contains("<li>第一项，<code>inline code</code></li><li>第二项<ol><li>nested one</li></ol></li>"), msg=html)
  assert_true(html.contains("<blockquote><p>引用里的一句话</p></blockquote>"), msg=html)
  assert_true(html.has_suffix("<pre><code>moon test</code></pre>"), msg=html)
}

///|
test "a table's cell of only the message's images: them side by side, 160 wide at most, not their names" {
  let drawn : Array[(String, Double)] = []
  let t = md_node_tester(390.0, 844.0, fn(col) {
    @controls.markdown_node(
      col,
      fn() { "| 网页 | 手机网页 |\n|---|---|\n| ![](web%2Dfolded.png) | ![](phone.png) |\n" },
      files=fn(name) {
        // a wide one and a tall one
        let r = if name == "web-folded.png" { 2.0 } else { 0.5 }
        Some({
          draw: fn(_) {  },
          image: Some((r, fn(v, w) {
            v.width(By(fn() {
              let x = w()
              drawn.push((name, x))
              Some(x)
            }))
            |> ignore
          })),
        })
      },
    )
    |> ignore
  })
  t.draw()
  assert_true(drawn.contains(("web-folded.png", 160.0)) && drawn.contains(("phone.png", 120.0)), msg="\{Repr(drawn)}")
  assert_true(t.find("web") is None)
  assert_true(t.find("网页") is Some(_))
}

///|
test "a paragraph of only the message's images: side by side as one row's height, onto the next row when they don't fit" {
  let text = @signals.signal("左边是新做法，右边是现在的：\n\n![](a.png) ![](b.png)\n")
  let widths : Map[String, Double] = Map([])
  let t = md_node_tester(390.0, 844.0, fn(col) {
    @controls.markdown_node(col, fn() { text.get() }, files=fn(name) {
      // a.png and b.png a little taller than wide, the wide ones twice as wide as high
      let r = if name.has_prefix("wide") { 2.0 } else { 0.64 }
      Some({
        draw: fn(_) {  },
        image: Some(
          (
            r,
            fn(v, w) {
              v
              .width(By(fn() {
                let x = w()
                widths[name] = x
                Some(x)
              }))
              .height(By(fn() { Some(w() / r) }))
              .words(Is(name))
              |> ignore
            },
          ),
        ),
      })
    })
    |> ignore
  })
  t.draw()
  // both on one row, 200 high (the most a row is): as wide as that makes them, 8 apart
  assert_eq((widths.get("a.png"), widths.get("b.png")), (Some(128.0), Some(128.0)))
  let (ax, ay, _, _) = t.rect_of("a.png").unwrap()
  let (bx, by, _, _) = t.rect_of("b.png").unwrap()
  assert_eq(by, ay)
  assert_eq(bx, ax + 128.0 + 8.0)
  // two wide ones (240 each at 120 high) don't fit the message's 358 side by side: each a row of its own, as wide as it
  widths.clear()
  text.set("![](wide1.png) ![](wide2.png)")
  t.frame()
  t.frame()
  assert_eq((widths.get("wide1.png"), widths.get("wide2.png")), (Some(358.0), Some(358.0)))
  let (_, y1, _, _) = t.rect_of("wide1.png").unwrap()
  let (_, y2, _, _) = t.rect_of("wide2.png").unwrap()
  assert_eq(y2, y1 + 179.0 + 8.0)
}

///|
test "a table in a shared picture fits whole inside the message and leaves room for the following paragraph" {
  let cell = fn(tag : String, value : String) -> Json { [Json::string(tag), [Json::string(value)]] }
  for (cols, unbroken, font_scale) in [(6, false, 1.0), (6, true, 1.0), (20, false, 1.0), (20, false, 1.8)] {
    let names = Array::makei(cols, fn(i) { if i == 0 { "First" } else if i == cols - 1 { "Last" } else { "Column\{i}" } })
    let words = if unbroken { "unbrokenword".repeat(12) } else { "a long cell of words that needs room to remain readable" }
    let tree : Json = [
      ["table", [
        ["tr", Json::array(names.map(fn(s) { cell("th", s) }))],
        ["tr", Json::array(names.map(fn(s) { cell("td", s + " " + words) }))],
      ]],
      ["p", ["After the table"]],
    ]
    let t = md_node_tester(760.0, 844.0, fn(col) {
      @controls.markdown_node(col, fn() { "wide table \{cols} \{font_scale} " + words }, tree=fn() { Some(tree) }, copy=false, fit_tables=true)
      |> ignore
    })
    t.set_font_scale(font_scale)
    t.draw()
    let (_, _, _, first_h) = t.rect_of("First").unwrap()
    let last = if unbroken { "Last unbrokenword" } else { "Last a long" }
    let (last_x, last_y, last_w, last_h) = t.rect_of(last).unwrap()
    let (_, after_y, _, _) = t.rect_of("After the table").unwrap()
    // Text, including a long unbroken word, wraps at normal size. Many columns are laid out at a smaller size.
    assert_true(if cols == 20 { first_h < 16.0 } else { first_h >= 16.0 }, msg="table header height \{first_h}")
    if unbroken { assert_true(t.lines_of(last).length() > 1, msg="the long word did not wrap") }
    assert_true(last_x + last_w <= 744.001, msg="the last column extends past the picture: \{last_x + last_w}")
    assert_true(after_y >= last_y + last_h - 0.001, msg="the paragraph overlaps the table")
  }
}

///|
test "a table too wide for the message: its columns 14em, not squeezed; scrolled out over the page's margin to its end, its key's in line with the words" {
  let long = "a long cell of words that would wrap to a word or two if squeezed into the message"
  let t = md_node_tester(390.0, 844.0, fn(col) {
    @controls.markdown_node(col, fn() { "| 一 | 二 | 三 |\n|---|---|---|\n| one \{long} | two \{long} | three \{long} |\n" }, bleed=fn() { 16.0 })
    |> ignore
  })
  t.draw()
  let column = 14.0 * 13.0 + 24.0
  let (x1, y) = t.drawn_of("one a long").unwrap()
  let (x2, _) = t.drawn_of("two a long").unwrap()
  let (x3, _) = t.drawn_of("three a long").unwrap()
  // at rest its first words in line with the message's (16 in: no card, no room before them); each column 14em of its
  // words (13) and its cells' 12 between them, though the three are wider than the message
  assert_eq(x1, 16.0)
  assert_eq(x2 - x1, column)
  assert_eq(x3 - x2, column)
  // dragged to its end: its key's room in line with the words' right edge (16 in from the right)
  for _ in 0..<4 {
    t.drag(370.0, y + 5.0, 20.0, y + 5.0)
    t.draw()
  }
  t.frame()
  let (x3_end, _) = t.drawn_of("three a long").unwrap()
  // (its last words its end, nothing after them; its copy key past it: 6, 32, 6)
  assert_eq(x3_end + column - 24.0, 390.0 - 16.0 - 44.0)
  // what went left shows out to the screen's edge, not cut at the words' margin
  let (shown, _, _, _) = t.shown_of("two a long").unwrap()
  assert_eq(shown, 0.0)
}

///|
test "an image the app cannot draw reads as its file's name, decoded" {
  let t = md_node_tester(390.0, 844.0, pad=0.0, fn(col) {
    @controls.markdown_node(col, fn() { "见 ![](web%2Dfolded%2D2%2Epng)" }) |> ignore
  })
  t.draw()
  assert_true(t.find("web-folded-2.png") is Some(_))
}

///|
let long_code : String = "let total = items.map(fn(x) { x.price * x.count }).fold(init=0, fn(a, b) { a + b }) // a line longer than the message"

///|
test "a code block's line longer than the message: on one line, scrolled across; its wrap key wraps it at the block's width, pressed again on one line again" {
  let t = md_node_tester(390.0, 844.0, platform=2, fn(col) {
    @controls.markdown_node(col, fn() { "```js\n" + long_code + "\n```\n\n之后的一段" }) |> ignore
  })
  // (how far down what follows the block is: the block as tall as its lines)
  let y0 = t.rect_of("之后的一段").unwrap().1
  t.tap_text("换行")
  t.run_for(@ui.move_most_ms)
  let y1 = t.rect_of("之后的一段").unwrap().1
  // (wrapped: on lines enough for its words, two more of its 18 at least)
  assert_true(y1 >= y0 + 18.0 * 2.0, msg="wrapped: \{y0} -> \{y1}")
  t.tap_text("不换行")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.rect_of("之后的一段").unwrap().1, y0)
  // (copied whole either way)
  t.tap_text("复制")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.clipboard(), long_code)
}
