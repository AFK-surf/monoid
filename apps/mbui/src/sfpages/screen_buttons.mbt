// What a whole mouse and a game controller do on a screen driven from this device's own window (a game's): the
// secondary and middle buttons held as long as they are, beside the primary (a view aimed with the right button held
// while the left fires: `buttons` 3); the pointer held by the window while an app there holds the screen's (its moves
// sent as how far the mouse went, `relative`, the system's pointer hidden and kept in place); controllers read and sent
// as they change. A browser's page does the last two itself (web/src/mbui/screen-peripherals.ts): here they are a
// native window's alone (screen_held_here).

///|
/// Whether this device's window holds the pointer and reads controllers for a screen itself: macOS's and Windows'
/// (a browser's page does both itself; the other hosts have neither).
fn screen_held_here() -> Bool {
  let p = @ui.platform()
  p == 0 || p == 3
}

///|
/// The pointer is to be held for the screen: an app there holds the screen's (its state's `pointerLock`), the view
/// driven by this device's window.
fn screen_lock_wanted(s : ScreenSess) -> Bool {
  screen_held_here() && s.driving() && flag(s.state, "pointerLock")
}

///|
/// Whether the window holds the pointer for the screen now: let go of by the system meanwhile (the window gone out
/// of focus), not.
fn MouseDrive::locked_now(self : MouseDrive) -> Bool {
  if self.locked && !@hostapi.pointer_locked() {
    self.locked = false
  }
  self.locked
}

///|
/// A button going down on the picture while an app there holds the screen's pointer: the window holds this device's
/// (a person's press, as a browser's page takes it on one), what it moved before let go of.
fn screen_lock_take(s : ScreenSess, m : MouseDrive) -> Unit {
  if m.locked_now() || !screen_lock_wanted(s) {
    return
  }
  @hostapi.set_pointer_lock(true)
  m.locked = @hostapi.pointer_locked()
  if m.locked {
    @hostapi.pointer_delta_take() |> ignore
  }
}

///|
/// The pointer held for the screen let go of (the app there holds it no more, the view no longer driven, the stage
/// gone, or the person's keys: screen_lock_keys), the system's pointer seen again.
fn screen_lock_give(m : MouseDrive) -> Unit {
  if m.locked {
    m.locked = false
    @hostapi.set_pointer_lock(false)
  }
}

///|
/// The keys that let go of the pointer held for the screen, whatever the app there does (⌃Esc, ⌃⌥⇧Q): true where they
/// did (the key not sent).
fn screen_lock_keys(m : MouseDrive, code : String, mods : Int, down : Bool) -> Bool {
  if !down && m.lock_key != "" && code == m.lock_key {
    m.lock_key = ""
    return true
  }
  guard down && m.locked_now() else { return false }
  let ctrl = (mods & mod_ctrl) != 0
  if (code == "Escape" && ctrl) ||
    (code == "KeyQ" && ctrl && (mods & mod_alt) != 0 && (mods & mod_shift) != 0) {
    screen_lock_give(m)
    m.lock_key = code
    true
  } else {
    false
  }
}

///|
/// The mouse moved while the pointer is held: how far it went since the last move sent (`dx`, `dy`, as a browser's
/// movementX and movementY), where the screen's pointer was last sent, `buttons` held; none where it went nowhere.
fn screen_lock_moved(s : ScreenSess, m : MouseDrive, buttons : Int) -> Unit {
  let (dx, dy) = @hostapi.pointer_delta_take()
  if dx == 0.0 && dy == 0.0 {
    return
  }
  let (x, y) = m.at.unwrap_or((0.5, 0.5))
  s.input(
    s.src,
    Json::object({
      "t": Json::string("pointer"),
      "kind": Json::string("move"),
      "x": Json::number(x),
      "y": Json::number(y),
      "buttons": Json::number(buttons.to_double()),
      "dx": Json::number(dx),
      "dy": Json::number(dy),
      "relative": Json::boolean(true),
    }),
  )
}

///|
/// A button's press or let go (`kind`) at `at`, `buttons` held after it: where the pointer is held, `relative` (it goes
/// where the screen's pointer is, never to x, y).
fn pointer_held(kind : String, m : MouseDrive, at : (Double, Double), buttons : Int) -> Json {
  if m.locked_now() {
    let (x, y) = m.at.unwrap_or(at)
    Json::object({
      "t": Json::string("pointer"),
      "kind": Json::string(kind),
      "x": Json::number(x),
      "y": Json::number(y),
      "buttons": Json::number(buttons.to_double()),
      "relative": Json::boolean(true),
    })
  } else {
    pointer_input(kind, at, buttons)
  }
}

///|
/// The mouse's secondary or middle button on the stage (`b`, each from down to up with the moves between): down where
/// it is (Ctrl-click is the system's own right click: no ⌃ round it), held beside the primary or alone, moved held
/// (past the picture's edge, at its edge) and up, each with the buttons held after it, the keys held as the first went
/// down round all of them. Only while driving it; it gives it the keyboard as a press does.
fn screen_mouse_buttons(_stage : @view.View, pg : ScreenPage, b : @view.Buttons) -> Unit {
  let s = pg.s
  let u = pg.u
  let m = u.mouse
  let send = fn(j : Json) { s.input(s.src, j) }
  let shown = u.shown_at(b.at)
  let bit = @view.button_bit(b.button)
  match b.went {
    ButtonDown => {
      if !s.driving() {
        if screen_frame_at(b.x, b.y, shown, false) is Some(_) {
          screen_held_by_hint(s, u)
        }
        return
      }
      guard bit != 0 && (m.extra & bit) == 0 else { return }
      guard screen_frame_at(b.x, b.y, shown, false) is Some(at) else { return }
      u.fling.stop()
      match u.catcher {
        Some(k) => @ui.key_catcher_focus_set(k, true)
        None => ()
      }
      if m.held() == 0 {
        let raw = mods_of_held(@ui.mods_held()) &
          (if b.button == 2 { mod_ctrl.lnot() } else { (0).lnot() })
        m.mods = screen_remap_mods(s, raw)
        mods_round(send, m.mods, "down")
      }
      screen_lock_take(s, m)
      if !m.locked_now() {
        m.at = Some(at)
      }
      m.extra = m.extra | bit
      send(pointer_held("down", m, at, m.held()))
      m.over.set(true)
    }
    ButtonMoved =>
      // (the primary held too: its drag sends the moves, these buttons with them)
      if m.extra != 0 && !m.sent_down {
        match screen_frame_at(b.x, b.y, shown, true) {
          Some(at) => m.move_to(s, at, m.held())
          None => ()
        }
      }
    ButtonUp => {
      guard bit != 0 && (m.extra & bit) != 0 else { return }
      m.extra = m.extra & bit.lnot()
      let at = match screen_frame_at(b.x, b.y, shown, true) {
        Some(at) => at
        None => m.at.unwrap_or((0.5, 0.5))
      }
      if !m.locked_now() {
        m.at = Some(at)
      }
      send(pointer_held("up", m, at, m.held()))
      if m.held() == 0 {
        mods_round(send, m.mods, "up")
      }
    }
  }
}

///|
/// The secondary and middle buttons sent down let go of (driving stopped, the stage gone): each sent up, the keys round
/// them after the last.
fn screen_buttons_let_go(s : ScreenSess, m : MouseDrive) -> Unit {
  guard m.extra != 0 else { return }
  let send = fn(j : Json) { s.input(s.src, j) }
  let at = m.at.unwrap_or((0.5, 0.5))
  for bit in [2, 4] {
    if (m.extra & bit) != 0 {
      m.extra = m.extra & bit.lnot()
      send(pointer_held("up", m, at, m.held()))
    }
  }
  if m.held() == 0 {
    mods_round(send, m.mods, "up")
  }
}

///|
/// A controller's state as `screen.input` takes it (`connected` false: let go of, the screen's virtual one released).
fn pad_input(p : @hostapi.Gamepad?, index : Int) -> Json {
  match p {
    Some(p) =>
      Json::object({
        "t": Json::string("gamepad"),
        "index": Json::number(p.index.to_double()),
        "connected": Json::boolean(true),
        "buttons": Json::number(p.buttons.to_double()),
        "lx": Json::number(p.lx),
        "ly": Json::number(p.ly),
        "rx": Json::number(p.rx),
        "ry": Json::number(p.ry),
        "lt": Json::number(p.lt),
        "rt": Json::number(p.rt),
      })
    None =>
      Json::object({
        "t": Json::string("gamepad"),
        "index": Json::number(index.to_double()),
        "connected": Json::boolean(false),
        "buttons": Json::number(0.0),
        "lx": Json::number(0.0),
        "ly": Json::number(0.0),
        "rx": Json::number(0.0),
        "ry": Json::number(0.0),
        "lt": Json::number(0.0),
        "rt": Json::number(0.0),
      })
  }
}

///|
/// The controllers this device's window reads, sent to the screen while it is driven from it (screen_held_here): each
/// as it changes (a stick held over, @ui.gamepad_ms apart), one let go of as it goes (`connected` false).
fn screen_pads_follow(stage : @view.View, s : ScreenSess) -> Unit {
  guard screen_held_here() else { return }
  @ui.gamepads_follow(stage, fn() { s.driving_now() }, fn(i, p) { s.input(s.src, pad_input(p, i)) })
}
