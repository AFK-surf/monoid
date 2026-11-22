///|
test "multiple matches on one search result line are each stroked under their own word" {
  let text = "hit hit hit"
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w=500.0, h=100.0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    @sf.found_words_node(root, fn() { text }, fn() { [(0, 3), (4, 7), (8, 11)] }, fn() {
      @sf.theme().chat_list.found.words
    }, fn() { @sf.theme().p.text })
    |> ignore
  })
  t.draw()
  t.run_for(@sf.strokes_ms(3))
  t.draw()
  // (the strokes drawn: each a run of pieces, one's end the next one's start; apart from each other, one under each)
  let pieces = t.drawn_lines().filter(fn(l) { l.4 == @sf.line_stroke.width })
  pieces.sort_by(fn(p, q) { p.0.compare(q.0) })
  let mut strokes = if pieces.is_empty() { 0 } else { 1 }
  for k in 1..<pieces.length() {
    if pieces[k].0 > pieces[k - 1].2 + 1.0 {
      strokes = strokes + 1
    }
  }
  assert_eq(strokes, 3, msg="a stroke under each of the three matches: \{Repr(pieces)}")
  // (under the words, the line's 20 high)
  assert_true(pieces.iter().all(fn(l) { l.1 >= 10.0 && l.1 <= 26.0 }), msg="\{Repr(pieces)}")
}

///|
test "chat find marker ink keeps text, links, and code legible in light and dark themes" {
  for dark in [false, true] {
    @sf.set_dark(Some(dark))
    let theme = @sf.theme()
    let ink = @sf.find_marker_bg(dark)
    let page = @sf.over(theme.p.bg, ink)
    let code = @sf.over(theme.p.code_ground, ink)
    assert_true(@ui.contrast_ratio(theme.p.text, page) >= 4.5, msg="message text stays legible")
    assert_true(@ui.contrast_ratio(theme.p.accent_text, page) >= 4.5, msg="links stay legible")
    assert_true(@ui.contrast_ratio(theme.p.code_ink, code) >= 4.5, msg="code stays legible")
  }
  @sf.set_dark(None)
}
