///|
test "a terminal is opened as many cells as the window holds under its bar" {
  // (the code face measured as a host measures it: a Tester's)
  @ui.Tester::new(fn(_) { () }, w=390.0, h=844.0) |> ignore
  let (cols, rows) = terminal_cells(390.0, 844.0, 0.0)
  assert_true(cols >= 40 && cols <= 60, msg="\{cols} across a phone")
  assert_true(rows >= 30, msg="\{rows} down a phone")
  let (wide, _) = terminal_cells(1280.0, 800.0, 0.0)
  assert_true(wide > 2 * cols, msg="\{wide} across a wide window, \{cols} a phone's")
  // (at least 20 × 6, however small)
  assert_eq(terminal_cells(100.0, 100.0, 0.0), (20, 6))
}

///|
test "what the keyboard sends a terminal: words as they are, keys as xterm sends them, modes as bitflags" {
  let down = fn(key : String, code : String, mods : Int) -> @ui.KeyIn { Key(down=true, key~, code~, mods~) }
  assert_eq(terminal_keys_of(Text("ls -la"), false), "ls -la")
  assert_eq(terminal_keys_of(down("Enter", "Enter", 0), false), "\r")
  assert_eq(terminal_keys_of(down("Backspace", "Backspace", 0), false), "\u{7f}")
  assert_eq(terminal_keys_of(down("ArrowUp", "ArrowUp", 0), false), "\u{1b}[A")
  // (the application cursor keys, as the program asked)
  assert_eq(terminal_keys_of(down("ArrowUp", "ArrowUp", 0), true), "\u{1b}OA")
  assert_eq(terminal_keys_of(down("ArrowLeft", "ArrowLeft", @ui.key_in_ctrl), false), "\u{1b}[1;5D")
  assert_eq(terminal_keys_of(down("c", "KeyC", @ui.key_in_ctrl), false), "\u{03}")
  assert_eq(terminal_keys_of(down("b", "KeyB", @ui.key_in_alt), false), "\u{1b}b")
  assert_eq(terminal_keys_of(down("Tab", "Tab", @ui.key_in_shift), false), "\u{1b}[Z")
  assert_eq(terminal_keys_of(down("PageDown", "PageDown", 0), false), "\u{1b}[6~")
  // (⌘ with a key: this device's shortcut; a key let go: nothing)
  assert_eq(terminal_keys_of(down("v", "KeyV", @ui.key_in_meta), false), "")
  assert_eq(terminal_keys_of(Key(down=false, key="a", code="KeyA", mods=0), false), "")
  assert_true(terminal_paste_key(down("v", "KeyV", @ui.key_in_meta)))
  assert_true(terminal_paste_key(down("V", "KeyV", @ui.key_in_ctrl | @ui.key_in_shift)))
  assert_false(terminal_paste_key(down("v", "KeyV", @ui.key_in_ctrl)))
  assert_true(terminal_copy_key(down("c", "KeyC", @ui.key_in_meta)))
  assert_true(terminal_copy_key(down("C", "KeyC", @ui.key_in_ctrl | @ui.key_in_shift)))
  assert_false(terminal_copy_key(down("c", "KeyC", @ui.key_in_ctrl)))
  assert_true(terminal_select_all_key(down("a", "KeyA", @ui.key_in_meta)))
  assert_true(terminal_select_all_key(down("A", "KeyA", @ui.key_in_ctrl | @ui.key_in_shift)))
  assert_false(terminal_select_all_key(down("a", "KeyA", @ui.key_in_ctrl)))
  assert_eq(terminal_pasted_of("echo hi", false), "echo hi")
  assert_eq(terminal_pasted_of("echo hi", true), "\u{1b}[200~echo hi\u{1b}[201~")
  assert_eq(terminal_keys_of(terminal_held(Text("cd"), @ui.key_in_ctrl), false), "\u{03}d")
  assert_true(terminal_app_keys_mode(@hostapi.term_mode_decckm))
  assert_false(terminal_app_keys_mode(0))
  assert_true(terminal_bracketed_paste_mode(@hostapi.term_mode_bracketed_paste))
  assert_false(terminal_bracketed_paste_mode(0))
}

///|
test "binary host terminal: incremental dirty rows, scrollback, selection copy, and SGR mouse" {
  @ui.Tester::new(fn(_) { () }, w=390.0, h=844.0) |> ignore
  guard @hostapi.Terminal::open(40, 6) is Some(t) else { fail("expected FakeHost terminal") }
  defer t.close()
  t.write(@utf8.encode("line-1\r\nline-2\r\nline-3\r\nline-4\r\nline-5\r\nline-6\r\nline-7  \r\n中文对齐 ok"))
  let f1 = t.frame()
  assert_true(f1.length() > 42, msg="initial full frame")
  // Second frame with no output should emit 0 dirty rows (exact 42-byte header)
  let f2 = t.frame()
  assert_eq(f2.length(), 42)
  assert_eq(t.text(), "line-3\nline-4\nline-5\nline-6\nline-7\n中文对齐 ok")
  // Scroll up 2 rows into scrollback
  t.scroll(0, -2)
  assert_eq(t.modes() & @hostapi.term_mode_viewport_active, 0)
  assert_eq(t.text(), "line-1\nline-2\nline-3\nline-4\nline-5\nline-6")
  // Word select "line-2" on row 1 and copy trimmed selection
  t.select(2, 2, 1, 2, 1) |> ignore
  assert_true((t.modes() & @hostapi.term_mode_has_selection) != 0)
  assert_eq(t.text(selection_only=true), "line-2")
  // Scroll back to bottom
  t.scroll(2, 0)
  assert_true((t.modes() & @hostapi.term_mode_viewport_active) != 0)
  // Enable SGR mouse tracking (?1000h?1006h) and verify click encoding
  t.write(@utf8.encode("\u{1b}[?1000h\u{1b}[?1006h"))
  assert_true((t.modes() & @hostapi.term_mode_mouse_tracking) != 0)
  let m = @utf8.decode_lossy(t.mouse(0, 1, 0, 32, 40, 320, 120, 8, 20)[:])
  assert_eq(m, "\u{1b}[<0;5;3M")
}
