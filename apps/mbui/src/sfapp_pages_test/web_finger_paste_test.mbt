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
/// The lowest run of words drawn saying `words` (and `also`, where said): the composer's, under the chat's messages.
fn composer_run(t : @ui.Tester, words : String, also? : String = "") -> @ui.TextRun {
  let runs = t.text_runs().filter(fn(r) { r.text.contains(words) && r.text.contains(also) })
  let mut low = runs[0]
  for r in runs {
    if r.top > low.top {
      low = r
    }
  }
  low
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
  // (its words where they rest, the composer's change of shape as they came in over)
  t.run_for(@ui.move_most_ms)
  // (the composer's own words: what it says of the chat referred to is drawn under it too, 首页 among it)
  let run = composer_run(t, "首页", also="吧")
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
  let run2 = composer_run(t, "首页", also="吧")
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

///|
/// The fixture's chat on a phone's screen on `platform` (1 iOS, 2 Android, 4 a browser), started with `native` and
/// pointed at with `pointing`, after the app's host_setup, its composer tapped and given `words`. The Tester.
fn finger_composer(platform : Int, native : @ui.Pointing, pointing : @ui.Pointing, words : String) -> @ui.Tester raise {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform~, pointing~, native~)
  host_setup()
  let log = t.drive("until 发消息\ntap 发消息\n")
  assert_true(log.contains("EXIT 0"), msg=log.join("\n"))
  t.type_text(words)
  t.draw()
  t.run_for(@ui.double_tap_ms + 50.0)
  t
}

///|
/// The finger's ways of each host the app runs on with a finger: iOS, Android, a browser started with a finger, a
/// browser started with a mouse touched.
let finger_hosts : Array[(String, Int, @ui.Pointing, @ui.Pointing)] = [
  ("iOS", 1, Finger, Finger),
  ("Android", 2, Finger, Finger),
  ("web, a finger", 4, Finger, Finger),
  ("web, a mouse touched", 4, Mouse, Finger),
]

///|
test "a finger's tap on the composer's caret (past its words' end): the liquid-glass bar's 粘贴 and 全选, nothing picked; 粘贴 puts the words after them, none written over" {
  for host in finger_hosts {
    let (what, platform, native, pointing) = host
    let t = finger_composer(platform, native, pointing, "然后 ios")
    let run = t.text_runs().filter(fn(r) { r.text.contains("然后 ios") })[0]
    let y = (run.top + run.bottom) / 2.0
    t.tap(run.x1 + 30.0, y)
    t.run_for(@motion.pop_ms)
    let paste = @sf.t("desktop.contextMenu.paste")
    assert_true(t.find(paste) is Some(_), msg="\{what}: 粘贴 over the caret tapped")
    assert_true(t.find(@sf.t("desktop.contextMenu.selectAll")) is Some(_), msg="\{what}: 全选 over it")
    assert_true(t.find(@sf.t("desktop.contextMenu.cut")) is None, msg="\{what}: nothing picked, nothing to cut")
    assert_false(t.text_menu().0, msg="\{what}: the system's menu held off")
    assert_eq(t.audit(), [], msg="\{what}: audit with the bar up")
    t.clipboard_gives("新内容")
    let (px, py) = t.find(paste).unwrap()
    t.tap(px, py)
    t.draw()
    t.draw()
    assert_eq(t.field_words(), "然后 ios新内容", msg="\{what}: pasted after the words")
    @ui.feel_as(-1)
  }
}

///|
test "a finger held on the composer's room round its words (between ＋ and send, past the last line's end): the caret there, 粘贴, nothing picked; 粘贴 keeps the 。" {
  let words = "ios这个对话框，手机单点无法触发快捷栏，我想粘贴东西进去都做不到。"
  for host in finger_hosts {
    let (what, platform, native, pointing) = host
    let t = finger_composer(platform, native, pointing, words)
    let paste = @sf.t("desktop.contextMenu.paste")
    let cut = @sf.t("desktop.contextMenu.cut")
    // (past the last line's 。)
    let last = t.text_runs().filter(fn(r) { r.text.contains("做不到。") })[0]
    let y = (last.top + last.bottom) / 2.0
    t.press_at(last.x1 + 24.0, y)
    t.run_for(@ui.long_press_ms + @ui.frame_period_default)
    t.release(last.x1 + 24.0, y)
    t.run_for(@motion.pop_ms)
    assert_true(t.find(paste) is Some(_), msg="\{what}: 粘贴 past the 。")
    assert_true(t.find(cut) is None, msg="\{what}: the 。 not picked")
    t.tap(195.0, 200.0)
    t.run_for(@motion.pop_out_ms + @ui.double_tap_ms)
    // (between ＋ and send, under the words)
    let send = t.get(Button, label=@sf.t("web-main.composer.send")).rect
    let (sx, sy) = (send.0 - 60.0, send.1 + send.3 / 2.0)
    t.press_at(sx, sy)
    t.run_for(@ui.long_press_ms + @ui.frame_period_default)
    t.release(sx, sy)
    t.run_for(@motion.pop_ms)
    assert_true(t.find(paste) is Some(_), msg="\{what}: 粘贴 held between ＋ and send")
    assert_true(t.find(cut) is None, msg="\{what}: nothing picked there")
    assert_eq(t.audit(), [], msg="\{what}: audit with the bar up")
    t.clipboard_gives("贴")
    let (px, py) = t.find(paste).unwrap()
    t.tap(px, py)
    t.draw()
    t.draw()
    assert_eq(t.field_words(), words + "贴", msg="\{what}: pasted at the end, the 。 kept")
    @ui.feel_as(-1)
  }
}

///|
test "signed in with no workspace, asked for a code: its field tapped twice, the liquid-glass bar's 粘贴 puts the code in" {
  for host in finger_hosts {
    let (what, platform, native, pointing) = host
    new_run()
    let src = fixture("landing")
    @sfpages.landing_reset()
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform~, pointing~, native~)
    host_setup()
    t.draw()
    @sfpages.landing_asked()
    t.draw()
    let (fx, fy) = t.find("XXXX-XXXX-XXXX").unwrap()
    t.tap(fx, fy)
    t.run_for(@ui.double_tap_ms + 50.0)
    t.tap(fx, fy)
    t.run_for(@motion.pop_ms)
    let paste = @sf.t("desktop.contextMenu.paste")
    assert_true(t.find(paste) is Some(_), msg="\{what}: 粘贴 over the code's field")
    t.clipboard_gives("ABCD-EFGH-IJKL")
    let (px, py) = t.find(paste).unwrap()
    t.tap(px, py)
    t.draw()
    t.draw()
    assert_eq(t.field_words(), "ABCD-EFGH-IJKL", msg="\{what}: the code pasted")
    @ui.feel_as(-1)
  }
}
