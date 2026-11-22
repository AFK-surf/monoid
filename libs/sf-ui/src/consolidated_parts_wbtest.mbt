// The library's parts made one of several (2026-11-18): a panel's switch row with its note (panel_switch_row_node's
// `note`), a row that does what cannot be undone while that is under way (link_row_node's `busy`), a bar's tool while
// what it does goes on (tool_node's `progress`), a wide button at work and under the pointer, a part that is a button
// only while something says so (button_while_node: a station's choice), each as the hand and a screen reader find it.

///|
/// A Tester of `w` by `h` (a desktop's) drawing what `make` makes in its root in the app's theme, drawn once.
fn parts_tester(w : Double, h : Double, make : (@view.View) -> Unit) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w~, h~, platform=0, tree=fn(root) { make(root) })
  // (the app's theme in the tree, its hover's ink among it)
  @ui.set_tree_theme(ui_theme_now)
  t.check_looks(false)
  t.draw()
  t
}

///|
test "a panel's switch row with a note of several lines: its switch on its title's line, never across the block" {
  let t = parts_tester(320.0, 600.0, fn(root) {
    panel_switch_row_node(root, fn() { "开机自启" }, fn() { true }, fn(_) {  }, note=fn() {
      "这台设备每次开机都会自动启动工作站并连接到工作区，关掉后要手动打开应用才会连接，期间收不到任何消息。"
    })
  })
  let s = t.get(Switch, label="开机自启")
  let (_, sy, _, sh) = s.rect
  let (_, ty, _, th) = t.rect_of("开机自启").unwrap()
  let (_, ny, _, nh) = t.rect_of("这台设备每次开机都会自动启动工作站并连接到工作区，关掉后要手动打开应用才会连接，期间收不到任何消息。").unwrap()
  // (the note on more than one line, under its title)
  assert_true(nh > th * 1.5, msg="the note on several lines: \{nh} against \{th}")
  assert_true(ny >= ty + th - 0.5, msg="the note under the title")
  // (the switch's middle on the title's line's middle, not the block's)
  let off = sy + sh / 2.0 - (ty + th / 2.0)
  assert_true(off.abs() < 1.0, msg="the switch \{off} off its title's line")
}

///|
test "a row that does what cannot be undone, busy: not done while it is under way, done once it is not" {
  let busy = @signals.signal(true)
  let done = Ref(0)
  let t = parts_tester(390.0, 300.0, fn(root) {
    link_row_node(root, fn() { "删除这台设备" }, fn() { done.val += 1 }, danger=true, acts=true, busy=fn() { busy.get() })
  })
  t.tap_text("删除这台设备")
  t.run_for(@ui.move_most_ms)
  assert_eq(done.val, 0)
  busy.set(false)
  t.draw()
  t.tap_text("删除这台设备")
  t.run_for(@ui.move_most_ms)
  assert_eq(done.val, 1)
}

///|
test "a bar's tool while what it does goes on: unable to be pressed, read out as itself; pressed again once it is over" {
  let coming : @signals.Signal[Double?] = @signals.signal(Some(0.4))
  let done = Ref(0)
  let t = parts_tester(200.0, 100.0, fn(root) {
    tool_node(
      root,
      fn() { { icon: "download", label: "下载", on: false, disabled: false } },
      fn() { page_viewer_ink() },
      Is(tool_side / 2.0),
      fn() { done.val += 1 },
      progress=fn() { coming.get() },
    )
    |> ignore
  })
  let b = t.get(Button, label="下载")
  assert_true(b.disabled, msg="unable to be pressed while it goes on")
  let (x, y, w, h) = b.rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(done.val, 0)
  coming.set(None)
  t.draw()
  assert_false(t.get(Button, label="下载").disabled)
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(done.val, 1)
}
