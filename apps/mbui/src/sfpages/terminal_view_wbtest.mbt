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
test "what the keyboard sends a terminal: words as they are, keys as xterm sends them" {
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
  assert_eq(terminal_pasted_of("echo hi", false), "echo hi")
  assert_eq(terminal_pasted_of("echo hi", true), "\u{1b}[200~echo hi\u{1b}[201~")
  assert_eq(terminal_keys_of(terminal_held(Text("cd"), @ui.key_in_ctrl), false), "\u{03}d")
  assert_true(terminal_app_keys("{\"cols\":80,\"rows\":24,\"cursor\":[0,0,true],\"keys\":1,\"lines\":[]}"))
  assert_false(terminal_app_keys("{\"cols\":80,\"rows\":24,\"cursor\":[0,0,true],\"keys\":0,\"lines\":[]}"))
  assert_true(terminal_bracketed_paste("{\"cols\":80,\"rows\":24,\"cursor\":[0,0,true],\"keys\":0,\"paste\":1,\"lines\":[]}"))
  assert_false(terminal_bracketed_paste("{\"cols\":80,\"rows\":24,\"cursor\":[0,0,true],\"keys\":0,\"paste\":0,\"lines\":[]}"))
  assert_eq(
    terminal_plain_text("{\"cols\":80,\"rows\":24,\"lines\":[[[\"ls\", \"\", \"\", 0], [\" -la\", \"\", \"\", 0]], []]}"),
    "ls -la",
  )
}
