// Chat list row titles and last-message previews disable tabular figures so hovering a row (which reveals the
// relative timestamp / archive action and can ellipsize away trailing digits) does not toggle OpenType `tnum`
// on hyphen-bearing text, while the timestamp itself keeps tabular figures.

///|
fn hover_tabular_run(t : @ui.Tester, prefix : String) -> @ui.TextRun raise {
  for r in t.text_runs() {
    if r.text.has_prefix(prefix) {
      return r
    }
  }
  fail("no text run starting with \{prefix} in \{Repr(t.text_runs().map(fn(r) { r.text }))}")
}

///|
test "chat_row_node disables tabular on title and last preview across hover while keeping row_time tabular" {
  @sfbase.reset()
  reset()
  @sf.set_words(@sfbase.fill)
  let item = {
    ..sample_chat(0),
    title: "claude-opus-4-5 PR #123",
    last: Some("fix-win-hover PR #123"),
    state_text: None,
    decision_text: None,
    ago: "5 minutes ago",
    full: "5 minutes ago",
  }
  // Width 210pt: at rest `last` ("fix-win-hover PR #123", 21 chars * 6pt = 126pt) fits whole;
  // on hover, `row_time` ("5 minutes ago", ~84pt) squeezes `last` so trailing digits "123" are ellipsized away.
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w=210.0, h=200.0, platform=0, pointing=Mouse)
  t.tabular_wider(0.5)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    let popup = root.box(fn(v) { v.over(Is(true)) |> ignore })
    let tips = @sf.TipLayer::new(fn() { Some(popup) })
    chat_row_node(root, @sfbase.sample_source, tips, fn() { item }, "agents", fn() { false }, Side, fn() { 0 }) |> ignore
  })
  t.draw()

  // Theme has tabular: true, but title and last nodes opt out via words_tabular = Some(false).
  assert_true(@sf.ui_theme_now().tabular)
  let tree = @ui.view_tree().unwrap()
  let drawn_rest = tree.drawn()
  let title_node = drawn_rest.iter().find_first(fn(d) { d.words == item.title })
  let last_node = drawn_rest.iter().find_first(fn(d) { d.words == "fix-win-hover PR #123" })
  assert_eq(title_node.map(fn(d) { d.words_tabular }), Some(Some(false)))
  assert_eq(last_node.map(fn(d) { d.words_tabular }), Some(Some(false)))

  // Non-tabular widths at rest: FakeHost gives 0.5 * size per ASCII char when tabular is off,
  // and adds +0.5 * size per digit when tabular is on.
  // Desktop Ui size = 13pt, Meta size = 12pt.
  let title_rest = hover_tabular_run(t, "claude-opus-4-5")
  let last_rest = hover_tabular_run(t, "fix-win-hover")
  assert_eq(last_rest.text, "fix-win-hover PR #123")
  assert_true(
    (title_rest.x1 - title_rest.x0 - title_rest.text.length().to_double() * 0.5 * 13.0).abs() < 0.5,
    msg="title at rest should be non-tabular: \{title_rest.text} width=\{title_rest.x1 - title_rest.x0}",
  )
  assert_true(
    (last_rest.x1 - last_rest.x0 - last_rest.text.length().to_double() * 0.5 * 12.0).abs() < 0.5,
    msg="last at rest should be non-tabular: \{last_rest.text} width=\{last_rest.x1 - last_rest.x0}",
  )
  assert_true(t.find(item.ago) is None)

  // Hover the row to reveal row_time and archive button.
  let (x, y, w, h) = t.get(Link, label=item.title).rect
  t.move_to(x + w / 2.0, y + h / 2.0)
  t.run_for(@sf.dur_ms)

  // row_time is visible and still uses tabular figures (digit '5' gets +0.5 * 12 = +6pt).
  assert_true(t.find(item.ago) is Some(_), msg="row_time should appear on hover")
  let drawn_hover = tree.drawn()
  let time_node = drawn_hover.iter().find_first(fn(d) { d.words == item.ago })
  assert_eq(time_node.map(fn(d) { d.words_tabular }), Some(None))
  let time_size = time_node.unwrap().words_look.size
  let time_run = hover_tabular_run(t, item.ago)
  let expected_time_w = item.ago.length().to_double() * 0.5 * time_size + 0.5 * time_size
  assert_true(
    (time_run.x1 - time_run.x0 - expected_time_w).abs() < 0.5,
    msg="row_time should remain tabular: width=\{time_run.x1 - time_run.x0}, expected=\{expected_time_w}",
  )

  // Under hover, title and last remain non-tabular, and row_time squeezes last narrower than its full text
  // so single-line ellipsizing drops the trailing digits "123".
  let title_hover = hover_tabular_run(t, "claude-opus-")
  assert_true(
    (title_hover.x1 - title_hover.x0 - title_hover.text.length().to_double() * 0.5 * 13.0).abs() < 0.5,
    msg="title on hover should stay non-tabular: \{title_hover.text} width=\{title_hover.x1 - title_hover.x0}",
  )
  let last_hover_node = drawn_hover.iter().find_first(fn(d) { d.words == "fix-win-hover PR #123" })
  assert_eq(last_hover_node.map(fn(d) { d.words_tabular }), Some(Some(false)))
  let last_rest_w = last_node.unwrap().w
  let last_hover_w = last_hover_node.unwrap().w
  // "fix-win-hover PR #" is 18 chars * 6pt = 108pt; squeezed below 108pt drops all trailing digits "123".
  assert_true(
    last_rest_w >= 126.0 && last_hover_w < 108.0,
    msg="expected row_time to squeeze last below 108pt: rest=\{last_rest_w}, hover=\{last_hover_w}",
  )
  let last_hover = hover_tabular_run(t, "fix-win-hover")
  assert_true(
    (last_hover.x1 - last_hover.x0 - last_hover.text.length().to_double() * 0.5 * 12.0).abs() < 0.5,
    msg="last on hover should stay non-tabular: \{last_hover.text} width=\{last_hover.x1 - last_hover.x0}",
  )
  assert_eq(t.audit(), [])
}
