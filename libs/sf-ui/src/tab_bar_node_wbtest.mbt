// The library's bar of tabs (tab_bar_node): one tab list, Tab stopping at the tab in front alone, ← → Home End bringing
// each in front; a tab's × closing it, the keyboard given to the tab then in front; Delete on a tab closing it.

///|
/// A bar of tabs `keys` (each called by its key) with the one in front `front`, at the top left of a window with
/// keyboard and mouse, after a node "别处" that takes the focus; each closed taken out of `keys`, the one in front then
/// the first left.
fn tab_bar_case(keys : @signals.Signal[Array[String]], front : @signals.Signal[String], look : TabLook) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(e) {
      e
      .width(Is(Some(40.0)))
      .height(Is(Some(40.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="别处"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    tab_bar_node(
      root,
      fn() { "标签页" },
      fn() { keys.get() },
      fn() { front.get() },
      fn(k) { front.set(k) },
      fn(k) { k },
      fn(b, k, shown) { tab_words_node(b, fn() { k }, shown) |> ignore },
      look~,
      close=fn(k) {
        let rest = keys.get().filter(fn(x) { x != k })
        if front.get() == k {
          front.set(rest.get(0).unwrap_or(""))
        }
        keys.set(rest)
      },
      close_label=fn(k) { "关闭" + k },
    )
    |> ignore
  })
  t.draw()
  t
}

///|
test "a bar of tabs: one tab list of tabs, the one in front read out selected; Tab stops at it alone, ← → Home End bring each in front" {
  for look in [Capsule, Groove, Chip] {
    let keys = @signals.signal(["一", "二", "三"])
    let front = @signals.signal("二")
    let t = tab_bar_case(keys, front, look)
    let at = "\{Repr(look)}"
    assert_eq(t.all(TabList, label="标签页").length(), 1, msg=at)
    assert_eq(t.all(Tab).length(), 3, msg=at)
    assert_eq(t.all(Tab, selected=true).map(fn(s) { s.label }), ["二"], msg=at)
    t.act(Button, Focus, label="别处")
    t.tab()
    assert_eq(t.focused().map(fn(s) { s.label }), Some("二"), msg=at)
    t.key(@ui.key_code_right)
    t.draw()
    assert_eq((front.get(), t.focused().map(fn(s) { s.label })), ("三", Some("三")), msg=at)
    t.key(@ui.key_code_home)
    t.draw()
    assert_eq(front.get(), "一", msg=at)
    t.key(@ui.key_code_end)
    t.draw()
    assert_eq(front.get(), "三", msg=at)
    t.key(@ui.key_code_left)
    t.draw()
    assert_eq(front.get(), "二", msg=at)
    // (Tab goes on past the list: its other tabs are no stops of it)
    t.tab()
    let next = t.focused().map(fn(s) { (s.role, s.label) })
    assert_true(next != Some((@view.Role::Tab, "一")) && next != Some((@view.Role::Tab, "三")), msg="\{at}: \{t.focus_said()}")
  }
}

///|
test "a bar of tabs: a tab's × closes it; the one the keyboard was on closed, the keyboard goes to the tab then in front; Delete on a tab closes it" {
  let keys = @signals.signal(["一", "二", "三"])
  let front = @signals.signal("一")
  let t = tab_bar_case(keys, front, Capsule)
  // × of one behind: it goes, the one in front stays
  t.click(Button, label="关闭二")
  t.run_for(@ui.move_most_ms)
  assert_eq((keys.get(), front.get()), (["一", "三"], "一"))
  // Delete on the one in front, the keyboard on it: it goes, the keyboard on the one then in front
  t.act(Button, Focus, label="别处")
  t.tab()
  assert_eq(t.focused().map(fn(s) { s.label }), Some("一"))
  t.key(@ui.key_code_delete)
  t.run_for(@ui.move_most_ms)
  assert_eq((keys.get(), front.get()), (["三"], "三"))
  assert_eq(t.focused().map(fn(s) { (s.role, s.label) }), Some((@view.Role::Tab, "三")), msg=t.focus_said())
}
