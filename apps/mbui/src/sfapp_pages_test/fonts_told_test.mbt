// 字体's unified Popover / Sheet (精选字体 + 本机字体 + unified search + script filter toggle) on 大屏,
// plus dismiss-timing regressions: Escape, a press on the page, and pressing the trigger again then Escape.

///|
fn fonts_tester() -> @ui.Tester {
  let t = wide_tester([])
  t.host_says_finger(Some(false))
  t.set_local_fonts("[\"Menlo\",\"Avenir Next\",\"Helvetica\"]")
  t.set_local_font_info(
    "[{\"name\":\"Menlo\",\"localized\":\"Menlo\",\"mono\":true,\"serif\":false,\"cjk\":false},{\"name\":\"Avenir Next\",\"localized\":\"Avenir Next\",\"mono\":false,\"serif\":false,\"cjk\":false},{\"name\":\"Helvetica\",\"localized\":\"Helvetica\",\"mono\":false,\"serif\":false,\"cjk\":false}]",
  )
  app.nav.replace(Setting(@settings.Route::Fonts))
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// 界面西文 popover opened from its trigger, dismissed by `how` (as the host hands it on, no frame after it):
/// whether it is open then, once a frame is drawn, as its trigger opens it again and a frame after.
fn fonts_dismissed(how : (@ui.Tester) -> Unit) -> Array[Bool] raise {
  let t = fonts_tester()
  guard t.query(Button, label="界面西文") is Some(s) else { fail("no 界面西文") }
  let (x, y) = (s.rect.0 + s.rect.2 / 2.0, s.rect.1 + s.rect.3 / 2.0)
  let open = fn() { @sfpages.local_open.untracked() }
  t.tap(x, y)
  t.frame()
  let seen = [open()]
  how(t)
  seen.push(open())
  t.draw()
  seen.push(open())
  t.tap(x, y)
  t.frame()
  seen.push(open())
  t.draw()
  seen.push(open())
  seen
}

///|
test "大屏: 界面西文 popover dismissed by Escape: closed as the key is taken; the frame after closes nothing more, opened again its own" {
  assert_eq(fonts_dismissed(fn(t) { t.key_told(@ui.key_escape, 0, t.time()) }), [true, false, false, true, true])
}

///|
test "大屏: 界面西文 popover dismissed by a press on the page: closed as it goes down; the frame after closes nothing more, opened again its own" {
  let down : Array[Bool] = []
  let seen = fonts_dismissed(fn(t) {
    t.touch_at(0, 1200.0, 100.0, t.time())
    down.push(@sfpages.local_open.untracked())
    t.touch_at(2, 1200.0, 100.0, t.time())
  })
  assert_eq((down, seen), ([false], [true, false, false, true, true]))
}

///|
test "大屏: 界面西文 trigger pressed again with popover open, then Escape at once: closed as it is let go, and stays closed, a frame between or none" {
  let run = fn(frames : Bool) raise {
    button_then_escape(fonts_tester(), "界面西文", fn() { @sfpages.local_open.untracked() }, frames)
  }
  assert_eq((run(false), run(true)), ([false, false, false], [false, false, false]))
}

///|
test "大屏: clicking a font slot opens unified Popover with curated + local fonts, script filter toggle, and unified search" {
  let t = fonts_tester()
  assert_false(@sfpages.local_open.untracked())
  assert_eq(@sfpages.font_picker_open.untracked(), -1)
  // Click 界面西文 slot trigger -> opens anchored Popover with both 精选字体 and 本机字体
  t.click(Button, label="界面西文")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfpages.font_picker_open.untracked(), 0)
  assert_true(@sfpages.local_open.untracked())
  assert_true(t.find("精选字体") is Some(_))
  assert_true(t.find("本机字体") is Some(_))
  assert_true(t.query(Button, label="Inter") is Some(_))
  // Latin slot smart-filters out mono Menlo, shows Avenir Next & Helvetica
  assert_true(t.find("Avenir Next") is Some(_))
  assert_true(t.find("Menlo") is None)
  // Toggle 全部 -> reveals Menlo alongside Avenir Next
  t.click(Button, label="全部")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Menlo") is Some(_))
  // Toggle back to 仅西文 -> hides Menlo again
  t.click(Button, label="仅西文")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Menlo") is None)
  // Unified search finds local mono Menlo even when script filter was active
  // (last TextField is the popover's search bar; first is the sidebar's)
  let fields = t.semantics().filter(fn(s) { s.role is TextField })
  assert_true(fields.length() > 0)
  let (fx, fy, fw, fh) = fields[fields.length() - 1].rect
  t.tap(fx + fw / 2.0, fy + fh / 2.0)
  t.frame()
  t.type_text("Menlo")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Menlo") is Some(_))
  assert_true(t.query(Button, label="Inter") is None)
}
