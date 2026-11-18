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

///|
fn uprobe_b() -> @ui.Tester {
  let t = uprobe_open()
  t.drag(180.0, 600.0, 180.0, 300.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_tap(t, "人")
  t.run_for(kept_switch_over_ms)
  uprobe_tap(t, "林")
  t.run_for(kept_switch_over_ms)
  t
}

///|
test "usage probe: after a row's pick, dragged elsewhere or after another tap" {
  let t = uprobe_b()
  t.drag(180.0, 300.0, 180.0, 100.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_at(t, "B2 dragged from 300")
  t.drag(180.0, 100.0, 180.0, 500.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_at(t, "B2 dragged down from 100")
  let t = uprobe_b()
  t.tap(380.0, 30.0)
  t.run_for(kept_switch_over_ms)
  t.drag(180.0, 650.0, 180.0, 150.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_at(t, "B3 after another tap")
  let t = uprobe_b()
  t.wheel(180.0, 400.0, 300.0)
  t.run_for(kept_glide_over_ms)
  uprobe_at(t, "B4 wheel 300")
}

///|
test "usage probe: isolate" {
  // legend picked after a scroll
  let t = uprobe_open()
  t.drag(180.0, 600.0, 180.0, 450.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_at(t, "C1 scrolled 150")
  uprobe_tap(t, "Ana")
  t.run_for(kept_switch_over_ms)
  uprobe_end(t, "C1 legend after scroll")
  // a row picked unscrolled, chats tab (a chat row opens a chat: use the people tab)
  let t = uprobe_open()
  uprobe_tap(t, "人")
  t.run_for(kept_switch_over_ms)
  uprobe_at(t, "C2 people tab, top")
  uprobe_tap(t, "Ana")
  t.run_for(kept_switch_over_ms)
  uprobe_end(t, "C2 legend at top, people tab")
  // people tab, scrolled, legend's pick by setting the pick (no press)
  let t = uprobe_open()
  t.drag(180.0, 600.0, 180.0, 300.0, steps=20)
  t.run_for(kept_glide_over_ms)
  uprobe_tap(t, "人")
  t.run_for(kept_switch_over_ms)
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfpages.usage_only_for_test(("people", "lin@example.com")) })
  t.run_for(kept_switch_over_ms)
  uprobe_end(t, "C3 set, people tab, scrolled")
  let t = uprobe_open()
  t.drag(180.0, 600.0, 180.0, 300.0, steps=20)
  t.run_for(kept_glide_over_ms)
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfpages.usage_only_for_test(("people", "lin@example.com")) })
  t.run_for(kept_switch_over_ms)
  uprobe_end(t, "C4 set, chats tab, scrolled")
}
