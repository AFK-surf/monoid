// The app in a browser started with a finger (a phone's Safari or Chrome): its fields a finger's, as on a phone, so a
// field held offers 粘贴 (the web's host's text menu), as nothing else in a browser offers it to a finger.

///|
/// The fixture's chat on a phone's screen in a browser (4), started with `native` and pointed at with it, after the
/// app's host_setup, its composer held: whether the system text menu is up, and whether the custom liquid-glass
/// editing bar offers 粘贴.
fn web_composer_held(native : @ui.Pointing) -> (Bool, Bool) raise {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(
    fn(c) { view(c, src) },
    tree=app_tree(src),
    w=390.0,
    h=844.0,
    platform=4,
    pointing=native,
    native~,
  )
  host_setup()
  let log = t.drive("until 发消息\nhold 700 发消息\n")
  t.draw()
  t.draw()
  let (sys_shown, _, _, _, _, _) = t.text_menu()
  let paste_at = t.find(@sf.t("desktop.contextMenu.paste"))
  let paste_shown = paste_at is Some(_)
  match paste_at {
    Some((px, py)) => {
      t.clipboard_gives(" 吧")
      t.tap(px, py)
      t.draw()
      t.draw()
      assert_true(
        t.text_runs().iter().any(fn(r) { r.text.contains("吧") }),
        msg="pressing 粘贴 on the custom bar must paste into the composer",
      )
    }
    None => ()
  }
  // (the feel said for the whole run: put back for the tests after this one)
  @ui.feel_as(-1)
  assert_true(log.contains("EXIT 0"), msg=log.join("\n"))
  (sys_shown, paste_shown)
}

///|
test "a browser started with a finger: the composer, empty, held: system menu suppressed and custom bar offers 粘贴" {
  let (sys_shown, paste_shown) = web_composer_held(Finger)
  assert_false(sys_shown, msg="system text menu must stay closed when field_bar_node is mounted")
  assert_true(paste_shown, msg="custom liquid-glass bar must offer 粘贴 over the held composer")
}

///|
test "a browser started with a mouse: the composer as a desktop's, no finger's menu" {
  let (sys_shown, paste_shown) = web_composer_held(Mouse)
  assert_false(sys_shown)
  assert_false(paste_shown)
}

///|
test "chat composer finger selection shows liquid-glass editing bar, runs select all and copy, and dismisses outside" {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(
    fn(c) { view(c, src) },
    tree=app_tree(src),
    w=390.0,
    h=844.0,
    platform=2,
    pointing=Finger,
    native=Finger,
  )
  host_setup()
  let log = t.drive("until 发消息\ntap 发消息\n")
  assert_true(log.contains("EXIT 0"), msg=log.join("\n"))
  t.type_text("@[首页] 吧")
  t.draw()
  let run = t.text_runs().filter(fn(r) { r.text.contains("首页") })[0]
  let wx = run.x0 + 24.0
  let wy = (run.top + run.bottom) / 2.0
  t.press_at(wx, wy)
  t.run_for(@ui.long_press_ms + @ui.frame_period_default)
  t.release(wx, wy)
  t.run_for(@motion.pop_ms)
  assert_false(t.text_menu().0, msg="system text menu must stay closed")
  let cut_label = @sf.t("desktop.contextMenu.cut")
  let copy_label = @sf.t("desktop.contextMenu.copy")
  let select_all_label = @sf.t("desktop.contextMenu.selectAll")
  assert_true(t.find(cut_label) is Some(_))
  assert_true(t.find(copy_label) is Some(_))
  assert_true(t.find(@sf.t("desktop.contextMenu.paste")) is Some(_))
  assert_true(t.find(select_all_label) is Some(_))
  assert_eq(t.audit(), [], msg="audit faults with composer field bar open")
  // Select All -> bar stays open without Select All
  let (ax, ay) = t.find(select_all_label).unwrap()
  t.tap(ax, ay)
  t.run_for(@motion.pop_ms)
  assert_true(t.find(cut_label) is Some(_))
  assert_true(t.find(select_all_label) is None)
  // Copy -> closes bar and shows copied toast (pick the Copy button on the floating bar, not a message's Copy)
  let (_, bar_y) = t.find(cut_label).unwrap()
  let copy_run = t.text_runs().filter(fn(r) { r.text == copy_label && ((r.top + r.bottom) / 2.0 - bar_y).abs() < 24.0 })[0]
  t.tap((copy_run.x0 + copy_run.x1) / 2.0, (copy_run.top + copy_run.bottom) / 2.0)
  t.run_for(@motion.pop_out_ms)
  assert_true(t.find(cut_label) is None)
  assert_true(t.find(@sf.t("common.copied")) is Some(_))
  // Re-open via long-press and tap outside -> closes bar
  let run2 = t.text_runs().filter(fn(r) { r.text.contains("首页") })[0]
  let wx2 = run2.x0 + 24.0
  let wy2 = (run2.top + run2.bottom) / 2.0
  t.press_at(wx2, wy2)
  t.run_for(@ui.long_press_ms + @ui.frame_period_default)
  t.release(wx2, wy2)
  t.run_for(@motion.pop_ms)
  assert_true(
    t.find(cut_label) is Some(_),
    msg="menu=\{Repr(@ui.field_menu_now())} wx2=\{wx2} wy2=\{wy2}",
  )
  t.tap(195.0, 200.0)
  t.run_for(@motion.pop_out_ms)
  assert_true(t.find(cut_label) is None)
  @ui.feel_as(-1)
}
