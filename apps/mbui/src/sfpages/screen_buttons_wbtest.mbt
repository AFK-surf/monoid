// A whole mouse and a game controller on a screen driven from a computer's window (screen_buttons.mbt): the secondary
// and middle buttons held as long as they are beside the primary, the pointer held for an app there that holds the
// screen's, controllers sent as they change; and 超清 (`qhd`) asked as 2560 × 1440.

///|
/// The pointer and buttons of the inputs sent from `from` on (keys left out).
fn pointers_since(r : ScreenRig, from : Int) -> Array[Json] {
  r.inputs()[from:].to_owned().filter(fn(j) { text(Some(j), "t") == "pointer" })
}

///|
test "1440p and 2160p ask for 2560×1440 and 3840×2160; bitrate and 4:4:4 go independently" {
  let r = screen_rig()
  r.quality.set("qhd")
  r.bitrate.set(35)
  @sfbase.close_page(Screen({ station: "ws-1/st-1", screen: "browser:tab-1", title: "Chrome", until_gone: false })) |> ignore
  nav_rested(r.t)
  app.nav.push(Screen({ station: "ws-1/st-1", screen: "browser:tab-1", title: "Chrome", until_gone: false }))
  nav_rested(r.t)
  let asked = r.told("screen.view")
  assert_eq(number(Some(asked[asked.length() - 1]), "maxWidth"), 2560.0)
  assert_eq(number(Some(asked[asked.length() - 1]), "maxHeight"), 1440.0)
  assert_eq(text(Some(asked[asked.length() - 1]), "quality"), "qhd")
  assert_eq(number(Some(asked[asked.length() - 1]), "bitrate"), 35_000_000.0)
  assert_true(field(Some(asked[asked.length() - 1]), "chroma444") is None)
  // 2160p (uhd) asks 3840x2160
  r.quality.set("uhd")
  r.t.run_for(@ui.move_most_ms)
  let bounds = r.told("screen.bounds").last().unwrap()
  assert_eq(number(Some(bounds), "maxWidth"), 3840.0)
  assert_eq(number(Some(bounds), "maxHeight"), 2160.0)
  assert_eq(text(Some(bounds), "quality"), "uhd")
  assert_eq(number(Some(bounds), "bitrate"), 35_000_000.0)
  assert_eq(screen_qualities.map(fn(q) { q.0 }), ["", "smooth", "hd", "qhd", "uhd", "original"])
  assert_eq(tr("web-pages.screen.quality.qhd"), "1440p")
  assert_eq(tr("web-pages.screen.quality.uhd"), "2160p")
  screen_done(r.t)
}

///|
test "input goes with the view's call, as its acks do; nobody reads its answer" {
  let r = mouse_rig()
  r.live(others=[])
  let (mx, my) = r.at(0.25, 0.5)
  r.t.move_to(mx, my)
  let told = r.told("screen.input")
  assert_eq(told.length(), 1)
  assert_eq(number(Some(told[0]), "call"), r.sess().call.to_double())
  assert_true(screen_unread_calls().contains("screen.input"))
  mouse_done(r)
}

///|
test "the right button held aims while the left fires: down 2, moves held 2, the left down 3 and up 2, the right up 0" {
  let r = mouse_rig()
  r.live(others=[])
  let from = r.inputs().length()
  let (ax, ay) = r.at(0.4, 0.4)
  let (bx, by) = r.at(0.5, 0.45)
  r.t.move_to(ax, ay)
  r.t.button_down(ax, ay, 2)
  r.t.move_to(bx, by)
  // (the left button pressed with the right held, then let go)
  r.t.press_at(bx, by)
  r.t.release(bx, by)
  r.t.button_up(bx, by, 2)
  let ins = pointers_since(r, from).filter(fn(j) { kind_of_input(j) != "move" || number(Some(j), "buttons") != 0.0 })
  assert_eq(ins.map(fn(j) { (kind_of_input(j), number(Some(j), "buttons")) }), [
    ("down", 2.0),
    ("move", 2.0),
    ("down", 3.0),
    ("up", 2.0),
    ("up", 0.0),
  ])
  assert_true(close_to(number(Some(ins[1]), "x"), 0.5))
  assert_true(close_to(number(Some(ins[4]), "y"), 0.45))
  // no menu came of it, nothing else held
  assert_eq(r.sess().phase(), "live")
  mouse_done(r)
}

///|
test "the middle button held drags: down 4, moves 4, up 0; dragged past the picture's edge, at its edge" {
  let r = mouse_rig()
  r.live(others=[])
  let from = r.inputs().length()
  let (ax, ay) = r.at(0.3, 0.3)
  r.t.move_to(ax, ay)
  r.t.button_down(ax, ay, 3)
  let (bx, by) = r.at(0.6, 0.5)
  r.t.move_to(bx, by)
  let (cx, cy) = r.at(1.4, 0.5)
  r.t.move_to(cx, cy)
  r.t.button_up(cx, cy, 3)
  let ins = pointers_since(r, from)[1:].to_owned()
  assert_eq(ins.map(fn(j) { (kind_of_input(j), number(Some(j), "buttons")) }), [
    ("down", 4.0),
    ("move", 4.0),
    ("move", 4.0),
    ("up", 0.0),
  ])
  assert_true(close_to(number(Some(ins[2]), "x"), 1.0))
  mouse_done(r)
}

///|
test "a middle button where nothing takes it does nothing; a right click elsewhere is a menu's as ever" {
  let r = mouse_rig()
  r.live(others=[])
  let from = r.inputs().length()
  // (the viewer's bar, above the picture)
  r.t.button_down(200.0, 10.0, 3)
  r.t.button_up(200.0, 10.0, 3)
  assert_eq(pointers_since(r, from).length(), 0)
  mouse_done(r)
}

///|
test "an app there holding the pointer: a press holds this window's, its moves go as how far it went, ⌃Esc lets it go" {
  let r = mouse_rig()
  r.live(others=[])
  r.state("live", others=[], more={ "pointerLock": Json::boolean(true) })
  let (ax, ay) = r.at(0.5, 0.5)
  r.t.move_to(ax, ay)
  assert_eq(r.t.pointer_locked().0, false)
  let from = r.inputs().length()
  r.tap_at(0.5, 0.5)
  assert_eq(r.t.pointer_locked().0, true)
  let click = pointers_since(r, from)
  assert_eq(click.map(fn(j) { (kind_of_input(j), field(Some(j), "relative") is Some(True)) }), [
    ("down", true),
    ("up", true),
  ])
  // moved: how far it went, where the pointer stays; held still, nothing
  let from = r.inputs().length()
  r.t.locked_move(ax, ay, 12.0, -3.0)
  r.t.locked_move(ax, ay, 0.0, 0.0)
  let moves = pointers_since(r, from)
  assert_eq(moves.length(), 1)
  assert_eq((number(Some(moves[0]), "dx"), number(Some(moves[0]), "dy")), (12.0, -3.0))
  assert_true(field(Some(moves[0]), "relative") is Some(True))
  // the right button held while it is: relative too, its moves how far
  let from = r.inputs().length()
  r.t.button_down(ax, ay, 2)
  r.t.locked_move(ax, ay, 5.0, 1.0)
  r.t.button_up(ax, ay, 2)
  assert_eq(pointers_since(r, from).map(fn(j) { (kind_of_input(j), number(Some(j), "buttons"), number(Some(j), "dx")) }), [
    ("down", 2.0, 0.0),
    ("move", 2.0, 5.0),
    ("up", 0.0, 0.0),
  ])
  // ⌃Esc: let go of, the key not sent
  let from = r.inputs().length()
  r.key_in(true, "Escape", "Escape", mod_ctrl)
  r.key_in(false, "Escape", "Escape", mod_ctrl)
  assert_eq(r.t.pointer_locked().0, false)
  assert_true(r.inputs()[from:].iter().all(fn(j) { text(Some(j), "code") != "Escape" }))
  mouse_done(r)
}

///|
test "the pointer held is let go of as the app there lets it go, as driving stops, and as the system takes it" {
  let r = mouse_rig()
  r.live(others=[])
  r.state("live", others=[], more={ "pointerLock": Json::boolean(true) })
  r.tap_at(0.5, 0.5)
  assert_eq(r.t.pointer_locked().0, true)
  // the app there lets it go
  r.state("live", others=[])
  assert_eq(r.t.pointer_locked().0, false)
  // held again, then the window out of focus: the system lets it go, moves are the pointer's own again
  r.state("live", others=[], more={ "pointerLock": Json::boolean(true) })
  r.tap_at(0.5, 0.5)
  assert_eq(r.t.pointer_locked().0, true)
  r.t.pointer_lock_lost()
  let from = r.inputs().length()
  let (bx, by) = r.at(0.25, 0.25)
  r.t.move_to(bx, by)
  let moves = pointers_since(r, from)
  assert_eq(moves.length(), 1)
  assert_true(field(Some(moves[0]), "relative") is None)
  assert_true(close_to(number(Some(moves[0]), "x"), 0.25))
  // held again, then only looking: let go of
  r.tap_at(0.5, 0.5)
  assert_eq(r.t.pointer_locked().0, true)
  r.state("live", control=false, others=[], more={ "pointerLock": Json::boolean(true) })
  assert_eq(r.t.pointer_locked().0, false)
  mouse_done(r)
}

///|
test "a controller's state goes as it changes, a stick held over 60 times a second, one let go of said so" {
  let r = mouse_rig()
  r.live(others=[])
  let pads = fn() { r.inputs().filter(fn(j) { text(Some(j), "t") == "gamepad" }) }
  // none connected: nothing
  r.t.run_for(@ui.gamepads_looked_ms * 2.0)
  assert_eq(pads().length(), 0)
  // one connected, A held: said within the second it is looked for
  r.t.set_gamepads([{ index: 0, buttons: 1, lx: 0.0, ly: 0.0, rx: 0.0, ry: 0.0, lt: 0.0, rt: 0.0 }])
  r.t.run_for(@ui.gamepads_looked_ms)
  assert_eq(pads().length(), 1)
  assert_eq(number(Some(pads()[0]), "buttons"), 1.0)
  assert_true(field(Some(pads()[0]), "connected") is Some(True))
  // the same, at rest: nothing more
  r.t.run_for(@ui.gamepad_ms * 30.0)
  assert_eq(pads().length(), 1)
  // a stick held over: again @ui.gamepad_ms apart (30 in 30 of them, give or take one)
  r.t.set_gamepads([{ index: 0, buttons: 0, lx: 0.5, ly: -1.0, rx: 0.0, ry: 0.0, lt: 0.0, rt: 0.25 }])
  let held_from = pads().length()
  r.t.run_for(@ui.gamepad_ms * 30.0)
  let held = pads().length() - held_from
  assert_true(held >= 29 && held <= 31, msg="\{held}")
  let last = pads().last().unwrap()
  assert_eq((number(Some(last), "lx"), number(Some(last), "ly"), number(Some(last), "rt")), (0.5, -1.0, 0.25))
  // let go of: said once, connected false
  r.t.set_gamepads([])
  r.t.run_for(@ui.gamepad_ms * 6.0)
  let gone = pads().last().unwrap()
  assert_true(field(Some(gone), "connected") is Some(False))
  let n = pads().length()
  r.t.run_for(@ui.gamepads_looked_ms * 2.0)
  assert_eq(pads().length(), n)
  r.t.set_gamepads([])
  mouse_done(r)
}
