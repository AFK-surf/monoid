// 用量's breakdown with one person picked (只看 X), the person's view answered late by the core's client, as a device's
// is: the breakdown card closes its way as its old rows go and comes back with the answer, its first value told as an
// answer (@view.answering), while that way still closes. It takes its room whole then: the note under it under its last
// row, never drawn over the card, the page as long as all of it (an iPhone, beta 78: the note over 花费明细, the page
// not scrolling to the card's foot).

///|
test "用量: a person picked in the breakdown, their view answered late, the card takes its room whole" {
  for case in [(2, 0.0), (2, 100.0), (2, 400.0), (1, 0.0), (1, 100.0)] {
    let (platform, ms) = case
    new_run()
    let src = @sffixture.round_trip_again(fixture("home"), 0.0, late=fn(name, params) {
      if name == "usage" && params.get("only") is Some(_) { ms } else { 0.0 }
    })
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform~, scale=3.0)
    t.set_rows_on_pixels(true)
    bars_picked.set(Some(([kept_bar], 0)))
    t.run_for(kept_switch_over_ms)
    kept_go(t, "usage", true)
    t.run_for(kept_switch_over_ms)
    only_late_tap(t, "人")
    t.run_for(kept_switch_over_ms)
    for _ in 0..<3 {
      t.drag(180.0, 650.0, 180.0, 250.0, steps=20)
      t.run_for(kept_glide_over_ms)
    }
    only_late_tap(t, "陈")
    t.run_for(kept_glide_over_ms)
    // (scrolled on to the page's end: the card's last row and the note under it both there to see)
    for _ in 0..<3 {
      t.drag(180.0, 650.0, 180.0, 150.0, steps=20)
      t.run_for(kept_glide_over_ms)
    }
    let at = "platform \{platform}, answered after \{ms} ms"
    let row = t.rect_of("2 个对话 · 52 次调用 · 最多 Haiku 5")
    let note = t.rect_of("按各服务商公开的 API 价格折算，不是实际账单。")
    match (row, note) {
      (Some(r), Some(n)) =>
        assert_true(n.1 >= r.1 + r.3 + 16.0, msg="\{at}: the card's last row at \{r.1}+\{r.3}, the note under it at \{n.1}")
      _ => fail("\{at}: the last row at \{row.map(@ui.rect_text).unwrap_or("none")}, the note at \{note.map(@ui.rect_text).unwrap_or("none")}")
    }
  }
}

///|
fn only_late_tap(t : @ui.Tester, words : String) -> Unit raise {
  match t.words().iter().find_first(fn(w) { w.0 == words && w.2 > 60.0 && w.2 < 740.0 }) {
    Some(w) => t.tap(w.1 + 4.0, w.2 + 4.0)
    None => fail("no \{words} on screen")
  }
}
