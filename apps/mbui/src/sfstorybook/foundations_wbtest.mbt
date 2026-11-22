// The component library's page (shell.mbt) and its foundations (foundations.mbt) in a Tester: each foundation, and the
// overview, held to every rule (Tester::audit) at 小屏's width and a wide window's, at the system's words as they are
// and at 1.3; the jump (⌘K) going to the page what is typed finds; a colour copied as its tile is pressed; the colour
// theme chosen from the bar's panel.

///|
/// The page opened on `key` ("" the overview), `w` wide, pointed at with a mouse, the system's words at `scale`.
fn story_tester(key : String, w : Double, scale? : Double = 1.0, h? : Double = 900.0) -> @ui.Tester {
  // (the overview's thumbnails: the faces its avatars' parts draw, handed to the host at once)
  @ui.host_image_bytes_known([("src/sfstorybook/foundations_wbtest.mbt", 9834)])
  @sf.presenters_reset()
  let t = @ui.Tester::new(stories_view, tree=stories_tree(key), w~, h~, platform=0)
  if scale != 1.0 {
    t.set_font_scale(scale)
  }
  t.draw()
  t
}

///|
/// What the rules find on the page, but the overview's thumbnails: each a part's first state drawn in a box of its
/// height said and cut to it (overview_node's), what is cut there being what a thumbnail is.
fn page_faults(t : @ui.Tester) -> Array[String] {
  t.audit().filter(fn(f) { !f.contains("its height said") || !f.contains("sfstorybook/shell.mbt") })
}

///|
/// Whether the jump (⌘K's pick) is open: its dialog read out by its name.
fn jump_shown(t : @ui.Tester) -> Bool {
  t.query(Dialog, label="跳转到页面") is Some(_)
}

///|
test "each foundation and the overview keep every rule at 390 and 1280, at the system's words and at 1.3" {
  for key in ["", "palette", "type", "corners", "depth"] {
    for w in [390.0, 1280.0] {
      for scale in [1.0, 1.3] {
        let t = story_tester(key, w, scale~)
        let at = "\{key} at \{w}, words ×\{scale}"
        // (the overview: what the foundations' thumbnails bring; the parts' thumbnails before them are the sweeps')
        let faults = page_faults(t).filter(fn(f) { key != "" || f.contains("foundations.mbt") })
        assert_true(faults.is_empty(), msg="\{at}: \{faults.join("\n")}")
      }
    }
  }
}

///|
test "the foundations come first in the list, the parts after them" {
  let t = story_tester("", 1280.0)
  let (_, palette_y) = t.find("色板与主题色 Palette").unwrap()
  let (_, button_y) = t.find("按钮 Button").unwrap()
  assert_true(palette_y < button_y, msg="palette \{palette_y}, button \{button_y}")
  // (where the parts are, said as the library's path, no · between it and their count)
  assert_true(t.find("libs/sf-ui/src") is Some(_))
  assert_true(t.find("apps/mbui/src/sf") is None, msg="the old path")
  // (each card's group and file side by side, not joined by ·)
  assert_true(t.words().iter().all(fn(w) { !w.0.contains(" · button_node.mbt") && !w.0.contains("src/sf · ") }), msg="no words joined by ·")
}

///|
test "⌘K opens the jump, what is typed finds a page and Enter goes to it; Ctrl+K too" {
  for mods in [@ui.mod_cmd, @ui.mod_ctrl] {
    let t = story_tester("", 1280.0)
    t.key(@ui.key_of_char('k'), mods~)
    t.run_for(@ui.move_most_ms)
    assert_true(jump_shown(t), msg="\{mods}: the jump is open")
    t.type_text("同心")
    t.key(@ui.key_code_enter)
    t.run_for(@ui.move_most_ms)
    assert_true(!jump_shown(t), msg="\{mods}: closed once it went")
    // (the page's own: what it is, under the bar's name)
    assert_true(t.find("同心阶梯 Ladder") is Some(_), msg="\{mods}: on 同心圆角's page")
    let faults = page_faults(t)
    assert_true(faults.is_empty(), msg=faults.join("\n"))
  }
}

///|
test "the bar's search button opens the same jump, at 小屏's width too" {
  // (opened on a part's page: the overview's thumbnails, far down, hold an old field the a11y rule finds unnamed, the
  // sweeps' as before)
  let t = story_tester("button", 390.0)
  guard t.query(Button, label="跳转到页面") is Some(_) else { fail("no 跳转到页面: \{t.semantics_dump()}") }
  t.click(Button, label="跳转到页面")
  t.run_for(@ui.move_most_ms)
  assert_true(jump_shown(t), msg="the jump is open")
  // (小屏's: a sheet from the foot, its search over the pages; a page pressed there goes to it)
  t.type_text("字阶")
  t.run_for(@ui.move_most_ms)
  guard t.find_last("字阶与排版 Typography") is Some((x, y)) else { fail("not found: \{t.words().map(fn(w) { w.0 }).join(" | ")}") }
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("字阶 Type scale") is Some(_), msg="on 字阶's page: \{t.words().map(fn(w) { w.0 }).join(" | ")}")
}

///|
test "a colour's tile pressed puts its name and value on the clipboard and says so" {
  let t = story_tester("palette", 1280.0)
  let said = "bg " + hex_of(@sf.theme().p.bg)
  t.click(Button, label="复制 " + said)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.clipboard(), said)
}

///|
test "a colour theme chosen in the bar's panel is the one every part is drawn in at once" {
  let t = story_tester("palette", 1280.0)
  let orange = @sf.theme().p.accent
  t.click(Button, label="主题色")
  t.run_for(@ui.move_most_ms)
  t.click(Radio, label="蓝")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sf.accent_key(), "blue")
  assert_true(@sf.theme().p.accent != orange, msg="the accent is the blue's")
  let faults = page_faults(t)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}

///|
test "播放 sets both dots off at its press and they come to rest at the track's end, 放回 brings them back" {
  let t = story_tester("depth", 1280.0, h=1600.0)
  t.click(Button, label="播放")
  t.run_for(@ui.move_most_ms * 4.0)
  assert_true(t.find("放回") is Some(_))
  assert_true(t.at_rest(), msg="at rest at the end")
  t.click(Button, label="放回")
  t.run_for(@ui.move_most_ms * 4.0)
  assert_true(t.find("播放") is Some(_))
}
