// A station's terminals (the user, 2026-11-14/15): among its screens and its browser on its page, not a part of their
// own; one's page over the whole window, a viewer's bar on a wide one and a phone's on a narrow one, 接管 there while
// someone else types, its ⋯ holding 复制工作目录 and 结束会话.

///|
/// A phone's window and a wide one (corner_windows').
let terminal_windows : Array[(String, Double, Double, Int, String)] = [corner_windows[0], corner_windows[5]]

///|
test "a station's terminals are rows among its screens, 打开终端 after them; no part of their own" {
  for win in terminal_windows {
    let t = screen_in("settings-station-terminals", win, "zh")
    // (what the machine is stands over its dials in 资源 now, a line more before the screens: a phone's window shows
    // its terminals under it)
    t.wheel(win.1 / 2.0, win.2 / 2.0, 200.0)
    t.run_for(@ui.move_most_ms)
    for title in ["station", "still.fail"] {
      assert_true(t.find(title) is Some(_), msg="\{win.0}: no row \{title}")
    }
    assert_true(t.query(Radio, label="终端") is None, msg="\{win.0}: a part 终端")
    assert_true(t.query(Radio, label="概览") is Some(_), msg="\{win.0}: no 概览")
    assert_true(t.find(tr("web-pages.terminal.openRow")) is Some(_) || t.all(Link, label=tr("web-pages.terminal.openRow")).length() == 1, msg="\{win.0}: no 打开终端")
  }
}

///|
test "a terminal typed into by someone else: who, and 接管, on a wide window's bar and on a phone's" {
  for win in terminal_windows {
    let t = screen_in("terminal-taken", win, "zh")
    assert_true(t.find("左子健 正在控制") is Some(_), msg="\{win.0}: who types not said")
    t.get(Button, label=tr("android-misc.screen.takeOver")) |> ignore
    // (its screen: what the station gave, drawn)
    assert_true(t.find("import { Effect }") is Some(_), msg="\{win.0}: the screen not drawn")
    assert_true(t.find("远程终端") is Some(_), msg="\{win.0}: CJK box table not drawn")
    assert_true(t.query(Radio, label=tr("web-pages.screen.control")) is None, msg="\{win.0}: 只看/控制 left")
  }
}

///|
test "a terminal typed into here: deck has Backspace, keyboard dismiss resets kb_up, scrollback shows 回到最新, and inline 按键 keeps terminal visible" {
  let tp = screen_in("terminal", terminal_windows[0], "zh")
  tp.get(Button, label="Esc") |> ignore
  tp.get(Button, label=tr("android-misc.screen.keyboard")) |> ignore
  tp.get(Button, label=tr("web-pages.terminal.backspace")) |> ignore
  tp.get(Button, label=tr("web-pages.terminal.sendCmd")) |> ignore
  let tkb = screen_in("terminal-kb", terminal_windows[0], "zh")
  tkb.get(Button, label=tr("android-misc.screen.key.down")) |> ignore
  tkb.get(Button, label=tr("android-misc.screen.key.right")) |> ignore
  tkb.get(Button, label=tr("web-pages.terminal.backspace")) |> ignore
  tkb.get(Button, label=tr("web-pages.terminal.hideKeyboard")) |> ignore
  assert_true(tkb.key_catching(), msg="terminal-kb should catch keys")
  // Pressing Backspace on the strip must keep key_catcher focused!
  tkb.click(Button, label=tr("web-pages.terminal.backspace"))
  assert_true(tkb.key_catching(), msg="tapping strip Backspace must not blur key catcher")
  // Dismissing soft keyboard via system back (keyboard_gone) must reset kb_up back to the 2-row deck!
  tkb.keyboard_gone()
  tkb.get(Button, label=tr("android-misc.screen.keyboard")) |> ignore
  // Scrolled-up scrollback view shows 回到最新 and jumps back to bottom when clicked
  let tsc = screen_in("terminal-scrolled", terminal_windows[0], "zh")
  tsc.get(Button, label=tr("web-pages.terminal.scrollBottom")) |> ignore
  tsc.click(Button, label=tr("web-pages.terminal.scrollBottom"))
  assert_true(tsc.query(Button, label=tr("web-pages.terminal.scrollBottom")) is None, msg="回到最新 should disappear at bottom")
  for win in terminal_windows {
    let t = screen_in("terminal", win, "zh")
    assert_true(t.query(Button, label=tr("android-misc.screen.takeOver")) is None, msg="\{win.0}: 接管 while typing")
    assert_true(t.query(Button, label=tr("web-pages.screen.control")) is None, msg="\{win.0}: 控制 while typing")
    t.click(Button, label=tr("web-pages.screen.panel"))
    t.run_for(@ui.move_most_ms)
    assert_true(t.find(tr("web-pages.terminal.fit80")) is Some(_), msg="\{win.0}: no 适应 80 列 in 控制中心")
    assert_true(t.find(tr("web-pages.terminal.copyCwd")) is Some(_), msg="\{win.0}: no 复制工作目录")
    assert_true(t.find(tr("web-pages.terminal.end")) is Some(_), msg="\{win.0}: no 结束会话")
  }
  for win in terminal_windows {
    let tk = screen_in("terminal-keys", win, "zh")
    assert_true(tk.find("import { Effect }") is Some(_), msg="\{win.0}: terminal hidden while 按键 open")
    assert_true(tk.find(tr("web-pages.terminal.combo.interrupt")) is Some(_), msg="\{win.0}: no 中断 · ^C in 按键")
    assert_true(tk.find("F12") is Some(_), msg="\{win.0}: no F12 in 按键")
  }
  for win in terminal_windows {
    for dark in [false, true] {
      let te = screen_in("terminal-ended", win, "zh", dark~)
      assert_true(te.find(tr("web-pages.terminal.ended")) is Some(_), msg="\{win.0} dark=\{dark}: no 已结束 on ended terminal")
      te.get(Button, label=tr("web-pages.screen.again")) |> ignore
      assert_true(te.drawn_glass().iter().any(fn(g) { g.4 == 6 }), msg="\{win.0} dark=\{dark}: ended card draws liquid glass")
      assert_eq(te.audit(), [], msg="\{win.0} dark=\{dark}: ended card audit")
    }
  }
}
