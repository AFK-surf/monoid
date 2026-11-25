// A Windows window has no title bar of the system's either, nor its buttons: the app draws them (@sf.window_keys) at
// the top row's right, as still.fail's desktop app did, the maximize one's place told the host (Windows' Snap Layouts
// open from it), and what a top row holds at the window's right stands before them.

///|
/// A named button on screen by its name: where it is.
fn named_at(t : @ui.Tester, label : String) -> (Double, Double, Double, Double)? raise {
  let all = t.semantics().filter(fn(s) { !s.hidden && s.label == label && s.role is Button }).map(fn(s) { s.rect })
  if all.length() > 1 {
    fail("\{all.length()} buttons named \{label}: \{Repr(all)}")
  }
  all.get(0)
}

///|
/// The window's own buttons' names, minimize, maximize or back, close (the menu bar's and the desktop app's words).
let window_key_names : Array[String] = ["最小化", "最大化", "还原", "关闭窗口"]

///|
/// Whether any non-owner visible control, text, icon, or narrow pill overlaps the window's own buttons
/// (or violates window-keys clearance/alignment via framework `Tester::window_keys_faults`).
fn past_rule(t : @ui.Tester, x : Double) -> String? {
  ignore(x)
  let faults = t.window_keys_faults()
  if faults.is_empty() {
    None
  } else {
    Some(faults.join("\n"))
  }
}

///|
fn assert_no_wk_faults(t : @ui.Tester, at : String) -> Unit raise {
  let faults = t.window_keys_faults()
  if !faults.is_empty() {
    fail("\{at}: \{faults.length()} window_keys_faults:\n" + faults.join("\n"))
  }
}

///|
test "a Windows window laid out Large: its own buttons at the top row's right, 9 in and aligned with the top-left rail, the page's keys before their pill" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat", platform=3, window_corner=8.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  // in a liquid glass pill 9 in (symmetric 9pt top/right inset, 32pt buttons at y=11 centered at y=27 with the top-left
  // rail), its buttons 2 in and 2 apart
  guard named_at(t, "关闭窗口") is Some((cx, cy, cw, ch)) else { fail("no close button") }
  assert_eq((cx + cw, cy, cw, ch), (1269.0, 11.0, 32.0, 32.0))
  guard named_at(t, "最大化") is Some((zx, zy, _, _)) else { fail("no maximize button") }
  assert_eq((zx, zy), (cx - 34.0, 11.0))
  guard named_at(t, "最小化") is Some((mx, _, _, _)) else { fail("no minimize button") }
  assert_eq(mx, zx - 34.0)
  // the maximize one's place, the host's (the pointer there is its)
  assert_eq(t.window_snap_rect(), (zx, zy, 32.0, 32.0))
  // the chat's bar's keys before their pill (its outer edge 2 before the first)
  assert_eq(past_rule(t, mx - 2.0), None)
  // its top row drags the window but for what is pressed there, the buttons among it
  assert_true(t.drags_window_at(700.0, 22.0))
  assert_false(t.drags_window_at(cx + 16.0, 22.0))
}

///|
test "a Windows window laid out Large: a new chat's Station 文件 before the window's buttons' pill, its panel open or closed" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="newchat-files", platform=3, window_corner=8.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() == NewChat)
  guard named_at(t, "最小化") is Some((mx, _, _, _)) else { fail("no minimize button") }
  // kept open: the panel's bar's switch before them
  assert_eq(past_rule(t, mx - 2.0), None)
  // closed: 文件 at the page's end before their pill, as a chat's bar's last is (it stood under close)
  t.click(Button, label="收起侧栏")
  t.run_for(@ui.move_most_ms)
  guard named_at(t, "Station 文件") is Some((fx, _, fw, _)) else { fail("no Station 文件") }
  assert_eq(fx + fw, mx - 2.0 - 12.0)
  assert_eq(past_rule(t, mx - 2.0), None)
}

///|
test "a Windows window's buttons: minimize and close do what the window's do; maximize as the host says the pointer stands on it" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, platform=3, window_corner=8.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  guard named_at(t, "最小化") is Some((mx, my, mw, mh)) else { fail("no minimize button") }
  t.tap(mx + mw / 2.0, my + mh / 2.0)
  guard named_at(t, "关闭窗口") is Some((cx, cy, cw, ch)) else { fail("no close button") }
  t.tap(cx + cw / 2.0, cy + ch / 2.0)
  assert_eq(t.window_acts(), [1, 3])
  // the pointer on maximize, then pressing it, as the host says: lit, then held down (its press the host's)
  t.set_window_snap(1)
  t.run_for(@sf.dur_ms)
  t.set_window_snap(2)
  t.run_for(@sf.dur_ms)
  t.set_window_snap(0)
  // maximized, its button the one bringing it back
  t.set_window_zoomed(true)
  t.frame()
  assert_true(named_at(t, "还原") is Some(_))
  assert_true(named_at(t, "最大化") is None)
}

///|
test "a Windows window laid out Small: its buttons in the band over the page; on the tape, on its line, the strip at the right holding them" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, w=390.0, h=844.0, platform=3, window_corner=8.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  guard named_at(t, "关闭窗口") is Some((cx, cy, cw, _)) else { fail("no close button") }
  assert_eq((cx + cw, cy), (379.0, 11.0))
  // nothing of the page's in the band (54) under them
  for s in t.semantics() {
    let (_, sy, _, sh) = s.rect
    if !s.hidden && s.label != "" && !window_key_names.contains(s.label) && sy + sh > 0.0 && sy < 54.0 {
      fail("\{s.label} in the band of the window's buttons")
    }
  }
  // laid out Medium: on the tape's line, concentric with the top right corner of the panel at the window's edge (its
  // 28, 6 in: 18; the pill round them concentric with it too), the sidebar in use and the page's strip at the right as
  // wide as holds them (their pill on it, its edge 6 past that)
  let t = wide_tester(calls, mode="chat", w=690.0, h=840.0, platform=3, window_corner=8.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  guard named_at(t, "关闭窗口") is Some((cx, cy, cw, _)) else { fail("no close button") }
  let line = @sf.window_in + @sf.tape_line
  assert_eq((cx + cw, cy), (690.0 - line, line))
  guard named_at(t, "最小化") is Some((mx, _, _, _)) else { fail("no minimize button") }
  assert_true((@sfdesk.tape_shows_right() - (690.0 - (mx - 2.0) + 6.0)).abs() < 1.0e-9)
  // the page's panel brought over: where they are the same, its bar's keys before them
  t.tap(650.0, 400.0)
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(named_at(t, "关闭窗口").map(fn(r) { (r.0 + r.2, r.1) }), Some((690.0 - line, line)))
  assert_eq(past_rule(t, mx - 2.0), None)
}

///|
test "a Windows window: the top row drags it on every page but for what is pressed there, its own buttons among that" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, platform=3, window_corner=8.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  row_drags(t, "新建对话", 400.0)
  let t = wide_tester(calls, mode="chat", platform=3, window_corner=8.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  row_drags(t, "a chat", 400.0)
  let t = wide_tester(calls, platform=3, window_corner=8.0, window_inset=true)
  app.nav.replace(Files)
  t.run_for(@ui.move_most_ms)
  row_drags(t, "文件", 400.0)
  let t = wide_tester(calls, platform=3, window_corner=8.0, window_inset=true)
  t.key(@ui.key_of_char(','), mods=@ui.mod_cmd)
  t.run_for(@ui.move_most_ms)
  row_drags(t, "settings", 400.0)
}

///|
/// `mode` in a Windows window `w` wide laid out Medium, its buttons the app's in its top row, the page come over on the
/// tape: how far before minimize the last of the bar at the window's right, said as `last`, ends.
fn tape_bar_short_of_keys(mode : String, last : String, w : Double) -> Double raise {
  let src : Ref[Source?] = Ref(None)
  let made = fn() {
    match src.val {
      Some(s) => s
      None => {
        let s = fixture_app(mode)
        src.val = Some(s)
        s
      }
    }
  }
  let t = @ui.Tester::new(
    fn(c) { view(c, made()) },
    tree=fn(root) { app_tree(made())(root) },
    w~,
    h=840.0,
    platform=3,
    window_corner=8.0,
    window_inset=true,
  )
  t.run_for(@ui.move_most_ms)
  assert_true(@sfdesk.wide.tape.get(), msg="\{mode} at \{w}: not on the tape")
  if !(@sfdesk.wide.tape_at.get() is Page) {
    page_over(t, w)
  }
  guard named_at(t, "最小化") is Some((mx, _, _, _)) else { fail("\{mode} at \{w}: no minimize button") }
  let at = t.semantics().filter(fn(s) { !s.hidden && s.label == last }).map(fn(s) { s.rect })
  guard at is [(x, y, kw, kh)] && y + kh / 2.0 < @sf.window_keys_band + @sf.window_in else {
    fail("\{mode} at \{w}: \{last} not one in the top row: \{Repr(at)}")
  }
  mx - (x + kw)
}

///|
test "a Windows window laid out Medium: a settings page's bar made as nodes ends as far before the window's buttons as a chat's bar (连接, 用量, 归档建议)" {
  // (the window's corner its tree's as the bar's node binds its end, not the old views' read where none builds: its
  // last stood against their rule)
  for w in [720.0, 600.0] {
    // (打开侧栏 sits inside a 2pt-padded liquid glass capsule, so compare the capsule's outer right edge)
    let chat = tape_bar_short_of_keys("chat", "打开侧栏", w) - 2.0
    for page in [("settings-connects", "添加连接"), ("settings-usage", "7 天 30 天 累计"), ("settings-completion", "重新发现模型")] {
      let short = tape_bar_short_of_keys(page.0, page.1, w)
      assert_true(
        (short - chat).abs() < 1.0e-9,
        msg="\{page.0} at \{w}: \{page.1} ends \{short} before minimize, a chat's bar's last \{chat}",
      )
    }
  }
}

///|
/// A button's x coordinate in `t.semantics()`, if exactly one visible button has `label`.
fn button_x_opt(t : @ui.Tester, label : String) -> Double? {
  let all = t.semantics().filter(fn(s) { !s.hidden && s.label == label && s.role is Button }).map(fn(s) { s.rect.0 })
  if all.length() == 1 {
    Some(all[0])
  } else {
    None
  }
}

///|
/// Whether a persistent chat bar action button (`归档`, `对话信息`, `更多`, `Station 文件`) in the top bar band reaches
/// past `x` (buttons inside `.clips(true)` sliding/leaving containers still appear at unclipped layout rects in
/// `t.semantics()`, so during a slide we check persistent chat bar keys here and clipped panel content via
/// `top_glyph_seen_past`, while asserting full `past_rule(t, x) == None` at every rest state).
fn chat_bar_past_rule(t : @ui.Tester, x : Double) -> String? {
  for s in t.semantics() {
    let (sx, sy, sw, sh) = s.rect
    if !s.hidden &&
      (s.label == "归档" || s.label == "对话信息" || s.label == "更多" || s.label == "Station 文件") &&
      (s.role is Button) &&
      sy >= 0.0 &&
      sy + sh <= 60.0 &&
      sx + sw > x {
      return Some(s.label)
    }
  }
  None
}

///|
/// Whether any visible (unoccluded, post-clip) text glyph in the top bar band (`y1 <= 44`) extends past `x`.
fn top_glyph_seen_past(t : @ui.Tester, x : Double) -> Double? {
  for g in t.glyphs_seen() {
    let (gx0, gy0, gx1, gy1) = g
    if gy0 >= 0.0 && gy1 <= 44.0 && gx1 > gx0 && gy1 > gy0 && gx1 > x + 0.5 {
      return Some(gx1)
    }
  }
  None
}

///|
test "a Windows window laid out Large: chat side panel open, close and interrupted slide keep bar keys monotonic and clear of window keys" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat", platform=3, window_corner=8.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  guard named_at(t, "最小化") is Some((mx, _, _, _)) else { fail("no minimize button") }
  let limit = mx - 2.0
  assert_eq(past_rule(t, limit), None)
  guard button_x_opt(t, "更多") is Some(more0) else { fail("no 更多 button") }
  guard button_x_opt(t, "对话信息") is Some(info0) else { fail("no 对话信息 button") }

  // 1) Open side panel: every frame clear of window keys, 更多 & 对话信息 monotonically move left
  let open_faults : Array[String] = []
  let open_more : Array[Double] = [more0]
  let open_info : Array[Double] = [info0]
  t.each_frame(
    Some(fn() {
      if chat_bar_past_rule(t, limit) is Some(lbl) {
        open_faults.push("open t=\{t.time()} past_rule=\{lbl}")
      }
      if top_glyph_seen_past(t, limit) is Some(r) {
        open_faults.push("open t=\{t.time()} glyph_right=\{r} > \{limit}")
      }
      if button_x_opt(t, "更多") is Some(x) {
        open_more.push(x)
      }
      if button_x_opt(t, "对话信息") is Some(x) {
        open_info.push(x)
      }
    }),
  )
  t.click(Button, label="打开侧栏")
  t.run_for(@ui.move_most_ms * 2.0)
  t.each_frame(None)
  assert_eq(open_faults, [])
  assert_eq(past_rule(t, limit), None)
  assert_true(open_more.length() >= 2 && open_more[open_more.length() - 1] < more0 - 50.0, msg="open_more=\{Repr(open_more)}")
  for i in 1..<open_more.length() {
    assert_true(
      open_more[i] <= open_more[i - 1] + 0.5,
      msg="open 更多 moved right at frame \{i}: \{open_more[i - 1]} -> \{open_more[i]} (all=\{Repr(open_more)})",
    )
  }
  for i in 1..<open_info.length() {
    assert_true(
      open_info[i] <= open_info[i - 1] + 0.5,
      msg="open 对话信息 moved right at frame \{i}: \{open_info[i - 1]} -> \{open_info[i]} (all=\{Repr(open_info)})",
    )
  }

  // 2) Close side panel: every frame clear of window keys, 更多 & 对话信息 monotonically return right to exact start
  let close_faults : Array[String] = []
  let close_more : Array[Double] = [open_more[open_more.length() - 1]]
  let close_info : Array[Double] = [open_info[open_info.length() - 1]]
  t.each_frame(
    Some(fn() {
      if chat_bar_past_rule(t, limit) is Some(lbl) {
        close_faults.push("close t=\{t.time()} past_rule=\{lbl}")
      }
      if top_glyph_seen_past(t, limit) is Some(r) {
        close_faults.push("close t=\{t.time()} glyph_right=\{r} > \{limit}")
      }
      if button_x_opt(t, "更多") is Some(x) {
        close_more.push(x)
      }
      if button_x_opt(t, "对话信息") is Some(x) {
        close_info.push(x)
      }
    }),
  )
  t.click(Button, label="收起侧栏")
  t.run_for(@ui.move_most_ms * 2.0)
  t.each_frame(None)
  assert_eq(close_faults, [])
  assert_eq(past_rule(t, limit), None)
  for i in 1..<close_more.length() {
    assert_true(
      close_more[i] >= close_more[i - 1] - 0.5,
      msg="close 更多 moved left at frame \{i}: \{close_more[i - 1]} -> \{close_more[i]} (all=\{Repr(close_more)})",
    )
  }
  for i in 1..<close_info.length() {
    assert_true(
      close_info[i] >= close_info[i - 1] - 0.5,
      msg="close 对话信息 moved left at frame \{i}: \{close_info[i - 1]} -> \{close_info[i]} (all=\{Repr(close_info)})",
    )
  }
  assert_true((close_more[close_more.length() - 1] - more0).abs() < 0.5, msg="close 更多 ended at \{close_more[close_more.length() - 1]}, expected \{more0}")
  assert_true((close_info[close_info.length() - 1] - info0).abs() < 0.5, msg="close 对话信息 ended at \{close_info[close_info.length() - 1]}, expected \{info0}")

  // 3) Interrupted open -> close mid-flight: every frame clear of window keys and returns cleanly
  let mid_faults : Array[String] = []
  t.each_frame(
    Some(fn() {
      if chat_bar_past_rule(t, limit) is Some(lbl) {
        mid_faults.push("mid t=\{t.time()} past_rule=\{lbl}")
      }
      if top_glyph_seen_past(t, limit) is Some(r) {
        mid_faults.push("mid t=\{t.time()} glyph_right=\{r} > \{limit}")
      }
    }),
  )
  t.click(Button, label="打开侧栏")
  t.run_for(@ui.move_most_ms / 3.0)
  // (at 1/3 of the slide, 收起侧栏 is clipped clear of window keys; interrupt via panel.close / Escape)
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms * 2.0)
  t.each_frame(None)
  assert_eq(mid_faults, [])
  assert_eq(past_rule(t, limit), None)
  guard button_x_opt(t, "更多") is Some(more_end) else { fail("no 更多 after interrupt") }
  assert_true((more_end - more0).abs() < 0.5, msg="interrupt 更多 ended at \{more_end}, expected \{more0}")
}

///|
test "a Windows window laid out Large: new chat Station 文件 side panel close and reopen keep bar keys clear of window keys" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="newchat-files", platform=3, window_corner=8.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  guard named_at(t, "最小化") is Some((mx, _, _, _)) else { fail("no minimize button") }
  let limit = mx - 2.0
  assert_eq(past_rule(t, limit), None)
  let faults : Array[String] = []
  t.each_frame(
    Some(fn() {
      if chat_bar_past_rule(t, limit) is Some(lbl) {
        faults.push("t=\{t.time()} past_rule=\{lbl}")
      }
      if top_glyph_seen_past(t, limit) is Some(r) {
        faults.push("t=\{t.time()} glyph_right=\{r} > \{limit}")
      }
    }),
  )
  t.click(Button, label="收起侧栏")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(past_rule(t, limit), None)
  t.click(Button, label="Station 文件")
  t.run_for(@ui.move_most_ms * 2.0)
  t.each_frame(None)
  assert_eq(faults, [])
  assert_eq(past_rule(t, limit), None)
}

///|
test "a Windows window laid out Large narrow (overlay panel): chat bar keys stay clear of window keys while panel opens and closes" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, w=960.0, h=800.0, mode="chat", platform=3, window_corner=8.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  guard named_at(t, "最小化") is Some((mx, _, _, _)) else { fail("no minimize button") }
  let limit = mx - 2.0
  assert_eq(past_rule(t, limit), None)
  let faults : Array[String] = []
  t.each_frame(
    Some(fn() {
      if chat_bar_past_rule(t, limit) is Some(lbl) {
        faults.push("t=\{t.time()} past_rule=\{lbl}")
      }
      if top_glyph_seen_past(t, limit) is Some(r) {
        faults.push("t=\{t.time()} glyph_right=\{r} > \{limit}")
      }
    }),
  )
  t.click(Button, label="打开侧栏")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(past_rule(t, limit), None)
  t.click(Button, label="收起侧栏")
  t.run_for(@ui.move_most_ms * 2.0)
  t.each_frame(None)
  assert_eq(faults, [])
  assert_eq(past_rule(t, limit), None)
}

///|
test "a Windows window laid out Medium: chat side panel open and close keep bar keys and panel switch clear of window keys" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, w=800.0, h=800.0, mode="chat", platform=3, window_corner=8.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  page_over(t, 800.0)
  guard named_at(t, "最小化") is Some((mx, _, _, _)) else { fail("no minimize button") }
  let limit = mx - 2.0
  assert_eq(past_rule(t, limit), None)
  let faults : Array[String] = []
  t.each_frame(
    Some(fn() {
      if chat_bar_past_rule(t, limit) is Some(lbl) {
        faults.push("t=\{t.time()} past_rule=\{lbl}")
      }
      if top_glyph_seen_past(t, limit) is Some(r) {
        faults.push("t=\{t.time()} glyph_right=\{r} > \{limit}")
      }
    }),
  )
  t.click(Button, label="打开侧栏")
  t.run_for(@ui.move_most_ms * 2.0)
  guard named_at(t, "收起侧栏") is Some((cx, _, cw, _)) else { fail("no 收起侧栏 on Medium panel") }
  assert_true(cx + cw <= limit, msg="Medium panel 收起侧栏 at \{cx + cw} > \{limit}")
  assert_eq(past_rule(t, limit), None)
  t.click(Button, label="收起侧栏")
  t.run_for(@ui.move_most_ms * 2.0)
  t.each_frame(None)
  assert_eq(faults, [])
  assert_eq(past_rule(t, limit), None)
}

///|
test "window_keys_node: inset toggle, window resize, and lone_window_tree update window_snap_rect and window_acts cleanly" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat", platform=3, window_corner=8.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  guard named_at(t, "最大化") is Some((zx0, zy0, _, _)) else { fail("no maximize button at 1280") }
  assert_eq(t.window_snap_rect(), (zx0, zy0, 32.0, 32.0))

  // Resize window: buttons and window_snap_rect follow immediately
  t.resize(960.0, 800.0)
  t.frame()
  guard named_at(t, "最大化") is Some((zx1, zy1, _, _)) else { fail("no maximize button at 960") }
  assert_true((zx1 - (zx0 - 320.0)).abs() < 1.0e-9, msg="expected zx1=\{zx0 - 320.0}, got \{zx1}")
  assert_eq(t.window_snap_rect(), (zx1, zy1, 32.0, 32.0))

  // Toggle window_keys_own_now off via set_window_inset(false): buttons vanish and snap rect clears
  t.set_window_inset(false)
  t.frame()
  assert_eq(named_at(t, "最小化"), None)
  assert_eq(named_at(t, "最大化"), None)
  assert_eq(named_at(t, "关闭窗口"), None)
  assert_eq(t.window_snap_rect(), (0.0, 0.0, 0.0, 0.0))

  // Toggle back on: buttons return and snap rect is restored
  t.set_window_inset(true)
  t.frame()
  guard named_at(t, "最大化") is Some((zx2, zy2, _, _)) else { fail("no maximize button after inset restored") }
  assert_eq(t.window_snap_rect(), (zx2, zy2, 32.0, 32.0))

  // Standalone lone_window_tree on narrow width: whole=true keeps buttons on bar_keys_top and reports snap rect + acts
  let src = fixture_app("chat")
  let t2 = @ui.Tester::new(
    fn(c) { lone_view(c, src) },
    tree=lone_window_tree(src, 1),
    w=600.0,
    h=700.0,
    platform=3,
    window_corner=8.0,
    window_inset=true,
  )
  t2.run_for(@ui.move_most_ms)
  guard named_at(t2, "关闭窗口") is Some((cx, cy, cw, ch)) else { fail("lone: no close button") }
  assert_eq((cx + cw, cy, cw, ch), (589.0, 11.0, 32.0, 32.0))
  guard named_at(t2, "最大化") is Some((zx, zy, zw, zh)) else { fail("lone: no maximize button") }
  assert_eq(t2.window_snap_rect(), (zx, zy, 32.0, 32.0))
  guard named_at(t2, "最小化") is Some((mx, my, mw, mh)) else { fail("lone: no minimize button") }
  t2.tap(mx + mw / 2.0, my + mh / 2.0)
  t2.tap(zx + zw / 2.0, zy + zh / 2.0)
  t2.tap(cx + cw / 2.0, cy + ch / 2.0)
  assert_eq(t2.window_acts(), [1, 2, 3])
}

///|
/// The liquid glass pill holding the window's own buttons in the last frame: the one glass 104 by 36 round them.
fn window_keys_pill(t : @ui.Tester) -> (Double, Double, Double, Double, Int)? raise {
  guard named_at(t, "关闭窗口") is Some((cx, cy, cw, ch)) else { fail("no close button") }
  let around = t
    .drawn_glass()
    .filter(fn(g) { g.0 <= cx && g.0 + g.2 >= cx + cw && g.1 <= cy && g.1 + g.3 >= cy + ch && g.3 < 60.0 })
  match around {
    [] => None
    [g] => Some((g.0, g.1, g.2, g.3, g.4))
    _ => fail("\{around.length()} glasses round the window's buttons: \{Repr(around)}")
  }
}

///|
/// The outside shadows (sigma, dy, colour) cast round `rect` (Tester::drawn_instances: a blurred shape, kind 2, outside).
fn window_keys_shadows(t : @ui.Tester, rect : (Double, Double, Double, Double)) -> Array[(Double, Double, Int64)] {
  let ch = fn(v : Double) { (v * 255.0).round().to_int64() }
  let (x, y, w, h) = rect
  let out : Array[(Double, Double, Int64)] = []
  for a in t.drawn_instances() {
    if a.length() > 13 &&
      a[5] == 2.0 &&
      a[12] == 1.0 &&
      (a[0] - x).abs() < 4.0 &&
      (a[1] - y).abs() < 4.0 &&
      (a[2] - w).abs() < 4.0 &&
      (a[3] - h).abs() < 4.0 {
      out.push((a[7], a[13], (ch(a[8]) << 24) | (ch(a[9]) << 16) | (ch(a[10]) << 8) | ch(a[11])))
    }
  }
  out
}

///|
/// The faults of the frame's corner rule and audit made by the window's own buttons or their pill (what the rest of the
/// screen shows has its own: the screen sweeps').
fn window_keys_faults(t : @ui.Tester) -> Array[String] {
  let ours = fn(f : String) {
    f.contains("window_keys_node.mbt") ||
    f.contains("bar_pill_group_node.mbt") ||
    window_key_names.iter().any(fn(n) { f.contains("「\{n}」") })
  }
  t.corner_faults().filter(ours) + t.audit().filter(ours)
}

///|
test "a Windows window's buttons in one liquid glass pill: 104 by 36 round them, its outside shadow, no rule, at every size, light and dark; solid without glass" {
  for win in [("大屏", 1280.0, 800.0), ("中屏", 800.0, 800.0), ("小屏", 390.0, 844.0)] {
    for dark in [false, true] {
      let at = "\{win.0} \{if dark { "dark" } else { "light" }}"
      let calls : Array[Made] = []
      let t = wide_tester(calls, mode="chat", w=win.1, h=win.2, platform=3, window_corner=8.0, window_inset=true)
      t.set_dark(dark)
      t.run_for(@ui.move_most_ms)
      guard window_keys_pill(t) is Some((gx, gy, gw, gh, kind)) else { fail("\{at}: no glass round the buttons") }
      assert_eq((kind, gw, gh), (6, 104.0, 36.0), msg=at)
      guard named_at(t, "最小化") is Some((mx, my, _, _)) else { fail("\{at}: no minimize button") }
      assert_eq((mx - 2.0, my - 2.0), (gx, gy), msg=at)
      assert_eq(window_keys_shadows(t, (gx, gy, gw, gh)), [@sf.glass_control_shadow()], msg=at)
      let rule = t.drawn_rects().filter(fn(r) { r.2 <= 1.5 && r.3 >= 10.0 && r.1 < 50.0 && r.0 > gx - 20.0 })
      assert_eq(rule.length(), 0, msg="\{at}: a rule \{Repr(rule)}")
      assert_eq(window_keys_faults(t), [], msg=at)
      // MBUI_GLASS=solid: the panel's ground and edge, no glass round them
      @ui.set_glass_solid(Some(true))
      t.frame()
      let solid = window_keys_pill(t)
      // (a ground of its own, opaque, not the neutral panel's of the bar's pills beside it)
      let ground = @sf.panel_ground()
      let has_ground = t
        .drawn_rects()
        .iter()
        .any(fn(r) { r.4 != ground && (r.4 & 0xFFL) == 0xFFL && r.2 == 104.0 && r.3 == 36.0 })
      let faults = window_keys_faults(t)
      @ui.set_glass_solid(None)
      assert_eq((solid, has_ground, faults), (None, true, []), msg="\{at} solid")
    }
  }
}

///|
test "a Windows window's buttons pressed, maximize held down as the host says: their pill springs and settles back" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat", platform=3, window_corner=8.0, window_inset=true)
  t.run_for(@ui.move_most_ms)
  let width = fn() raise {
    guard window_keys_pill(t) is Some((_, _, w, _, _)) else { fail("no glass round the buttons") }
    w
  }
  assert_eq(width(), 104.0)
  for label in ["最小化", "关闭窗口"] {
    guard named_at(t, label) is Some((x, y, w, h)) else { fail("no \{label}") }
    t.press_at(x + w / 2.0, y + h / 2.0)
    t.run_for(@sf.dur_ms * 2.0)
    assert_true(width() > 104.0 * 1.01, msg="\{label} pressed: pill \{width()} across")
    t.release(x + w / 2.0, y + h / 2.0)
    t.run_for(@ui.move_most_ms)
    assert_true((width() - 104.0).abs() < 0.3, msg="\{label} let go: pill \{width()} across")
  }
  assert_eq(t.window_acts(), [1, 3])
  t.set_window_snap(2)
  t.run_for(@sf.dur_ms * 2.0)
  assert_true(width() > 104.0 * 1.01, msg="maximize held: pill \{width()} across")
  t.set_window_snap(0)
  t.run_for(@ui.move_most_ms)
  assert_true((width() - 104.0).abs() < 0.3, msg="maximize let go: pill \{width()} across")
  t.assert_idle()
}

///|
test "a Windows window in Light mode: window_keys_node uses adaptive glass and adaptive icon ink with symmetric 9pt top/right margin across chat, previews, and player" {
  for mode in ["chat", "chat-preview-video", "chat-preview-image", "player-video"] {
    let t = if mode == "chat-preview-image" {
      desk_tester(mode, platform=3, window_corner=8.0, window_inset=true)
    } else {
      let calls : Array[Made] = []
      wide_tester(calls, mode~, w=1280.0, h=800.0, platform=3, window_corner=8.0, window_inset=true)
    }
    t.set_dark(false)
    t.run_for(@ui.move_most_ms)
    guard named_at(t, "关闭窗口") is Some((cx, cy, cw, ch)) else { fail("\{mode}: no close button") }
    let pills = t
      .drawn_glass()
      .filter(fn(g) { g.0 <= cx && g.0 + g.2 >= cx + cw && g.1 <= cy && g.1 + g.3 >= cy + ch && g.4 == 6 })
    guard pills is [(gx, gy, gw, gh, kind, _)] else { fail("\{mode}: expected 1 liquid pill round close, got \{Repr(pills)}") }
    assert_eq((kind, gw, gh), (6, 104.0, 36.0), msg=mode)
    assert_eq((gy, 1280.0 - (gx + gw)), (9.0, 9.0), msg=mode)
    let has_adaptive_glass = t
      .drawn_instances()
      .iter()
      .any(fn(a) {
        a.length() > 14 &&
        a[5] == 6.0 &&
        (a[0] - gx).abs() < 0.5 &&
        (a[1] - gy).abs() < 0.5 &&
        (a[2] - 104.0).abs() < 0.01 &&
        (a[3] - 36.0).abs() < 0.01 &&
        a[14] < -0.5
      })
    let has_adaptive_icon = t
      .drawn_instances()
      .iter()
      .any(fn(a) {
        a.length() > 23 &&
        a[5] == 11.0 &&
        a[0] >= gx &&
        a[0] + a[2] <= gx + gw &&
        a[1] >= gy &&
        a[1] + a[3] <= gy + gh &&
        a[23] > 0.0
      })
    assert_eq((has_adaptive_glass, has_adaptive_icon, window_keys_faults(t)), (true, true, []), msg=mode)
  }
}

///|
#callsite(autofill(loc))
fn wk_mode_tester(
  mode : String,
  w~ : Double,
  h~ : Double,
  window_inset? : Bool = true,
  loc~ : SourceLoc,
) -> @ui.Tester {
  let src : Ref[Source?] = Ref(None)
  let made = fn() {
    match src.val {
      Some(s) => s
      None => {
        let s = fixture_app(mode)
        src.val = Some(s)
        s
      }
    }
  }
  @ui.Tester::new(
    fn(c) { view(c, made()) },
    tree=fn(root) { app_tree(made())(root) },
    w~,
    h~,
    platform=3,
    window_corner=8.0,
    window_inset~,
    loc~,
  )
}

///|
test "window_keys_faults: place-remote (desktop screen, simulator, terminal) on Large and Medium Windows" {
  for win in [("Large", 1280.0, 800.0), ("Medium-600", 600.0, 760.0), ("Medium-800", 800.0, 800.0)] {
    let t = wk_mode_tester("place-remote", w=win.1, h=win.2)
    t.run_for(@ui.move_most_ms)
    if @sfdesk.wide.tape.get() && !(@sfdesk.wide.tape_at.get() is Page) {
      page_over(t, win.1)
    }
    assert_no_wk_faults(t, "place-remote desktop \{win.0}")
    // Switch to simulator tab ("iPhone 17 Pro") and assert zero faults (no silent skip)
    if @sfdesk.wide.tape.get() {
      @sfdesk.wide.tape_ask.set(Some(Side))
      t.run_for(@ui.move_most_ms)
    }
    t.click(Link, label="iPhone 17 Pro")
    t.run_for(@ui.move_most_ms)
    if @sfdesk.wide.tape.get() && !(@sfdesk.wide.tape_at.get() is Page) {
      page_over(t, win.1)
    }
    assert_no_wk_faults(t, "place-remote simulator \{win.0}")
    // Open a terminal tab in place-remote via Willow's "+" menu -> "新建终端"
    // (remote screens intentionally catch Ctrl+T after #8708 once focused).
    if @sfdesk.wide.tape.get() {
      @sfdesk.wide.tape_ask.set(Some(Side))
      t.run_for(@ui.move_most_ms)
    }
    t.click(Button, label="在 Willow 新建视图")
    t.run_for(@ui.move_most_ms)
    t.tap_text("新建终端")
    t.run_for(@ui.move_most_ms)
    if @sfdesk.wide.tape.get() && !(@sfdesk.wide.tape_at.get() is Page) {
      page_over(t, win.1)
    }
    assert_true(named_at(t, "粘贴") is Some(_), msg="place-remote 新建终端 did not open Terminal tab (\{win.0})")
    assert_no_wk_faults(t, "place-remote terminal \{win.0}")
  }
}

///|
test "window_keys_faults: files-tree on Large and Medium Windows" {
  for win in [("Large", 1280.0, 800.0), ("Medium", 600.0, 760.0)] {
    let t = wk_mode_tester("files-tree", w=win.1, h=win.2)
    t.run_for(@ui.move_most_ms)
    if @sfdesk.wide.tape.get() && !(@sfdesk.wide.tape_at.get() is Page) {
      page_over(t, win.1)
    }
    assert_no_wk_faults(t, "files-tree \{win.0}")
  }
}

///|
test "window_keys_faults: board and board_beside on Large Windows" {
  let t = wk_mode_tester("board", w=1280.0, h=800.0)
  t.run_for(@ui.move_most_ms)
  assert_no_wk_faults(t, "board Large")
  let t_side = wk_mode_tester("board-side", w=1280.0, h=800.0)
  t_side.run_for(@ui.move_most_ms)
  assert_no_wk_faults(t_side, "board-side Large")
}

///|
test "window_keys_faults: Large narrow pane (880x800) settings sub-page aligns back bar and clears window keys" {
  let t = wk_mode_tester("settings-completion", w=880.0, h=800.0)
  t.run_for(@ui.move_most_ms)
  // Verify the pushed settings sub-page rendered in Narrow look with its back bar and zero window-keys faults
  assert_true(t.find("归档建议") is Some(_))
  assert_no_wk_faults(t, "880x800 settings-completion")
}

///|
test "window_keys_faults: Medium place_bare and Medium full-window Screen, Terminal, DriveRead, DrivePlay" {
  for mode in ["settings-connects", "settings-usage", "screen-live", "screen-full", "terminal", "reader", "player-video"] {
    let t = wk_mode_tester(mode, w=680.0, h=800.0)
    t.run_for(@ui.move_most_ms)
    assert_no_wk_faults(t, "Medium \{mode}")
  }
}

///|
test "window_keys_faults: terminal in-app fullscreen exit button on Large and Medium Windows" {
  for win in [("Large", 1280.0, 800.0), ("Medium", 800.0, 800.0)] {
    let t = wk_mode_tester("terminal", w=win.1, h=win.2)
    t.run_for(@ui.move_most_ms)
    assert_no_wk_faults(t, "terminal normal \{win.0}")
    t.click(Button, label="控制中心")
    t.run_for(@ui.move_most_ms)
    t.click(Button, label="全屏")
    t.run_for(@ui.move_most_ms)
    assert_true(named_at(t, "退出全屏") is Some(_), msg="terminal fullscreen exit button missing (\{win.0})")
    assert_no_wk_faults(t, "terminal fullscreen \{win.0}")
  }
}

///|
test "window_keys_faults: Medium single-service side panel path clears window keys without wasting chat bar width" {
  let t = wk_mode_tester("chat-service-side", w=800.0, h=800.0)
  t.run_for(@ui.move_most_ms)
  if !(@sfdesk.wide.tape_at.get() is Page) {
    page_over(t, 800.0)
  }
  assert_no_wk_faults(t, "Medium chat-service-side (Page)")
  // With the side panel open on the right, the chat bar must NOT double-reserve window_keys_room_tape (#7752):
  // restrict to chat-bar buttons left of `kx` (excluding any peeking side-panel buttons) and assert the trailing gap
  // to `kx` stays within 48 pt (catching the ~116-120 pt double-reserved dead zone).
  guard named_at(t, "最小化") is Some((min_x, _, _, _)) else { fail("chat-service-side: no minimize button") }
  let kx = min_x - 2.0
  let mut right_most = 0.0
  for s in t.semantics() {
    let (sx, sy, sw, sh) = s.rect
    if !s.hidden &&
      !window_key_names.contains(s.label) &&
      (s.role is Button) &&
      sy >= 20.0 &&
      sy + sh <= 72.0 &&
      sx + sw <= kx + 0.5 {
      if sx + sw > right_most {
        right_most = sx + sw
      }
    }
  }
  assert_true(
    right_most >= kx - 48.0,
    msg="Medium chat bar over-reserved trailing space (> 48 pt) when side panel is open: right_most=\{right_most}, kx=\{kx}",
  )
  @sfdesk.wide.tape_ask.set(Some(Panel))
  t.run_for(@ui.move_most_ms * 2.0)
  assert_no_wk_faults(t, "Medium chat-service-side (Panel)")
}

///|
test "window_keys_faults: Small 390x844 and real lone_window_tree Screen window pass with zero faults" {
  let t_small = wk_mode_tester("chat", w=390.0, h=844.0)
  t_small.run_for(@ui.move_most_ms)
  assert_no_wk_faults(t_small, "Small 390x844")
  let t_main = wk_mode_tester("place-remote", w=1280.0, h=800.0)
  t_main.set_window_opens(true)
  t_main.set_windows_in_process(true)
  t_main.run_for(@ui.move_most_ms)
  assert_true(
    @sfbase.open_window(Screen({ station: "ws1/st1", screen: "display:0", title: "桌面", until_gone: false })),
    msg="failed to open in-process lone_window_tree screen",
  )
  t_main.run_for(@ui.move_most_ms)
  assert_eq(t_main.windows_beside().length(), 1)
  let (wid, _) = t_main.windows_beside()[0]
  t_main.set_window_beside_size(wid, 800.0, 720.0)
  t_main.set_window_inset_of(wid, true)
  t_main.run_for(@ui.move_most_ms)
  let lone_center : Ref[Bool] = Ref(false)
  let lone_close : Ref[Bool] = Ref(false)
  let lone_faults : Ref[Array[String]] = Ref([])
  t_main.in_window(wid, fn() {
    lone_center.val = t_main.semantics().any(fn(s) { !s.hidden && s.label == "控制中心" })
    lone_close.val = t_main.semantics().any(fn(s) { !s.hidden && s.label == "关闭窗口" })
    lone_faults.val = t_main.window_keys_faults()
  })
  assert_true(lone_center.val, msg="lone_window_tree screen controls missing")
  assert_true(lone_close.val, msg="lone_window_tree window keys missing")
  assert_eq(lone_faults.val, [], msg="lone_window_tree screen faults")
}

///|
test "window_keys_faults: reactive toggle set_window_inset(false) -> true updates bars and clears faults" {
  let t = wk_mode_tester("place-remote", w=1280.0, h=800.0, window_inset=false)
  t.run_for(@ui.move_most_ms)
  assert_no_wk_faults(t, "inset false")
  assert_eq(named_at(t, "关闭窗口"), None)
  t.set_window_inset(true)
  t.run_for(@ui.move_most_ms)
  assert_true(named_at(t, "关闭窗口") is Some(_))
  assert_no_wk_faults(t, "inset toggled true")
}
