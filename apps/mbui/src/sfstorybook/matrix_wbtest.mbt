// The workbench (matrix.mbt) in a Tester: the bar's 环境 panel switching the size of words, the current input and the
// language at once and 恢复默认 putting them back; the state matrix held to every rule at 小屏's width and a wide
// window's, at each size of words, input and language, as MBUI_FONT_SCALE, MBUI_POINTING and MBUI_LANG start it.

///|
/// What the workbench chose put back as the system's, so that no other test starts under it.
fn env_put_back() -> Unit {
  @ui.set_font_scale(None)
  @ui.set_pointing(None)
  @sf.set_language(None)
}

///|
/// The page opened on `key`, `w` wide, started by the workbench's settings `env` (MBUI_FONT_SCALE and the like).
fn env_tester(key : String, w : Double, env : Array[(String, String)], native? : @ui.Pointing) -> @ui.Tester {
  @sf.presenters_reset()
  let t = @ui.Tester::new(stories_view, tree=stories_tree(key), w~, h=900.0, platform=0, env~, native?)
  t.draw()
  t
}

///|
/// What every rule finds on the page, its corners and what is beside what among them.
fn env_faults(t : @ui.Tester) -> Array[String] {
  page_faults(t) + t.corner_faults() + t.beside_faults()
}

///|
test "环境 switches the size of words, the input and the language at once, and 恢复默认 puts them back" {
  for w in [390.0, 1280.0] {
    let t = story_tester("button", w)
    let (_, _, w1, h1) = t.rect_of("按钮 Button").unwrap()
    t.click(Button, label="环境")
    t.run_for(@ui.move_most_ms)
    t.click(Radio, label="1.3×")
    t.run_for(@ui.move_most_ms)
    assert_true((@ui.font_scale() - 1.3).abs() < 0.001, msg="\{w}: \{@ui.font_scale()}")
    let (_, _, w2, h2) = t.rect_of("按钮 Button").unwrap()
    // (on one line cut short: taller as its words grow, as wide as the bar leaves it where that is less than they need)
    assert_true(h2 > h1 && w2 >= w1, msg="\{w}: at 1.3, \{w1}×\{h1} → \{w2}×\{h2}")
    let open = page_faults(t)
    assert_true(open.is_empty(), msg="\{w}, 环境 open at 1.3: \{open.join("\n")}")
    t.click(Radio, label="2.0×")
    t.run_for(@ui.move_most_ms)
    let (_, _, _, h3) = t.rect_of("按钮 Button").unwrap()
    assert_true(h3 > h2, msg="\{w}: at 2.0, \{h2} → \{h3}")
    t.click(Radio, label="触屏")
    t.run_for(@ui.move_most_ms)
    assert_true(@ui.pointing() is Finger, msg="\{w}: pointed at with a finger")
    t.click(Radio, label="English")
    t.run_for(@ui.move_most_ms)
    assert_eq(@sf.language(), "en")
    // (closed, the bar's button says what is chosen: its words where the bar has the room, its name for a screen
    // reader)
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
    // (at 2× words the library's segmented draws its words taller than its track: its own, seg_node.mbt's, not the
    // workbench's, as the panel's three are)
    let faults = page_faults(t).filter(fn(f) { !f.contains("ui/src/controls/seg_node.mbt") })
    assert_true(faults.is_empty(), msg="\{w} at 2.0: \{faults.join("\n")}")
    assert_true(t.query(Button, label="2.0× · 触屏 · EN") is Some(_), msg="\{w}: \{t.semantics_dump()}")
    t.click(Button, label="2.0× · 触屏 · EN")
    t.run_for(@ui.move_most_ms)
    t.click(Button, label="恢复默认")
    t.run_for(@ui.move_most_ms)
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
    assert_true((@ui.font_scale() - 1.0).abs() < 0.001, msg="\{w}: back to \{@ui.font_scale()}")
    assert_true(@ui.pointing() is Mouse, msg="\{w}: the system's mouse again")
    assert_eq(@sf.language(), "zh")
    assert_true(t.query(Button, label="环境") is Some(_), msg="\{w}: named 环境 again")
    let (_, _, w4, h4) = t.rect_of("按钮 Button").unwrap()
    assert_true((w4 - w1).abs() < 0.01 && (h4 - h1).abs() < 0.01, msg="\{w}: \{w1}×\{h1} again, \{w4}×\{h4}")
    env_put_back()
  }
}

///|
test "the state matrix keeps every rule at 390 and 1280, at 1.0, 1.3 and 2.0, with a mouse in Chinese and a finger in English" {
  // (at 2× words, what the page round it brings at 1280 is the library's own (its segmented's words taller than its
  // track, the side's title on two lines): held to the matrix's alone there)
  for w in [390.0, 1280.0] {
    let mut last_h = 0.0
    for scale in ["1.0", "1.3", "2.0"] {
      for hand in [("mouse", "zh"), ("finger", "en")] {
        let env = [("MBUI_FONT_SCALE", scale), ("MBUI_POINTING", hand.0), ("MBUI_LANG", hand.1)]
        let t = env_tester("matrix", w, env)
        let at = "matrix at \{w}, words ×\{scale}, \{hand.0}, \{hand.1}"
        assert_true(t.find("状态矩阵 State matrix") is Some(_), msg=at)
        // (the library's own word, in the language chosen)
        let cancel = if hand.1 == "en" { "Cancel" } else { "取消" }
        assert_true(t.find(cancel) is Some(_), msg="\{at}: \{cancel}")
        assert_true(t.query(Switch, label="开着的开关") is Some(_), msg=at)
        let faults = env_faults(t).filter(fn(f) { scale != "2.0" || w < 720.0 || f.contains("matrix.mbt") })
        assert_true(faults.is_empty(), msg="\{at}: \{faults.join("\n")}")
        // (its words measured larger as the size goes up)
        let (_, _, _, h) = t.rect_of("按钮各状态 Button states").unwrap()
        assert_true(h >= last_h, msg="\{at}: \{last_h} → \{h}")
        last_h = h
        env_put_back()
      }
    }
  }
}

///|
test "the overview and a part's page started at 1.3 with a finger in English keep every rule the workbench brings" {
  // (the overview's thumbnails: the faces its avatars' parts draw, handed to the host at once)
  @ui.host_image_bytes_known([("src/sfstorybook/matrix_wbtest.mbt", 9834)])
  for key in ["", "button"] {
    for w in [390.0, 1280.0] {
      let t = env_tester(key, w, [("MBUI_FONT_SCALE", "1.3"), ("MBUI_POINTING", "finger"), ("MBUI_LANG", "en")])
      let at = "\{key} at \{w}"
      assert_true((@ui.font_scale() - 1.3).abs() < 0.001, msg=at)
      assert_true(@ui.pointing() is Finger, msg=at)
      // (what the bar and the workbench's own page bring: the parts' thumbnails are the sweeps')
      let faults = env_faults(t).filter(fn(f) { f.contains("shell.mbt") || f.contains("matrix.mbt") })
      assert_true(faults.is_empty(), msg="\{at}: \{faults.join("\n")}")
      assert_true(t.query(Button, label="1.3× · 触屏 · EN") is Some(_), msg="\{at}: \{t.semantics_dump()}")
      t.click(Button, label="1.3× · 触屏 · EN")
      t.run_for(@ui.move_most_ms)
      let opened = env_faults(t).filter(fn(f) { f.contains("shell.mbt") || f.contains("matrix.mbt") })
      assert_true(opened.is_empty(), msg="\{at}, 环境 open: \{opened.join("\n")}")
      env_put_back()
    }
  }
}

///|
test "a finger's native input draws the matrix's controls at its sizes, a mouse's at its own" {
  let mouse = env_tester("matrix", 1280.0, [], native=Mouse)
  let m = mouse.get(Switch, label="开着的开关").rect
  let finger = env_tester("matrix", 1280.0, [], native=Finger)
  let f = finger.get(Switch, label="开着的开关").rect
  assert_true(f.2 > m.2, msg="a finger's switch wider: \{m.2} → \{f.2}")
  let faults = env_faults(finger)
  assert_true(faults.is_empty(), msg=faults.join("\n"))
}
