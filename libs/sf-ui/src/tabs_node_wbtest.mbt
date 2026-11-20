// The library's tabs (tabs_node.mbt): a tab list of tabs, the chosen one read out selected and its panel the one shown;
// a press or the arrow keys choosing (or, manual, moving the focus alone till Space or Enter); a panel kept
// (keep_mounted) keeping what it holds across another's being chosen, taking no room meanwhile; the bar or the capsule
// sliding under the chosen tab, there by move_most_ms; both looks, nothing the audit finds.

///|
/// What a tabs case keeps: its window, the tab chosen (the caller's), the keys told, how many times each panel was made.
struct Tabs2 {
  t : @ui.Tester
  chosen : @signals.Signal[String]
  told : Array[String]
  made : Map[String, Int]
}

///|
/// Tabs 对话, 文件 and 任务 (对话 chosen) in a window `w` wide, each panel's words "<name>面板", `look`, `manual` and
/// `keep_mounted` as given.
fn tabs2(look? : TabsLook = Underline, manual? : Bool = false, keep_mounted? : Bool = false, w? : Double = 600.0) -> Tabs2 {
  let chosen = @signals.signal("chat")
  let told : Array[String] = []
  let made : Map[String, Int] = Map([])
  let names = [("chat", "对话"), ("files", "文件"), ("jobs", "任务")]
  let t = w2_case(w~, fn(root) {
    tabs_node(
      root,
      fn() { "页面" },
      names.map(fn(n) { (n.0, fn() { n.1 }) }),
      fn() { chosen.get() },
      fn(k) {
        told.push(k)
        chosen.set(k)
      },
      fn(p, k) {
        made[k] = made.get(k).unwrap_or(0) + 1
        let name = names.search_by(fn(n) { n.0 == k }).map(fn(i) { names[i].1 }).unwrap_or("")
        words_node(p, fn() { name + "面板" }, fn() { paragraph }) |> ignore
      },
      look~,
      manual~,
      keep_mounted~,
    )
    |> ignore
  })
  { t, chosen, told, made }
}

///|
/// The tab read out selected, and the panels read out.
fn tabs2_said(t : @ui.Tester) -> (Array[String], Array[String]) {
  (t.all(Tab, selected=true).map(fn(s) { s.label }), t.all(TabPanel).map(fn(s) { s.label }))
}

///|
/// The bar's or the capsule's place along the list and its width, as drawn: the rectangle drawn `h` high (within half
/// a point) in the tab list's band.
fn tabs2_mark(t : @ui.Tester, h : Double) -> (Int, Int) raise {
  let list = t.get(TabList, label="页面")
  match
    t
    .drawn_rects()
    .search_by(fn(r) { (r.3 - h).abs() <= 0.5 && r.1 >= list.rect.1 - 0.5 && r.1 + r.3 <= list.rect.1 + list.rect.3 + 0.5 }) {
    Some(i) => {
      let r = t.drawn_rects()[i]
      (r.0.round().to_int(), r.2.round().to_int())
    }
    None => (-1, -1)
  }
}

///|
test "tabs: the chosen one read out selected, its panel the one read out and shown; a press on another chooses it, its panel shown in place of the other; the bar under the chosen tab, there by move_most_ms; nothing the audit finds" {
  let k = tabs2()
  assert_eq(tabs2_said(k.t), (["对话"], ["对话"]))
  assert_true(k.t.rect_of("对话面板") is Some(_))
  let tab = fn(name : String) raise {
    let r = k.t.get(Tab, label=name).rect
    (r.0.round().to_int(), r.2.round().to_int())
  }
  assert_eq(tabs2_mark(k.t, tabs_bar_h), tab("对话"))
  assert_eq(k.t.audit(), [])
  k.t.click(Tab, label="任务")
  k.t.run_for(@ui.move_most_ms)
  assert_eq(tabs2_said(k.t), (["任务"], ["任务"]))
  assert_true(k.t.rect_of("对话面板") is None && k.t.rect_of("任务面板") is Some(_))
  assert_eq(tabs2_mark(k.t, tabs_bar_h), tab("任务"))
  assert_eq(k.told, ["jobs"])
  assert_eq(k.t.audit(), [])
}

///|
test "tabs, the pill look: the lifted capsule under the chosen tab, sliding to another chosen, there by move_most_ms; nothing the audit finds" {
  let k = tabs2(look=Pill)
  let tab = fn(name : String) raise {
    let r = k.t.get(Tab, label=name).rect
    (r.0.round().to_int(), r.2.round().to_int())
  }
  assert_eq(tabs2_mark(k.t, tabs_pill_h), tab("对话"))
  assert_eq(k.t.audit(), [])
  k.t.click(Tab, label="文件")
  k.t.run_for(@ui.move_most_ms)
  assert_eq(tabs2_mark(k.t, tabs_pill_h), tab("文件"))
  assert_eq(k.t.audit(), [])
}

///|
test "tabs, chosen by the keys: Tab stops at the chosen tab, → and ← choose along them round the ends, Home and End the first and last" {
  let k = tabs2()
  k.t.act(Button, Focus, label="别处")
  k.t.tab()
  let at = fn() { k.t.focused().map(fn(s) { s.label }).unwrap_or("none") }
  let first = at()
  k.t.key(@ui.key_code_right)
  let right = (at(), k.chosen.get())
  k.t.key(@ui.key_code_left)
  k.t.key(@ui.key_code_left)
  let round = (at(), k.chosen.get())
  k.t.key(@ui.key_code_home)
  let home = k.chosen.get()
  k.t.key(@ui.key_code_end)
  k.t.run_for(@ui.move_most_ms)
  assert_eq(first, "对话")
  assert_eq(right, ("文件", "files"))
  assert_eq(round, ("任务", "jobs"))
  assert_eq((home, k.chosen.get()), ("chat", "jobs"))
  assert_eq(tabs2_said(k.t), (["任务"], ["任务"]))
}

///|
test "tabs, manual: the arrow keys move the focus alone, Space or Enter choosing the tab the keyboard is on" {
  let k = tabs2(manual=true)
  k.t.act(Button, Focus, label="别处")
  k.t.tab()
  k.t.key(@ui.key_code_right)
  let moved = (k.t.focused().map(fn(s) { s.label }).unwrap_or("none"), k.chosen.get())
  k.t.key(@ui.key_space)
  let spaced = k.chosen.get()
  k.t.key(@ui.key_code_right)
  k.t.enter()
  k.t.run_for(@ui.move_most_ms)
  assert_eq(moved, ("文件", "chat"))
  assert_eq((spaced, k.chosen.get()), ("files", "jobs"))
  assert_eq(tabs2_said(k.t), (["任务"], ["任务"]))
}

///|
test "tabs, kept panels: each made once and kept as another is chosen, hidden and taking no room meanwhile; not kept, made again each time its tab is chosen" {
  let kept = tabs2(keep_mounted=true)
  kept.t.click(Tab, label="文件")
  kept.t.run_for(@ui.move_most_ms)
  kept.t.click(Tab, label="对话")
  kept.t.run_for(@ui.move_most_ms)
  assert_eq(tabs2_said(kept.t), (["对话"], ["对话"]))
  assert_eq((kept.made.get("chat"), kept.made.get("files"), kept.made.get("jobs")), (Some(1), Some(1), Some(1)))
  // (the chosen one's words where they were before another was chosen: the kept ones take no room)
  let at_first = kept.t.rect_of("对话面板").unwrap()
  assert_true(kept.t.rect_of("文件面板") is None)
  assert_eq(kept.t.audit(), [])
  let plain = tabs2()
  let plain_at = plain.t.rect_of("对话面板").unwrap()
  plain.t.click(Tab, label="文件")
  plain.t.run_for(@ui.move_most_ms)
  plain.t.click(Tab, label="对话")
  plain.t.run_for(@ui.move_most_ms)
  assert_eq((plain.made.get("chat"), plain.made.get("files"), plain.made.get("jobs")), (Some(2), Some(1), None))
  assert_eq(at_first, plain_at)
}

///|
test "tabs in a phone's width, both looks: nothing the audit finds" {
  for look in [Underline, Pill] {
    let k = tabs2(look~, w=390.0)
    assert_eq(k.t.audit(), [], msg=if look is Pill { "pill" } else { "underline" })
  }
}

///|
test "tabs_node: indicator slide animation causes zero relayout (laid == 0)" {
  for look in [Underline, Pill] {
    let k = tabs2(look~, keep_mounted=true)
    k.t.click(Tab, label="任务")
    k.t.draw()
    k.t.tree_frames_from_now()
    k.t.run_for(@ui.move_most_ms)
    for f in k.t.tree_frames() {
      assert_eq(f.laid, 0, msg="tabs_node indicator slide relaid out: \{Repr(f)}")
    }
  }
}
