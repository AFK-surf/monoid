///|
fn uprobe_at(t : @ui.Tester, tag : String) -> Unit {
  let ys = ["折合费用 · 近 7 天", "花费明细", "今天", "只看 Ana", "只看 林", "整理发布清单", "已删除的对话（14 个）", "林 · Opus 5.5 · Willow", "$50", "$118"].map(fn(w) {
    match t.rect_of(w) {
      Some(r) => "\{w}@\{r.1}+\{r.3}"
      None => "\{w}:none"
    }
  })
  println("probe \{tag}: \{ys.join(" | ")}")
}

///|
fn uprobe_tap(t : @ui.Tester, words : String) -> Unit {
  match t.words().iter().find_first(fn(w) { w.0 == words && w.2 > 60.0 && w.2 < 740.0 }) {
    Some(w) => t.tap(w.1 + 4.0, w.2 + 4.0)
    None => println("probe: no \{words} on screen")
  }
}

///|
fn uprobe_end(t : @ui.Tester, tag : String) -> Unit {
  for _ in 0..<3 {
    t.drag(180.0, 650.0, 180.0, 150.0, steps=20)
    t.run_for(kept_glide_over_ms)
  }
  uprobe_at(t, tag + " (at its end)")
}

///|
fn uprobe_open() -> @ui.Tester {
  new_run()
  let src = fixture("home")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  bars_picked.set(Some(([kept_bar], 0)))
  t.run_for(kept_switch_over_ms)
  kept_go(t, "usage", true)
  t.run_for(kept_switch_over_ms)
  t
}

///|
test "usage probe: a person picked in the legend" {
  let t = uprobe_open()
  uprobe_at(t, "L opened")
  uprobe_end(t, "L none picked")
  let t = uprobe_open()
  uprobe_tap(t, "Ana")
  t.run_for(kept_switch_over_ms)
  uprobe_at(t, "L Ana picked")
  uprobe_end(t, "L Ana picked")
  t.drag(180.0, 250.0, 180.0, 550.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_at(t, "L Ana picked, back up 300")
  uprobe_tap(t, "只看 Ana")
  t.run_for(kept_switch_over_ms)
  uprobe_end(t, "L let go")
}

///|
test "usage probe: a person picked in the breakdown" {
  let t = uprobe_open()
  t.drag(180.0, 600.0, 180.0, 300.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_tap(t, "人")
  t.run_for(kept_switch_over_ms)
  uprobe_at(t, "B people tab")
  uprobe_tap(t, "林")
  t.run_for(kept_switch_over_ms)
  uprobe_at(t, "B 林 picked")
  uprobe_end(t, "B 林 picked")
}
