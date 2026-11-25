// A station's screen with keyboard and mouse (screen_view.mbt's viewer bar, screen_stage.mbt's screen_mouse), as the
// web's page has it on a computer: the viewer's bar across the window's top and the picture under it, nothing a
// phone's hand needs; the mouse the screen's pointer where it is, the keyboard its own once it is pressed, ⌘V this
// device's clipboard pasted there, 全屏 the window's.

///|
/// The viewer in a computer's window, a moment after it opened (正在连接 said by then, the frame round it still).
fn mouse_rig() -> ScreenRig {
  let r = screen_rig(w=1280.0, h=800.0, platform=0)
  r.t.run_for(@sf.later_ms)
  r
}

///|
/// The test's end with a mouse: the pointer gone from the window (no tip coming over what it rested on, nothing it
/// lit still lit), the frame round the screen at rest.
fn mouse_done(r : ScreenRig) -> Unit {
  r.t.leave()
  r.t.run_for(@headless.tooltip_delay_ms)
  let rest = r.t.rest_of("Anim")
  if rest > r.t.time() {
    r.t.run_for(rest - r.t.time())
  }
  screen_done(r.t)
}

///|
test "with keyboard and mouse: the viewer's bar across the top, the picture under it, nothing a finger needs; back closes it" {
  let r = mouse_rig()
  r.live()
  assert_true(r.t.find("still.fail — Chrome") is Some(_))
  assert_true(r.t.find("控制 · 李雷也在看") is Some(_))
  assert_true(r.labelled(tr("common.back")) is Some(_))
  // one row (2026-11-13): how the link goes only while it is poor, 只看 in 控制中心
  assert_true(r.labelled(tr("web-pages.screen.stats")) is None)
  assert_true(r.labelled(tr("web-pages.screen.panel")) is Some(_))
  assert_true(r.labelled(tr("web-pages.screen.combos")) is Some(_))
  assert_true(r.labelled("控制") is None)
  // none of a phone's: its ×, the keyboard to raise, the trackpad, 按键, the paste button, the keys row
  assert_true(r.labelled("关闭") is None)
  assert_true(r.labelled("键盘") is None)
  assert_true(r.labelled("触控板") is None)
  assert_true(r.labelled(tr("web-pages.screen.keysPanel")) is None)
  assert_true(r.labelled("粘贴手机剪贴板") is None)
  assert_true(r.labelled("Esc") is None)
  // the picture under the bar, the window's width
  let u = r.ui()
  assert_true(u.stage_xy().1 >= @sf.viewer_bar_h)
  assert_eq(u.box_w.get(), 1280.0)
  assert_eq(r.t.squeeze_faults(), [])
  r.tap_label(tr("common.back"))
  nav_rested(r.t)
  assert_true(!(app.nav.top() is Screen(_)))
  r.t.draw()
  mouse_done(r)
}

///|
test "a mouse is the screen's pointer where it is: moved over the picture, clicked there, dragged held, right clicked, its wheel" {
  let r = mouse_rig()
  r.live(others=[])
  // moved over the picture: the screen's pointer goes there, no button held
  let (mx, my) = r.at(0.25, 0.5)
  r.t.move_to(mx, my)
  let ins = r.inputs()
  assert_eq(ins.length(), 1)
  assert_eq(kind_of_input(ins[0]), "move")
  assert_eq(number(Some(ins[0]), "buttons"), 0.0)
  assert_true(close_to(number(Some(ins[0]), "x"), 0.25))
  assert_true(close_to(number(Some(ins[0]), "y"), 0.5))
  // still: nothing more
  r.t.draw()
  assert_eq(r.inputs().length(), 1)
  // clicked: down and up with the primary button where it was clicked
  r.tap_at(0.75, 0.25)
  let click = r.inputs()[1:].to_owned()
  assert_eq(click.length(), 2)
  assert_eq(kind_of_input(click[0]), "down")
  assert_eq(number(Some(click[0]), "buttons"), 1.0)
  assert_true(close_to(number(Some(click[0]), "x"), 0.75))
  assert_true(close_to(number(Some(click[0]), "y"), 0.25))
  assert_eq(kind_of_input(click[1]), "up")
  // the press gave it the keyboard
  assert_true(r.t.key_catching())
  // dragged: down where it began, moves with the button held, up where it was let go
  let from = r.inputs().length()
  let (ax, ay) = r.at(0.2, 0.6)
  let (bx, by) = r.at(0.6, 0.6)
  r.t.drag(ax, ay, bx, by)
  let drag = r.inputs()[from:].to_owned()
  assert_eq(kind_of_input(drag[0]), "down")
  assert_true(close_to(number(Some(drag[0]), "x"), 0.2))
  let moves = drag.filter(fn(j) { kind_of_input(j) == "move" })
  assert_true(moves.length() >= 2)
  assert_true(moves.iter().all(fn(j) { number(Some(j), "buttons") == 1.0 }))
  let up = drag[drag.length() - 1]
  assert_eq(kind_of_input(up), "up")
  assert_true(close_to(number(Some(up), "x"), 0.6))
  // right clicked: down and up with the secondary button there
  let from = r.inputs().length()
  let (rx, ry) = r.at(0.4, 0.4)
  r.t.move_to(rx, ry)
  r.t.right_click(rx, ry)
  let right = r.inputs()[from:].to_owned().filter(fn(j) { kind_of_input(j) != "move" })
  assert_eq(right.length(), 2)
  assert_eq(kind_of_input(right[0]), "down")
  assert_eq(number(Some(right[0]), "buttons"), 2.0)
  assert_true(close_to(number(Some(right[0]), "x"), 0.4))
  assert_eq(kind_of_input(right[1]), "up")
  // the wheel where the mouse is, in pixels
  r.t.wheel_with(rx, ry, 0.0, 120.0, 0)
  let wheel = r.inputs().last().unwrap()
  assert_eq(text(Some(wheel), "t"), "wheel")
  assert_eq(number(Some(wheel), "dy"), 120.0)
  assert_true(close_to(number(Some(wheel), "x"), 0.4))
  // a trackpad's pinch zooms nothing there
  let before = r.inputs().length()
  r.t.wheel_with(rx, ry, 0.0, 30.0, @ui.wheel_mod_pinch)
  assert_eq(r.inputs().length(), before)
  mouse_done(r)
}

///|
test "a click with ⇧ or ⌘ held is one there: their keys go down before it and up after it" {
  let r = mouse_rig()
  r.live(others=[])
  r.t.hold_mods(@ui.mod_shift_key)
  r.tap_at(0.5, 0.5)
  r.t.hold_mods(0)
  let ins = r.inputs()
  assert_eq(ins.length(), 4)
  assert_eq(text(Some(ins[0]), "code"), "ShiftLeft")
  assert_eq(kind_of_input(ins[0]), "down")
  assert_eq(kind_of_input(ins[1]), "down")
  assert_eq(text(Some(ins[1]), "t"), "pointer")
  assert_eq(kind_of_input(ins[2]), "up")
  assert_eq(text(Some(ins[3]), "code"), "ShiftLeft")
  assert_eq(kind_of_input(ins[3]), "up")
  // each key's own event says what is held after it: ⇧'s down with it, its up without
  assert_eq(number(Some(ins[0]), "mods"), mod_shift.to_double())
  assert_eq(number(Some(ins[3]), "mods"), 0.0)
  // ⌘ and ⇧: down one more each, up one fewer each
  let from = r.inputs().length()
  r.t.hold_mods(@ui.mod_cmd | @ui.mod_shift_key)
  r.tap_at(0.5, 0.5)
  r.t.hold_mods(0)
  let keys = r.inputs()[from:].to_owned().filter(fn(j) { text(Some(j), "t") == "key" })
  assert_eq(keys.map(fn(k) { text(Some(k), "code") }), ["MetaLeft", "ShiftLeft", "MetaLeft", "ShiftLeft"])
  assert_eq(keys.map(fn(k) { kind_of_input(k) }), ["down", "down", "up", "up"])
  assert_eq(keys.map(fn(k) { number(Some(k), "mods") }), [4.0, 12.0, 8.0, 0.0])
  mouse_done(r)
}

///|
test "a wheel with ⌘ or ⇧ held is one there: their keys go down before it and up after it; a pinch said as ⌃ alone goes bare" {
  let r = mouse_rig()
  r.live(others=[])
  let (mx, my) = r.at(0.4, 0.4)
  r.t.move_to(mx, my)
  let from = r.inputs().length()
  r.t.hold_mods(@ui.mod_cmd)
  r.t.wheel_with(mx, my, 0.0, -120.0, @ui.wheel_mod_cmd)
  r.t.hold_mods(0)
  let zoom = r.inputs()[from:].to_owned()
  assert_eq(zoom.map(fn(j) { text(Some(j), "t") }), ["key", "wheel", "key"])
  assert_eq(text(Some(zoom[0]), "code"), "MetaLeft")
  assert_eq(kind_of_input(zoom[0]), "down")
  assert_eq(number(Some(zoom[0]), "mods"), mod_meta.to_double())
  assert_eq(number(Some(zoom[1]), "dy"), -120.0)
  assert_true(close_to(number(Some(zoom[1]), "x"), 0.4))
  assert_eq(text(Some(zoom[2]), "code"), "MetaLeft")
  assert_eq(kind_of_input(zoom[2]), "up")
  assert_eq(number(Some(zoom[2]), "mods"), 0.0)
  // ⇧: sideways on the station as here
  let from = r.inputs().length()
  r.t.hold_mods(@ui.mod_shift_key)
  r.t.wheel_with(mx, my, 0.0, 60.0, @ui.wheel_mod_shift)
  r.t.hold_mods(0)
  let side = r.inputs()[from:].to_owned()
  assert_eq(side.map(fn(j) { text(Some(j), "code") }), ["ShiftLeft", "", "ShiftLeft"])
  // a host that says a trackpad's pinch is a wheel with ⌃, no key held: no ⌃ made of it
  let from = r.inputs().length()
  r.t.wheel_with(mx, my, 0.0, 30.0, @ui.wheel_mod_ctrl)
  let bare = r.inputs()[from:].to_owned()
  assert_eq(bare.map(fn(j) { text(Some(j), "t") }), ["wheel"])
  // a pinch marked so: nothing, with ⌃ held too
  let from = r.inputs().length()
  r.t.hold_mods(@ui.mod_ctrl)
  r.t.wheel_with(mx, my, 0.0, 30.0, @ui.wheel_mod_ctrl | @ui.wheel_mod_pinch)
  r.t.hold_mods(0)
  assert_eq(r.inputs().length(), from)
  mouse_done(r)
}

///|
test "the keyboard types into it once it is pressed; ⌘V pastes this device's clipboard there, ⌘C goes as its keys" {
  let r = mouse_rig()
  driven(r)
  r.tap_at(0.5, 0.5)
  let from = r.inputs().length()
  r.t.type_text("hi 你好")
  let typed = r.inputs()[from:].to_owned()
  assert_eq(text(Some(typed[0]), "t"), "text")
  assert_eq(text(Some(typed[0]), "text"), "hi 你好")
  r.t.clipboard_gives("from the Mac")
  let from = r.inputs().length()
  r.t.key(@ui.key_of_char('v'), mods=@ui.mod_cmd)
  r.t.draw()
  let asked = r.told("screen.clipboard")
  assert_eq(asked.length(), 1)
  assert_eq(text(Some(asked[0]), "text"), "from the Mac")
  assert_eq(field(Some(asked[0]), "paste"), Some(Json::boolean(true)))
  assert_eq(r.inputs().length(), from)
  r.t.key(@ui.key_of_char('c'), mods=@ui.mod_cmd)
  let copy = r.inputs()[from:].to_owned()
  assert_eq(copy.length(), 2)
  assert_eq(text(Some(copy[0]), "code"), "KeyC")
  assert_eq(number(Some(copy[0]), "mods"), 4.0)
  mouse_done(r)
}

///|
test "Windows driving a Mac: cross-OS mapping swaps Ctrl and Meta by default and respects screenKeyMap off" {
  let r = screen_rig(w=1280.0, h=800.0, platform=3, os="macOS 26")
  r.t.run_for(@sf.later_ms)
  driven(r)
  r.tap_at(0.5, 0.5)
  let from = r.inputs().length()
  // Default ON: Ctrl+A/K/Shift+Z -> ⌘, Win+K -> ⌃, Ctrl+Alt+I -> ⌥⌘I, F5/F12/Insert pass through
  for pair in [
    (@ui.key_of_char('a'), @ui.mod_ctrl),
    (@ui.key_of_char('k'), @ui.mod_ctrl),
    (@ui.key_of_char('z'), @ui.mod_ctrl | @ui.mod_shift_key),
    (@ui.key_of_char('k'), @ui.mod_cmd),
    (@ui.key_of_char('i'), @ui.mod_ctrl | @ui.mod_alt),
    (@ui.key_code_f5, 0),
    (@ui.key_code_f12, 0),
    (@ui.key_code_insert, 0),
  ] {
    r.t.key(pair.0, mods=pair.1)
  }
  let keys = r.inputs()[from:].to_owned()
  assert_eq(
    keys.map(fn(k) { (text(Some(k), "kind"), text(Some(k), "code"), number(Some(k), "mods")) }),
    [
      ("down", "KeyA", 4.0),
      ("up", "KeyA", 4.0),
      ("down", "KeyK", 4.0),
      ("up", "KeyK", 4.0),
      ("down", "KeyZ", 12.0),
      ("up", "KeyZ", 12.0),
      ("down", "KeyK", 2.0),
      ("up", "KeyK", 2.0),
      ("down", "KeyI", 5.0),
      ("up", "KeyI", 5.0),
      ("down", "F5", 0.0),
      ("up", "F5", 0.0),
      ("down", "F12", 0.0),
      ("up", "F12", 0.0),
      ("down", "Insert", 0.0),
      ("up", "Insert", 0.0),
    ],
  )
  // Ctrl+V pastes this device's clipboard on Mac; Win+V sends raw ⌃V without pasting
  r.t.clipboard_gives("from win")
  let before_paste = r.inputs().length()
  r.t.key(@ui.key_of_char('v'), mods=@ui.mod_ctrl)
  r.t.draw()
  assert_eq(r.told("screen.clipboard").length(), 1)
  assert_eq(r.inputs().length(), before_paste)
  r.t.key(@ui.key_of_char('v'), mods=@ui.mod_cmd)
  let ctrl_v = r.inputs()[before_paste:].to_owned()
  assert_eq(ctrl_v.map(fn(k) { (text(Some(k), "code"), number(Some(k), "mods")) }), [("KeyV", 2.0), ("KeyV", 2.0)])
  // Ctrl+Click and Ctrl+Wheel send MetaLeft on Mac
  let (mx, my) = r.at(0.4, 0.4)
  let before_click = r.inputs().length()
  r.t.hold_mods(@ui.mod_ctrl)
  r.t.tap(mx, my)
  r.t.wheel_with(mx, my, 0.0, 30.0, 0)
  r.t.hold_mods(0)
  let ptr_mods = r.inputs()[before_click:]
    .to_owned()
    .filter(fn(k) { text(Some(k), "t") == "key" })
    .map(fn(k) { (text(Some(k), "kind"), text(Some(k), "code")) })
  assert_eq(ptr_mods, [("down", "MetaLeft"), ("up", "MetaLeft"), ("down", "MetaLeft"), ("up", "MetaLeft")])
  // Semantic text editing & navigation on Win -> Mac:
  // Home/End (+Shift) -> ⌘+←/→, Ctrl+←/→ (+Shift) -> ⌥+←/→, Ctrl+Backspace/Delete -> ⌥+Backspace/Delete, Ctrl+Home/End (+Shift) -> ⌘+↑/↓
  let from_nav = r.inputs().length()
  for pair in [
    (@ui.key_code_home, 0),
    (@ui.key_code_end, @ui.mod_shift_key),
    (@ui.key_code_left, @ui.mod_ctrl),
    (@ui.key_code_right, @ui.mod_ctrl | @ui.mod_shift_key),
    (@ui.key_code_backspace, @ui.mod_ctrl),
    (@ui.key_code_delete, @ui.mod_ctrl),
    (@ui.key_code_home, @ui.mod_ctrl),
    (@ui.key_code_end, @ui.mod_ctrl | @ui.mod_shift_key),
  ] {
    r.t.key(pair.0, mods=pair.1)
  }
  assert_eq(
    r.inputs()[from_nav:].to_owned().map(fn(k) { (text(Some(k), "code"), number(Some(k), "mods")) }),
    [
      ("ArrowLeft", 4.0),
      ("ArrowLeft", 4.0),
      ("ArrowRight", 12.0),
      ("ArrowRight", 12.0),
      ("ArrowLeft", 1.0),
      ("ArrowLeft", 1.0),
      ("ArrowRight", 9.0),
      ("ArrowRight", 9.0),
      ("Backspace", 1.0),
      ("Backspace", 1.0),
      ("Delete", 1.0),
      ("Delete", 1.0),
      ("ArrowUp", 4.0),
      ("ArrowUp", 4.0),
      ("ArrowDown", 12.0),
      ("ArrowDown", 12.0),
    ],
  )
  // Turn mapping off: Ctrl stays Control, Win stays Command, Win+V pastes, Ctrl+V sends raw ⌃V, Ctrl+Backspace raw
  r.key_map.set("off")
  r.t.draw()
  let from_off = r.inputs().length()
  for mods in [@ui.mod_cmd, @ui.mod_cmd | @ui.mod_shift_key, @ui.mod_ctrl] {
    r.t.key(@ui.key_of_char('k'), mods~)
  }
  r.t.key(@ui.key_code_backspace, mods=@ui.mod_ctrl)
  let raw = r.inputs()[from_off:].to_owned()
  assert_eq(raw.map(fn(k) { (text(Some(k), "code"), number(Some(k), "mods")) }), [
    ("KeyK", 4.0),
    ("KeyK", 4.0),
    ("KeyK", 12.0),
    ("KeyK", 12.0),
    ("KeyK", 2.0),
    ("KeyK", 2.0),
    ("Backspace", 2.0),
    ("Backspace", 2.0),
  ])
  let before_off_v = r.inputs().length()
  r.t.key(@ui.key_of_char('v'), mods=@ui.mod_ctrl)
  let off_ctrl_v = r.inputs()[before_off_v:].to_owned()
  assert_eq(off_ctrl_v.map(fn(k) { (text(Some(k), "code"), number(Some(k), "mods")) }), [("KeyV", 2.0), ("KeyV", 2.0)])
  assert_eq(r.told("screen.clipboard").length(), 1)
  r.t.clipboard_gives("win+v raw")
  r.t.key(@ui.key_of_char('v'), mods=@ui.mod_cmd)
  r.t.draw()
  assert_eq(r.told("screen.clipboard").length(), 2)
  mouse_done(r)
}

///|
test "Mac driving Windows: ⌘ maps to Ctrl, ⌃ stays Ctrl by default (or maps to Win when keepCtrl off), semantic text nav, ⌘V pastes" {
  let r = screen_rig(w=1280.0, h=800.0, platform=0, os="Windows 11 Pro")
  r.t.run_for(@sf.later_ms)
  driven(r)
  r.tap_at(0.5, 0.5)
  let from = r.inputs().length()
  // Default (screenKeyMap on, screenKeepCtrl on): ⌘ -> Ctrl, ⌃ stays Ctrl (safe for terminals)
  for pair in [
    (@ui.key_of_char('a'), @ui.mod_cmd),
    (@ui.key_of_char('l'), @ui.mod_cmd),
    (@ui.key_of_char('w'), @ui.mod_cmd),
    (@ui.key_of_char('c'), @ui.mod_ctrl),
    (@ui.key_of_char('d'), @ui.mod_ctrl),
  ] {
    r.t.key(pair.0, mods=pair.1)
  }
  let keys = r.inputs()[from:].to_owned()
  assert_eq(
    keys.map(fn(k) { (text(Some(k), "code"), number(Some(k), "mods")) }),
    [
      ("KeyA", 2.0),
      ("KeyA", 2.0),
      ("KeyL", 2.0),
      ("KeyL", 2.0),
      ("KeyW", 2.0),
      ("KeyW", 2.0),
      ("KeyC", 2.0),
      ("KeyC", 2.0),
      ("KeyD", 2.0),
      ("KeyD", 2.0),
    ],
  )
  // Semantic text editing & navigation on Mac -> Win:
  // ⌥+←/→ (+Shift) -> Ctrl+←/→, ⌥+Backspace/Delete -> Ctrl+Backspace/Delete,
  // ⌘+←/→ (+Shift) -> Home/End, ⌘+↑/↓ (+Shift) -> Ctrl+Home/End
  let from_nav = r.inputs().length()
  for pair in [
    (@ui.key_code_left, @ui.mod_alt),
    (@ui.key_code_right, @ui.mod_alt | @ui.mod_shift_key),
    (@ui.key_code_backspace, @ui.mod_alt),
    (@ui.key_code_delete, @ui.mod_alt),
    (@ui.key_code_left, @ui.mod_cmd),
    (@ui.key_code_right, @ui.mod_cmd | @ui.mod_shift_key),
    (@ui.key_code_up, @ui.mod_cmd),
    (@ui.key_code_down, @ui.mod_cmd | @ui.mod_shift_key),
  ] {
    r.t.key(pair.0, mods=pair.1)
  }
  assert_eq(
    r.inputs()[from_nav:].to_owned().map(fn(k) { (text(Some(k), "code"), number(Some(k), "mods")) }),
    [
      ("ArrowLeft", 2.0),
      ("ArrowLeft", 2.0),
      ("ArrowRight", 10.0),
      ("ArrowRight", 10.0),
      ("Backspace", 2.0),
      ("Backspace", 2.0),
      ("Delete", 2.0),
      ("Delete", 2.0),
      ("Home", 0.0),
      ("Home", 0.0),
      ("End", 8.0),
      ("End", 8.0),
      ("Home", 2.0),
      ("Home", 2.0),
      ("End", 10.0),
      ("End", 10.0),
    ],
  )
  // Modifier released before remapped key: ⌘+ArrowLeft down -> Home down, then ArrowLeft up with mods=0 still sends Home up
  let from_rel = r.inputs().length()
  r.key_in(true, "ArrowLeft", "ArrowLeft", mod_meta)
  r.key_in(false, "ArrowLeft", "ArrowLeft", 0)
  assert_eq(
    r.inputs()[from_rel:].to_owned().map(fn(k) { (kind_of_input(k), text(Some(k), "code"), number(Some(k), "mods")) }),
    [("down", "Home", 0.0), ("up", "Home", 0.0)],
  )
  // ⌘V pastes on Windows; ⌃V sends raw Ctrl+V without hijacking Vim/terminal into clipboard paste
  r.t.clipboard_gives("from mac")
  let before_v = r.inputs().length()
  r.t.key(@ui.key_of_char('v'), mods=@ui.mod_cmd)
  r.t.draw()
  assert_eq(r.told("screen.clipboard").length(), 1)
  assert_eq(r.inputs().length(), before_v)
  r.t.key(@ui.key_of_char('v'), mods=@ui.mod_ctrl)
  let raw_ctrl_v = r.inputs()[before_v:].to_owned()
  assert_eq(raw_ctrl_v.map(fn(k) { (text(Some(k), "code"), number(Some(k), "mods")) }), [("KeyV", 2.0), ("KeyV", 2.0)])
  assert_eq(r.told("screen.clipboard").length(), 1)
  // Turn screenKeepCtrl OFF: ⌃ now maps to Win (Meta), ⌃V sends Win+V, Ctrl-right-click still never leaks Win
  r.keep_ctrl.set("off")
  r.t.draw()
  let from_win = r.inputs().length()
  r.t.key(@ui.key_of_char('d'), mods=@ui.mod_ctrl)
  r.t.key(@ui.key_of_char('v'), mods=@ui.mod_ctrl)
  assert_eq(
    r.inputs()[from_win:].to_owned().map(fn(k) { (text(Some(k), "code"), number(Some(k), "mods")) }),
    [("KeyD", 4.0), ("KeyD", 4.0), ("KeyV", 4.0), ("KeyV", 4.0)],
  )
  assert_eq(r.told("screen.clipboard").length(), 1)
  // ⌘+Click and ⌘+Wheel send ControlLeft; macOS Ctrl+Click right-click strips Ctrl before remap (no MetaLeft!)
  let (mx, my) = r.at(0.4, 0.4)
  let before_ptr = r.inputs().length()
  r.t.hold_mods(@ui.mod_cmd)
  r.t.tap(mx, my)
  r.t.wheel_with(mx, my, 0.0, 30.0, 0)
  r.t.hold_mods(@ui.mod_ctrl)
  r.t.right_click(mx, my)
  r.t.hold_mods(0)
  let ptr_keys = r.inputs()[before_ptr:]
    .to_owned()
    .filter(fn(k) { text(Some(k), "t") == "key" })
    .map(fn(k) { (text(Some(k), "kind"), text(Some(k), "code")) })
  assert_eq(ptr_keys, [("down", "ControlLeft"), ("up", "ControlLeft"), ("down", "ControlLeft"), ("up", "ControlLeft")])
  // Turn mapping off: ⌘ sends raw Win (Meta), ⌥← sends raw Alt+ArrowLeft
  r.key_map.set("off")
  r.t.draw()
  let from_off = r.inputs().length()
  r.t.key(@ui.key_of_char('l'), mods=@ui.mod_cmd)
  r.t.key(@ui.key_code_left, mods=@ui.mod_alt)
  assert_eq(
    r.inputs()[from_off:].to_owned().map(fn(k) { (text(Some(k), "code"), number(Some(k), "mods")) }),
    [("KeyL", 4.0), ("KeyL", 4.0), ("ArrowLeft", 1.0), ("ArrowLeft", 1.0)],
  )
  mouse_done(r)
}

///|
test "same-OS, Android emulator on Mac, iOS Simulator on Windows, and touch combos" {
  // Mac -> Mac: untouched 1:1, ⌃V sends ⌃V rather than pasting
  let mac_mac = screen_rig(w=1280.0, h=800.0, platform=0, os="macOS 26")
  mac_mac.t.run_for(@sf.later_ms)
  driven(mac_mac)
  mac_mac.tap_at(0.5, 0.5)
  let f0 = mac_mac.inputs().length()
  mac_mac.t.key(@ui.key_of_char('a'), mods=@ui.mod_cmd)
  mac_mac.t.key(@ui.key_of_char('v'), mods=@ui.mod_ctrl)
  assert_eq(
    mac_mac.inputs()[f0:].to_owned().map(fn(k) { (text(Some(k), "code"), number(Some(k), "mods")) }),
    [("KeyA", 4.0), ("KeyA", 4.0), ("KeyV", 2.0), ("KeyV", 2.0)],
  )
  assert_eq(mac_mac.told("screen.clipboard").length(), 0)
  mouse_done(mac_mac)

  // Mac -> Android emulator hosted on a Mac: Android uses Ctrl, so ⌘A maps to Ctrl+A
  let mac_and = screen_rig(w=1280.0, h=800.0, platform=0, screen="android:emulator-5554", os="macOS 26")
  mac_and.t.run_for(@sf.later_ms)
  driven(mac_and)
  mac_and.tap_at(0.5, 0.5)
  let f1 = mac_and.inputs().length()
  mac_and.t.key(@ui.key_of_char('a'), mods=@ui.mod_cmd)
  assert_eq(mac_and.inputs()[f1:].to_owned().map(fn(k) { number(Some(k), "mods") }), [2.0, 2.0])
  mouse_done(mac_and)

  // Windows -> iOS Simulator: Simulator uses ⌘, so Ctrl+A maps to ⌘A, and held touch modifiers stay untouched
  let win_sim = screen_rig(w=1280.0, h=800.0, platform=3, screen="sim:iphone", os="macOS 26")
  win_sim.t.run_for(@sf.later_ms)
  win_sim.state("live", others=[], more={ "kind": Json::string("simulator") })
  win_sim.config()
  win_sim.frame(1000.0)
  win_sim.tap_at(0.5, 0.5)
  let f2 = win_sim.inputs().length()
  win_sim.t.key(@ui.key_of_char('a'), mods=@ui.mod_ctrl)
  assert_eq(win_sim.inputs()[f2:].to_owned().map(fn(k) { number(Some(k), "mods") }), [4.0, 4.0])
  // Touch keys row (u.held) sends remote-native modifiers without double-swapping
  let f3 = win_sim.inputs().length()
  win_sim.ui().held.toggle(mod_ctrl)
  win_sim.t.type_text("c")
  assert_eq(win_sim.inputs()[f3:].to_owned().map(fn(k) { number(Some(k), "mods") }), [2.0, 2.0])
  mouse_done(win_sim)
}

///|
test "over the picture driving it the mouse is the screen's pointer, in its shape; the station's is drawn again once it leaves" {
  let r = mouse_rig()
  r.live(others=[])
  r.state("live", others=[], more={ "cursor": { "x": 0.5, "y": 0.5, "shape": "text" } })
  assert_true(pointer_now(r.sess(), r.ui()) is Some(_))
  let (mx, my) = r.at(0.3, 0.3)
  r.t.move_to(mx, my)
  r.t.draw()
  assert_true(pointer_now(r.sess(), r.ui()) is None)
  assert_eq(r.t.cursor(), @ui.Cursor::IBeam)
  // up on the bar: the station's pointer drawn again
  r.t.move_to(mx, @sf.viewer_bar_h / 2.0)
  r.t.draw()
  assert_true(pointer_now(r.sess(), r.ui()) is Some(_))
  mouse_done(r)
}

///|
test "only looking, the mouse sends nothing and takes no keyboard" {
  let r = mouse_rig()
  r.state("live", control=false, others=[])
  r.config()
  r.frame(1000.0)
  let (mx, my) = r.at(0.5, 0.5)
  r.t.move_to(mx, my)
  r.tap_at(0.5, 0.5)
  r.t.wheel_with(mx, my, 0.0, 120.0, 0)
  assert_eq(r.inputs().length(), 0)
  assert_true(!r.t.key_catching())
  mouse_done(r)
}

///|
test "全屏 in 控制中心 fills the screen with the window, the bar kept; closing the screen puts it back" {
  let r = mouse_rig()
  r.live(others=[])
  r.tap_label(tr("web-pages.screen.panel"))
  r.t.run_for(@sf.later_ms)
  r.t.tap_text("全屏")
  r.t.run_for(@motion.presence_out_ms + @sf.later_ms)
  assert_true(@ui.full_screen())
  assert_true(!r.ui().full.get())
  assert_true(r.labelled(tr("common.back")) is Some(_))
  r.tap_label(tr("common.back"))
  nav_rested(r.t)
  assert_true(!@ui.full_screen())
  r.t.draw()
  mouse_done(r)
}

///|
test "an agent driving it: who drives said by the bar's line, 接管 among its tools with how the view goes and 控制中心; 接管 asks for control" {
  let r = mouse_rig()
  let agent = "Agent「修登录」"
  r.state(
    "live",
    control=false,
    others=[agent],
    controllers=[agent],
    take_over=true,
    line="只看 · \{agent} 正在控制",
  )
  r.config()
  r.frame(1000.0)
  assert_true(r.t.find("\{agent} 正在控制") is Some(_))
  assert_true(r.labelled(tr("web-pages.screen.panel")) is Some(_))
  r.t.tap_text("接管")
  let asked = r.told("screen.control")
  assert_eq(asked.length(), 1)
  assert_eq(field(Some(asked[0]), "control"), Some(Json::boolean(true)))
  mouse_done(r)
}

///|
test "在新窗口打开 in 控制中心 (a desktop's): the screen goes to a window of its own, which shows it alone, and leaves this one" {
  let r = mouse_rig()
  r.t.set_window_opens(true)
  r.live(others=[])
  r.tap_label(tr("web-pages.screen.panel"))
  r.t.run_for(@sf.later_ms)
  r.t.tap_text("在新窗口打开")
  nav_rested(r.t)
  let opened = r.t.windows_opened()
  assert_eq(opened.length(), 1)
  // what the window is started with names this screen, and reads back as it: the page's own, its title too
  assert_true(
    @sfbase.window_page(opened[0]) ==
    Some(Screen({ station: "ws-1/st-1", screen: "browser:tab-1", title: "Chrome", until_gone: false })),
  )
  // here it is closed, its view let go of: not open twice
  assert_true(!(app.nav.top() is Screen(_)))
  r.t.draw()
  assert_true(!screens_open.contains(screen_key("ws-1/st-1", "browser:tab-1")))
  mouse_done(r)
}

///|
test "no 在新窗口打开 where the app opens no window of its own (a phone's, the web's), nor in such a window" {
  let r = mouse_rig()
  r.live(others=[])
  r.tap_label(tr("web-pages.screen.panel"))
  r.t.run_for(@sf.later_ms)
  assert_true(r.t.find("全屏") is Some(_))
  assert_true(r.t.find("在新窗口打开") is None)
  mouse_done(r)
  // a window of its own already: none from it
  let r = mouse_rig()
  r.t.set_window_opens(true)
  @sfbase.lone_page.val = Some(Screen({ station: "ws-1/st-1", screen: "browser:tab-1", title: "", until_gone: false }))
  r.live(others=[])
  r.tap_label(tr("web-pages.screen.panel"))
  r.t.run_for(@sf.later_ms)
  assert_true(r.t.find("全屏") is Some(_))
  assert_true(r.t.find("在新窗口打开") is None)
  assert_eq(r.t.windows_opened(), [])
  @sfbase.lone_page.val = None
  mouse_done(r)
}

///|
test "what a window of its own is started with: a station's screen and its title, read back; nothing else names a page" {
  let at : @sfbase.Page = Screen({ station: "ws-1/st-1", screen: "desktop", title: "Willow 的屏幕", until_gone: false })
  let text = @sfbase.window_text(at).unwrap()
  assert_true(@sfbase.window_page(text) == Some(at))
  assert_eq(@sfbase.window_text(Files), None)
  assert_true(@sfbase.window_page("") is None)
  assert_true(@sfbase.window_page("{\"screen\":{\"station\":\"\",\"screen\":\"desktop\"}}") is None)
  assert_true(@sfbase.window_page("{\"drive\":{}}") is None)
}

///|
test "a round button says its name when the pointer has rested on it: a device's buttons show only icons" {
  let r = mouse_rig()
  simulator_live(r)
  r.t.draw()
  let home = tr("web-pages.screen.device.home")
  assert_true(r.t.find(home) is None)
  let (x, y) = r.labelled(home).unwrap()
  r.t.move_to(x, y)
  r.t.run_for(@headless.tooltip_delay_ms)
  r.t.draw()
  assert_true(r.t.find(home) is Some(_))
  mouse_done(r)
}

///|
test "this device's input method by the press on the screen being driven, not at the window's foot" {
  let r = mouse_rig()
  r.live()
  let (x, y) = r.at(0.5, 0.5)
  r.tap_at(0.5, 0.5)
  r.t.draw()
  assert_true(r.t.key_catching())
  let (ix, iy, _, _) = r.t.ime_rect()
  assert_eq(ix, x)
  assert_eq(iy, y)
  mouse_done(r)
}

///|
test "a mouse's press on a drop row's 在访达中显示 over the picture is its alone: nothing pressed on the screen under it" {
  let r = screen_rig(w=1280.0, h=800.0, platform=0)
  r.t.run_for(@sf.later_ms)
  driven(r)
  screen_fix_drops(true)
  r.t.draw()
  r.t.draw()
  let (x, y) = r.labelled(tr("android-misc.screen.reveal")).unwrap()
  let u = r.ui()
  let sh = u.shown(r.t.ctx())
  assert_true(
    x > u.stage_xy().0 + sh.x && x < u.stage_xy().0 + sh.x + sh.w && y > u.stage_xy().1 + sh.y && y < u.stage_xy().1 + sh.y + sh.h,
    msg="\{x},\{y}",
  )
  let before = r.inputs().filter(fn(j) { text(Some(j), "t") == "pointer" && kind_of_input(j) != "move" }).length()
  r.t.move_to(x, y)
  r.t.tap(x, y)
  r.t.draw()
  let after = r.inputs().filter(fn(j) { text(Some(j), "t") == "pointer" && kind_of_input(j) != "move" })
  assert_eq(after.length(), before)
  assert_eq(r.inputs().filter(fn(j) { text(Some(j), "t") == "reveal" }).length(), 1)
  r.t.run_for(@sf.toast_ms)
  mouse_done(r)
}

///|
test "in a chat's side panel with keyboard and mouse: one compact toolbar row (no traffic-light indent, no back, no duplicate title), with 控制中心 on a browser tab and 组合键 on a desktop" {
  // browser tab in side panel (373 wide, as in a 1280x800 chat window)
  let b = screen_rig(w=373.0, h=756.0, platform=0, in_tab=true)
  b.t.run_for(@sf.later_ms)
  b.state("live", more={ "openUrl": Json::boolean(true), "address": Json::string("https://console.anthropic.com/login") })
  b.t.draw()
  assert_true(b.labelled(tr("common.back")) is None)
  assert_true(b.t.find("still.fail — Chrome") is None)
  assert_true(b.labelled(tr("web-pages.screen.back")) is Some(_))
  assert_true(b.labelled(tr("web-pages.screen.panel")) is Some(_))
  assert_eq(b.ui().stage_xy().1, 48.0)
  assert_eq(b.t.squeeze_faults(), [])
  assert_eq(b.t.audit(), [])
  mouse_done(b)

  // desktop screen in side panel: status line + 组合键 + 控制中心 in one 48px row
  let d = screen_rig(w=373.0, h=756.0, platform=0, screen="desktop", in_tab=true)
  d.t.run_for(@sf.later_ms)
  d.state("live", more={ "kind": Json::string("desktop"), "title": Json::string("桌面") })
  d.t.draw()
  assert_true(d.labelled(tr("common.back")) is None)
  assert_true(d.t.find("桌面") is None)
  assert_true(d.t.find("控制 · 李雷也在看") is Some(_))
  assert_true(d.labelled(tr("web-pages.screen.combos")) is Some(_))
  assert_true(d.labelled(tr("web-pages.screen.panel")) is Some(_))
  assert_eq(d.ui().stage_xy().1, 48.0)
  assert_eq(d.t.squeeze_faults(), [])
  assert_eq(d.t.audit(), [])
  mouse_done(d)
}

///|
test "a window of its own driven: the keyboard the screen's at once, no press on the picture first; not beside a chat, not only looking" {
  let r = mouse_rig()
  r.live(others=[])
  // what a voice input types (豆包, Typeless, the system's dictation) lands there straight away
  assert_true(r.t.key_catching())
  let from = r.inputs().length()
  r.t.type_text("语音输入测试")
  let typed = r.inputs()[from:].to_owned()
  assert_eq(typed.length(), 1)
  assert_eq(text(Some(typed[0]), "t"), "text")
  assert_eq(text(Some(typed[0]), "text"), "语音输入测试")
  mouse_done(r)
  // only looking: nothing taken
  let r = mouse_rig()
  r.state("live", control=false, others=[])
  assert_false(r.t.key_catching())
  mouse_done(r)
  // a tab beside a chat: the chat's field keeps the keys
  let r = screen_rig(w=373.0, h=756.0, platform=0, in_tab=true)
  r.t.run_for(@sf.later_ms)
  r.live(others=[])
  assert_false(r.t.key_catching())
  mouse_done(r)
  // 远程's workbench pane (in_tab with tab_pads, no chat field beside it): takes the keyboard at once so ⌘V works
  let r = screen_rig(w=1024.0, h=756.0, platform=0, in_tab=true, tab_pads=true)
  r.t.run_for(@sf.later_ms)
  r.live(others=[], clipboard=["text"])
  assert_true(r.t.key_catching())
  r.t.clipboard_gives("lock-pass")
  r.t.key(@ui.key_of_char('v'), mods=@ui.mod_cmd)
  r.t.draw()
  let asked = r.told("screen.clipboard")
  assert_eq(asked.length(), 1)
  assert_eq(text(Some(asked[0]), "text"), "lock-pass")
  assert_eq(field(Some(asked[0]), "paste"), Some(Json::boolean(true)))
  mouse_done(r)
}

///|
/// The page's own keys (screen_keys_in) as the key catcher hands them: a key going down or up alone.
fn ScreenRig::key_in(self : ScreenRig, down : Bool, key : String, code : String, mods : Int) -> Unit {
  let pg : ScreenPage = {
    s: self.sess(),
    u: self.ui(),
    title: "",
    close: fn() {  },
    tips: @sf.TipLayer::new(fn() { None }),
    in_tab: false,
    own_bar: None,
    lone: false,
    tab_pads: None,
    pane_width: None,
    on_window: None,
  }
  screen_keys_in(pg, Key(down~, key~, code~, mods~))
  self.t.draw()
}

///|
test "⌘V on a screen that carries no clipboard: this device's text typed there; with none, ⌘V itself sent; V let go of after ⌘ sends nothing alone" {
  let r = mouse_rig()
  // a tab of the station's browser: no clipboard of its own
  r.live(others=[])
  assert_false(r.sess().pastes())
  r.t.clipboard_gives("从语音输入粘贴")
  let from = r.inputs().length()
  r.t.key(@ui.key_of_char('v'), mods=@ui.mod_cmd)
  r.t.draw()
  assert_eq(r.told("screen.clipboard").length(), 0)
  let typed = r.inputs()[from:].to_owned()
  assert_eq(typed.length(), 1)
  assert_eq(text(Some(typed[0]), "t"), "text")
  assert_eq(text(Some(typed[0]), "text"), "从语音输入粘贴")
  // nothing on this device's clipboard (copied on the screen itself): ⌘V goes there, down and up
  r.t.clipboard_gives("")
  let from = r.inputs().length()
  r.t.key(@ui.key_of_char('v'), mods=@ui.mod_cmd)
  r.t.draw()
  let keys = r.inputs()[from:].to_owned()
  assert_eq(keys.map(fn(k) { text(Some(k), "code") }), ["KeyV", "KeyV"])
  assert_eq(keys.map(fn(k) { text(Some(k), "kind") }), ["down", "up"])
  assert_eq(keys.map(fn(k) { number(Some(k), "mods") }), [4.0, 4.0])
  // ⌘ let go of before V: V's going up taken with its going down, nothing of it sent alone
  r.t.clipboard_gives("again")
  let from = r.inputs().length()
  r.key_in(true, "v", "KeyV", mod_meta)
  r.key_in(false, "v", "KeyV", 0)
  let after = r.inputs()[from:].to_owned()
  assert_eq(after.length(), 1)
  assert_eq(text(Some(after[0]), "t"), "text")
  assert_eq(text(Some(after[0]), "text"), "again")
  // a V of its own afterwards goes as it is
  let from = r.inputs().length()
  r.key_in(true, "v", "KeyV", 0)
  r.key_in(false, "v", "KeyV", 0)
  assert_eq(r.inputs()[from:].to_owned().map(fn(k) { text(Some(k), "kind") }), ["down", "up"])
  mouse_done(r)
}

///|
test "two pastes one on the other (two sentences of a voice input): the second asked as the first is done, never lost" {
  let r = mouse_rig()
  driven(r)
  // both asked before this device's clipboard answers the first
  r.t.key(@ui.key_of_char('v'), mods=@ui.mod_cmd)
  r.t.key(@ui.key_of_char('v'), mods=@ui.mod_cmd)
  assert_eq(r.t.clipboard_reads(), 1)
  // (the host's answer taken at the next frame, the paste told as it is read)
  r.t.clipboard_gives("第一句")
  r.t.draw()
  r.t.draw()
  assert_eq(r.told("screen.clipboard").map(fn(p) { text(Some(p), "text") }), ["第一句"])
  // the second read as the first was done
  assert_eq(r.t.clipboard_reads(), 2)
  // (the host's answer taken at the next frame, the paste told as it is read)
  r.t.clipboard_gives("第二句")
  r.t.draw()
  r.t.draw()
  assert_eq(r.told("screen.clipboard").map(fn(p) { text(Some(p), "text") }), ["第一句", "第二句"])
  assert_false(r.sess().pasting.untracked())
  mouse_done(r)
}

///|
test "the station's diagonal resize pointers are this device's own over the picture" {
  let r = mouse_rig()
  r.live(others=[])
  let (mx, my) = r.at(0.3, 0.3)
  for pair in [("nwse-resize", @ui.Cursor::ResizeNWSE), ("se-resize", ResizeNWSE), ("nesw-resize", ResizeNESW), ("sw-resize", ResizeNESW)] {
    let (shape, cursor) = pair
    r.state("live", others=[], more={ "cursor": { "x": 0.5, "y": 0.5, "shape": Json::string(shape) } })
    r.t.move_to(mx, my)
    r.t.draw()
    assert_eq(r.t.cursor(), cursor, msg=shape)
  }
  mouse_done(r)
}
