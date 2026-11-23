// A keyboard's bar of keys (key_pad_bar_node.mbt): its modifiers held for the next key, locked, let go; its arrows
// and ⏎ telling their keys; its row giving up its least used keys for a ⋯ that turns it to them, a modifier held
// never leaving it.

///|
test "a modifier pressed: held for the next key alone, again locked through keys, a third time let go" {
  let mods = KeyPadMods::new()
  let ctrl = 1
  let alt = 2
  mods.press(ctrl)
  assert_true(mods.holds(ctrl))
  assert_true(!mods.holds(alt))
  // (the next key takes it, and lets it go)
  assert_eq(mods.consume_once(), ctrl)
  assert_eq(mods.held_now(), 0)
  // (pressed twice: locked, a key going down after another not letting it go)
  mods.press(ctrl)
  mods.press(ctrl)
  mods.press(alt)
  assert_eq(mods.consume_once(), ctrl | alt)
  assert_eq(mods.consume_once(), ctrl)
  assert_true(mods.holds(ctrl))
  // (a third time: let go)
  mods.press(ctrl)
  assert_eq(mods.held_now(), 0)
}

///|
test "the arrows and ⏎: each tells its key; pressed, none takes the keyboard's focus" {
  let told : Array[String] = []
  let tt = u5_case(fn(root) { key_pad_dpad_node(root, 38.0, 41.0, 44.0, 86.0, fn(k) { told.push(k) }) |> ignore })
  let labels = [
    t("android-misc.screen.key.up"), t("web-pages.terminal.backspace"), t("android-misc.screen.key.left"),
    t("android-misc.screen.key.down"), t("android-misc.screen.key.right"), t("web-pages.terminal.sendCmd"),
  ]
  let took = []
  for label in labels {
    tt.click(Button, label~)
    tt.draw()
    match tt.focused() {
      Some(s) if labels.contains(s.label) => took.push(s.label)
      _ => ()
    }
  }
  assert_eq(told, ["ArrowUp", "Backspace", "ArrowLeft", "ArrowDown", "ArrowRight", "Enter"])
  assert_eq(took, [], msg=tt.focus_said())
}

///|
test "a row short of room: its least used keys leave it for ⋯, which turns the row to them; a modifier held stays" {
  let turned : @signals.Signal[Array[String]] = @signals.signal([])
  let shift = @signals.signal(false)
  let key = fn(cap : String, drop : Int) -> KeyPadKey {
    { cap, name: cap, icon: "", drop, held: None, felt: None, press: fn() {  } }
  }
  let tt = u5_case(fn(root) {
    root.box(fn(narrow) {
      narrow.width(Is(Some(200.0))) |> ignore
      key_pad_row_node(
        narrow,
        [
          key("Esc", 0),
          key("Tab", 3),
          {
            cap: "Shift",
            name: "Shift",
            icon: "",
            drop: 1,
            held: Some(fn() { shift.get() }),
            felt: None,
            press: fn() { shift.set(!shift.get()) },
          },
          key("Alt", 2),
          key("Home", 4),
          key("End", 4),
        ],
        turned,
      )
      |> ignore
    })
    |> ignore
  })
  let shown = fn(cap : String) { tt.find(cap) is Some(_) }
  // (short of room: Shift, the first to leave, gone; Esc, never)
  assert_true(shown("Esc"))
  assert_true(!shown("Shift"))
  // (⋯ turns the row to those left out: Esc no more on it)
  tt.click(Button, label=t("common.more"))
  tt.run_for(@ui.move_most_ms)
  assert_true(shown("Shift"), msg="\{Repr(turned.get())}")
  assert_true(!shown("Esc"))
  // (held, it stays on the first face too)
  tt.click(Button, label="Shift")
  turned.set([])
  tt.run_for(@ui.move_most_ms)
  assert_true(shown("Shift"))
  assert_true(shown("Esc"))
}
