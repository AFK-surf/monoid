// The library's keys and round tools (key_cap_node.mbt): a terminal's key pressed leaving the keyboard's focus where
// it was; a key that repeats pressed again while held and not as it is let go; a modifier read out pressed while held.

///|
test "a key that steals no focus: pressed, it takes no focus, and Tab passes it by" {
  let pressed = Ref(0)
  let t = u5_case(fn(root) {
    key_cap_node(root, "Esc", fn() { "Esc" }, fn() { pressed.val += 1 }, look=Tile, width=56.0, height=42.0, steals_focus=false)
    |> ignore
  })
  t.click(Button, label="Esc")
  t.draw()
  let after_press = t.focused().map(fn(s) { s.label })
  t.act(Button, Focus, label="别处")
  t.tab()
  assert_eq(pressed.val, 1)
  assert_true(after_press != Some("Esc"), msg=t.focus_said())
  assert_true(t.focused().map(fn(s) { s.label }) != Some("Esc"), msg=t.focus_said())
}

///|
test "a key that repeats: held, pressed at 400 ms and every 45 ms after; let go then, not pressed again" {
  let pressed = Ref(0)
  let t = u5_case(fn(root) {
    key_cap_node(root, "←", fn() { "左" }, fn() { pressed.val += 1 }, look=Tile, width=42.0, height=42.0, steals_focus=false, repeat=true)
    |> ignore
  })
  let (x, y) = t.find("←").unwrap()
  // (a millisecond either side of the hold's moment, then two repeats' worth past it)
  let a_ms = 1.0
  t.press_at(x, y)
  t.run_for(key_repeat_after - a_ms)
  let before = pressed.val
  t.run_for(a_ms * 2.0)
  let at_hold = pressed.val
  t.run_for(key_repeat_every * 2.0)
  let after = pressed.val
  t.release(x, y)
  t.run_for(key_repeat_every * 4.0)
  assert_eq((before, at_hold, after, pressed.val), (0, 1, 3, 3))
  // (a tap: pressed once)
  t.click(Button, label="左")
  t.draw()
  assert_eq(pressed.val, 4)
}

///|
test "a modifier's key: read out pressed while held, a press turning it" {
  let held = @signals.signal(false)
  let t = u5_case(fn(root) {
    key_cap_node(root, "⇧", fn() { "Shift" }, fn() { held.set(!held.get()) }, held=fn() { held.get() }) |> ignore
  })
  assert_eq(t.get(Button, label="Shift").pressed, Some(false))
  t.click(Button, label="Shift")
  t.draw()
  assert_eq(t.get(Button, label="Shift").pressed, Some(true))
}

///|
test "a round tool: a button by its name, pressed once a press" {
  let pressed = Ref(0)
  let t = u5_case(fn(root) {
    tool_round_node(root, "shrink", fn() { "退出全屏" }, fn() { pressed.val += 1 }, look=Floating) |> ignore
  })
  t.click(Button, label="退出全屏")
  t.draw()
  assert_eq(pressed.val, 1)
}
