// What a person does on the device, as a station's screen takes it (still.fail apps/android app/remote/Input.kt;
// `screen.input`): points in 0..1 of the frame, buttons as the DOM's bit mask, keys by the DOM's
// KeyboardEvent names, typed text as it is committed. And the frame's own zoom and the trackpad's pointer, on this
// device only (PadPointer).

///|
/// The DOM's mouse buttons (MouseEvent.buttons).
let btn_primary : Int = 1

///|
let btn_secondary : Int = 2

///|
/// The modifier bits as the station takes them.
let mod_alt : Int = 1

///|
let mod_ctrl : Int = 2

///|
let mod_meta : Int = 4

///|
let mod_shift : Int = 8

///|
/// A rect on the stage: left, top, width, height (px).
// Eq and Debug for its tests
#warnings("-unused_value")
#derive(Eq, Debug)
priv struct SRect {
  x : Double
  y : Double
  w : Double
  h : Double
}

///|
// kept across runs: a value (no field of it changes)
let srect_zero : SRect = { x: 0.0, y: 0.0, w: 0.0, h: 0.0 }

///|
/// Where `p` (on the stage) is on the frame drawn at `shown` (on the stage too: letterboxed, zoomed), 0..1 each way.
/// Outside the frame: None, or the nearest edge when `clamp` (a drag that went past it).
fn screen_frame_at(px : Double, py : Double, shown : SRect, clamp : Bool) -> (Double, Double)? {
  if shown.w <= 0.0 || shown.h <= 0.0 {
    return None
  }
  let x = (px - shown.x) / shown.w
  let y = (py - shown.y) / shown.h
  if !clamp && (x < 0.0 || x > 1.0 || y < 0.0 || y > 1.0) {
    return None
  }
  Some((clamp01(x), clamp01(y)))
}

///|
fn clamp01(v : Double) -> Double {
  if v < 0.0 {
    0.0
  } else if v > 1.0 {
    1.0
  } else {
    v
  }
}

///|
/// Where a frame of `fw` × `fh` px fits whole in a stage of `bw` × `bh` px, centred (letterboxed).
fn fit_in(bw : Double, bh : Double, fw : Double, fh : Double) -> SRect {
  if fw <= 0.0 || fh <= 0.0 || bw <= 0.0 || bh <= 0.0 {
    return srect_zero
  }
  let k = dmin(bw / fw, bh / fh)
  let w = fw * k
  let h = fh * k
  { x: (bw - w) / 2.0, y: (bh - h) / 2.0, w, h }
}

///|
fn pointer_input(kind : String, at : (Double, Double), buttons : Int) -> Json {
  Json::object({
    "t": Json::string("pointer"),
    "kind": Json::string(kind),
    "x": Json::number(at.0),
    "y": Json::number(at.1),
    "buttons": Json::number(buttons.to_double()),
  })
}

///|
/// A wheel at `at`, `dx`/`dy` in CSS pixels (positive: scrolls right / down).
fn wheel_input(at : (Double, Double), dx : Double, dy : Double) -> Json {
  Json::object({
    "t": Json::string("wheel"),
    "x": Json::number(at.0),
    "y": Json::number(at.1),
    "dx": Json::number(dx),
    "dy": Json::number(dy),
  })
}

///|
fn key_input(kind : String, key : String, code : String, mods : Int) -> Json {
  Json::object({
    "t": Json::string("key"),
    "kind": Json::string(kind),
    "key": Json::string(key),
    "code": Json::string(code),
    "mods": Json::number(mods.to_double()),
  })
}

///|
fn text_input(words : String) -> Json {
  Json::object({ "t": Json::string("text"), "text": Json::string(words) })
}

///|
/// A key pressed and let go.
fn stroke(send : (Json) -> Unit, key : String, code : String, mods : Int) -> Unit {
  send(key_input("down", key, code, mods))
  send(key_input("up", key, code, mods))
}

///|
/// A mouse button pressed and let go at `at`, the keys of `mods` held round it (⌘-click, ⇧-click).
fn click(send : (Json) -> Unit, at : (Double, Double), button : Int, mods : Int) -> Unit {
  mods_round(send, mods, "down")
  send(pointer_input("down", at, button))
  send(pointer_input("up", at, button))
  mods_round(send, mods, "up")
}

///|
/// The keys held on this device (@ui.mods_held: mod_shift_key, mod_ctrl, mod_alt, mod_cmd) as the station takes them.
fn mods_of_held(held : Int) -> Int {
  (if (held & @ui.mod_alt) != 0 { mod_alt } else { 0 }) |
  (if (held & @ui.mod_ctrl) != 0 { mod_ctrl } else { 0 }) |
  (if (held & @ui.mod_cmd) != 0 { mod_meta } else { 0 }) |
  (if (held & @ui.mod_shift_key) != 0 { mod_shift } else { 0 })
}

///|
/// Whether a station's host OS string names an Apple system (macOS / Darwin); None until known.
fn os_is_apple(os : String) -> Bool? {
  let low = os.trim().to_lower()
  if low == "" {
    None
  } else {
    Some(low.has_prefix("mac") || low.has_prefix("darwin"))
  }
}

///|
/// Whether the remote screen uses Apple-style ⌘ shortcuts (vs Ctrl): Android emulators use Ctrl even when hosted on a
/// Mac, iOS Simulators use ⌘, and other screens follow their station's host OS.
fn screen_remote_apple(s : ScreenSess) -> Bool? {
  if s.screen.has_prefix("android:") {
    Some(false)
  } else if s.simulator() {
    Some(true)
  } else {
    os_is_apple(screen_os(s.src, s.station))
  }
}

///|
/// Whether this device's keyboard uses Apple-style ⌘ shortcuts (@ui.keys_system: 0 macOS, 1 iOS, else Ctrl; <0 unknown).
fn screen_local_apple() -> Bool? {
  let sys = @ui.keys_system()
  if sys < 0 {
    None
  } else {
    Some(sys == 0 || sys == 1)
  }
}

///|
/// Whether this device and the remote screen use opposite primary shortcut modifiers (Apple ⌘ vs Windows/Linux/Android
/// Ctrl). False while either system is unknown.
fn screen_cross_os(s : ScreenSess) -> Bool {
  match (screen_local_apple(), screen_remote_apple(s)) {
    (Some(local_apple), Some(remote_apple)) => local_apple != remote_apple
    _ => false
  }
}

///|
/// Whether cross-OS shortcut mapping is enabled on this device (`prefs.screenKeyMap`: `"off"` raw keys, default on).
fn screen_key_map_on(src : Source) -> Bool {
  @settings.pref_from(src.topic("prefs", {}).get().value, "screenKeyMap") != "off"
}

///|
/// Whether physical Control stays Ctrl (instead of mapping to Win/Meta) when an Apple device drives Windows/Linux/Android
/// (`prefs.screenKeepCtrl`: `"off"` maps ⌃ → Win, default on so terminal ⌃C/⌃D work without triggering Win shortcuts).
fn screen_keep_ctrl_on(src : Source) -> Bool {
  @settings.pref_from(src.topic("prefs", {}).get().value, "screenKeepCtrl") != "off"
}

///|
/// Whether `s` currently keeps physical Control as Ctrl (only applies when Apple drives Windows/Linux/Android).
fn screen_keep_ctrl(s : ScreenSess) -> Bool {
  screen_local_apple() == Some(true) && screen_remote_apple(s) == Some(false) && screen_keep_ctrl_on(s.src)
}

///|
/// Whether physical keyboard/mouse modifiers should map cross-OS shortcuts for `s` right now.
fn screen_swaps_ctrl_meta(s : ScreenSess) -> Bool {
  screen_key_map_on(s.src) && screen_cross_os(s)
}

///|
/// Swaps `mod_ctrl` and `mod_meta` in `mods`, leaving `mod_alt` and `mod_shift` untouched.
fn swap_ctrl_meta(mods : Int) -> Int {
  let base = mods & (mod_ctrl | mod_meta).lnot()
  let c = if (mods & mod_ctrl) != 0 { mod_meta } else { 0 }
  let m = if (mods & mod_meta) != 0 { mod_ctrl } else { 0 }
  base | c | m
}

///|
/// Remaps `mod_ctrl` and `mod_meta` for cross-OS input: two-way swap unless `keep_ctrl` keeps physical Control as Ctrl
/// while still mapping ⌘ → Ctrl.
fn remap_ctrl_meta(mods : Int, keep_ctrl : Bool) -> Int {
  if !keep_ctrl {
    swap_ctrl_meta(mods)
  } else {
    let base = mods & mod_meta.lnot()
    if (mods & mod_meta) != 0 { base | mod_ctrl } else { base }
  }
}

///|
/// Remaps a physical key event `(key, code, mods)` when cross-OS shortcut mapping is active:
/// - Semantic text-editing and navigation shortcuts (word jump/delete, line/document bounds) translate between Apple and
///   Windows/Linux conventions so `Ctrl+Backspace` deletes a word instead of a whole line on Mac and `⌥←` moves a word
///   instead of navigating Back on Windows.
/// - Other shortcuts remap Ctrl ↔ ⌘ (or map ⌘ → Ctrl while keeping ⌃ as Ctrl on Mac → Windows/Linux when `screenKeepCtrl`
///   is on).
fn remap_screen_key(s : ScreenSess, key : String, code : String, mods : Int) -> (String, String, Int) {
  if !screen_swaps_ctrl_meta(s) {
    return (key, code, mods)
  }
  let shift = mods & mod_shift
  let non_shift = mods & mod_shift.lnot()
  match (screen_local_apple(), screen_remote_apple(s)) {
    (Some(false), Some(true)) => {
      if non_shift == 0 {
        match code {
          "Home" => return ("ArrowLeft", "ArrowLeft", mod_meta | shift)
          "End" => return ("ArrowRight", "ArrowRight", mod_meta | shift)
          _ => ()
        }
      }
      if non_shift == mod_ctrl {
        match code {
          "ArrowLeft" | "ArrowRight" => return (key, code, mod_alt | shift)
          "Backspace" | "Delete" if shift == 0 => return (key, code, mod_alt)
          "Home" => return ("ArrowUp", "ArrowUp", mod_meta | shift)
          "End" => return ("ArrowDown", "ArrowDown", mod_meta | shift)
          _ => ()
        }
      }
    }
    (Some(true), Some(false)) => {
      if non_shift == mod_alt {
        match code {
          "ArrowLeft" | "ArrowRight" => return (key, code, mod_ctrl | shift)
          "Backspace" | "Delete" if shift == 0 => return (key, code, mod_ctrl)
          _ => ()
        }
      }
      if non_shift == mod_meta {
        match code {
          "ArrowLeft" => return ("Home", "Home", shift)
          "ArrowRight" => return ("End", "End", shift)
          "ArrowUp" => return ("Home", "Home", mod_ctrl | shift)
          "ArrowDown" => return ("End", "End", mod_ctrl | shift)
          _ => ()
        }
      }
    }
    _ => ()
  }
  let keep_ctrl = screen_keep_ctrl(s)
  let next_mods = remap_ctrl_meta(mods, keep_ctrl)
  let next_key = match key {
    "Meta" => "Control"
    "Control" if !keep_ctrl => "Meta"
    _ => key
  }
  let next_code = match code {
    "MetaLeft" => "ControlLeft"
    "MetaRight" => "ControlRight"
    "ControlLeft" if !keep_ctrl => "MetaLeft"
    "ControlRight" if !keep_ctrl => "MetaRight"
    _ => code
  }
  (next_key, next_code, next_mods)
}

///|
/// Remaps held keyboard modifiers for mouse click/wheel events when cross-OS shortcut mapping is active.
fn screen_remap_mods(s : ScreenSess, mods : Int) -> Int {
  if screen_swaps_ctrl_meta(s) {
    remap_ctrl_meta(mods, screen_keep_ctrl(s))
  } else {
    mods
  }
}

///|
/// Whether a key-down with `code`, physical `raw_mods`, and remapped `mapped_mods` is the local clipboard paste shortcut.
/// With cross-OS mapping on, follows this device's paste key (⌘V on Apple so terminal/Vim ⌃V stays raw Ctrl+V; Ctrl+V on
/// Windows/Linux so Win+V stays raw ⌃V). Otherwise follows the remote OS's paste key.
fn is_paste_key(s : ScreenSess, code : String, raw_mods : Int, mapped_mods : Int) -> Bool {
  guard code == "KeyV" && (raw_mods & mod_alt) == 0 && (mapped_mods & mod_alt) == 0 else { return false }
  if screen_swaps_ctrl_meta(s) {
    match screen_local_apple() {
      Some(true) => (raw_mods & mod_meta) != 0 && (raw_mods & mod_ctrl) == 0
      Some(false) => (raw_mods & mod_ctrl) != 0 && (raw_mods & mod_meta) == 0
      None => false
    }
  } else {
    match screen_remote_apple(s) {
      Some(true) => (mapped_mods & mod_meta) != 0 && (mapped_mods & mod_ctrl) == 0
      Some(false) => (mapped_mods & mod_ctrl) != 0 && (mapped_mods & mod_meta) == 0
      None => (mapped_mods & (mod_meta | mod_ctrl)) != 0
    }
  }
}

///|
/// The modifier keys of `mods`, each its key going `kind` ("down" before a press, "up" after it), so a click with ⇧ or
/// ⌘ held is one there too (a key held alone never comes to a key catcher). Each key's event says the modifiers held
/// after it, as a keyboard's do: a down with itself, an up without itself.
fn mods_round(send : (Json) -> Unit, mods : Int, kind : String) -> Unit {
  let mut held = if kind == "down" { 0 } else { mods }
  for k in [
    (mod_meta, "Meta", "MetaLeft"),
    (mod_ctrl, "Control", "ControlLeft"),
    (mod_alt, "Alt", "AltLeft"),
    (mod_shift, "Shift", "ShiftLeft"),
  ] {
    if (mods & k.0) != 0 {
      held = if kind == "down" { held | k.0 } else { held & k.0.lnot() }
      send(key_input(kind, k.1, k.2, held))
    }
  }
}

///|
/// The station's pointer's shape (a CSS cursor's name) as this device draws its own.
fn cursor_of_shape(shape : String) -> @ui.Cursor {
  match shape {
    "pointer" => Hand
    "text" | "vertical-text" => IBeam
    "ew-resize" | "col-resize" | "e-resize" | "w-resize" => ResizeX
    "ns-resize" | "row-resize" | "n-resize" | "s-resize" => ResizeY
    "nwse-resize" | "nw-resize" | "se-resize" => ResizeNWSE
    "nesw-resize" | "ne-resize" | "sw-resize" => ResizeNESW
    "grab" | "move" | "all-scroll" => Grab
    "grabbing" => Grabbing
    "crosshair" => Crosshair
    "not-allowed" | "no-drop" => NotAllowed
    _ => Arrow
  }
}

///|
/// The modifiers tapped on the keys row (⌘ ⌃ ⌥ ⇧, which a phone's keyboard has not): held for the next key or
/// character, then let go, as a phone's own shift is.
priv struct HeldKeys {
  mut mods : Int
  /// each change of `mods` (what shows them held reads it)
  told : @signals.Signal[Int]
}

///|
fn held_keys_new() -> HeldKeys {
  { mods: 0, told: @signals.signal(0) }
}

///|
fn HeldKeys::toggle(self : HeldKeys, bit : Int) -> Unit {
  self.mods = self.mods ^ bit
  self.told.set(self.told.untracked() + 1)
}

///|
/// What is held, for a key now: let go of after it.
fn HeldKeys::take(self : HeldKeys) -> Int {
  let m = self.mods
  if m != 0 {
    self.mods = 0
    self.told.set(self.told.untracked() + 1)
  }
  m
}

///|
/// What is held now, as it is told (what shows a modifier held reads it).
fn HeldKeys::held_said(self : HeldKeys) -> Int {
  self.told.get() |> ignore
  self.mods
}

///|
/// The DOM's `code` of a character typed with a modifier held (⌘ then c: KeyC); "" for one with no key of its own.
fn code_of(ch : Char) -> String {
  let c = if ch >= 'A' && ch <= 'Z' { (ch.to_int() + 32).unsafe_to_char() } else { ch }
  if c >= 'a' && c <= 'z' {
    return "Key" + (c.to_int() - 32).unsafe_to_char().to_string()
  }
  if c >= '0' && c <= '9' {
    return "Digit" + c.to_string()
  }
  match c {
    ' ' => "Space"
    '-' => "Minus"
    '=' => "Equal"
    '[' => "BracketLeft"
    ']' => "BracketRight"
    '\\' => "Backslash"
    ';' => "Semicolon"
    '\'' => "Quote"
    ',' => "Comma"
    '.' => "Period"
    '/' => "Slash"
    '`' => "Backquote"
    _ => ""
  }
}

///|
/// Words typed (committed by the keyboard: KeyCatcher.type): lines as text, Enter between them; with a modifier held
/// on the keys row, each character as its key with it (⌘ then c: ⌘C).
fn type_words(send : (Json) -> Unit, held : HeldKeys, words : String) -> Unit {
  let mods = held.take()
  if mods != 0 {
    for ch in words {
      if ch == '\n' {
        stroke(send, "Enter", "Enter", mods)
      } else {
        stroke(send, ch.to_string(), code_of(ch), mods)
      }
    }
    return
  }
  for i, line in words.split("\n").to_array() {
    if i > 0 {
      stroke(send, "Enter", "Enter", 0)
    }
    if line.length() > 0 {
      send(text_input(line.to_owned()))
    }
  }
}

///|
/// The frame's own zoom, on this device only (never sent): mbui's @motion.Zoom, the frame fitted edge to edge (larger
/// than its pixels where the stage has room), zoomed from the fitted size to `screen_max_zoom` times it. Kept within
/// the stage: smaller than it, centred; larger, no gap at its edges.
fn screen_zoom() -> @motion.Zoom {
  @motion.Zoom::new(margin=fn(_) { 0.0 }, enlarge=true, min_scale=fn(fit) { fit }, max_scale=fn(fit) {
    fit * screen_max_zoom
  })
}

///|
/// The most a screen is zoomed in, over its fitted size.
let screen_max_zoom : Double = 5.0

///|
/// Where the frame is drawn on the stage at `at` (zoomed, its glide or fling as far as it has gone then); nothing before
/// its size is known.
fn ScreenUi::shown_at(self : ScreenUi, at : Double) -> SRect {
  match self.zoom.rect_at(at) {
    Some((x, y, w, h)) => cased_in({ x, y, w, h }, self.case_x, self.case_y)
    None => srect_zero
  }
}

///|
/// The part of the frame in sight at `at` while it is zoomed in (0..1 of it each way); None while it is not (all of it
/// is).
fn ScreenUi::in_sight_at(self : ScreenUi, at : Double) -> Part? {
  let s = self.shown_at(at)
  let (bw, bh) = (self.box_w.untracked(), self.box_h.untracked())
  if !self.zoom.zoomed_at(at) || s.w <= 0.0 || s.h <= 0.0 || bw <= 0.0 || bh <= 0.0 {
    return None
  }
  let x0 = dmax(0.0, -s.x / s.w)
  let y0 = dmax(0.0, -s.y / s.h)
  let x1 = dmin(1.0, (bw - s.x) / s.w)
  let y1 = dmin(1.0, (bh - s.y) / s.h)
  if x1 <= x0 || y1 <= y0 {
    None
  } else {
    Some(({ x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : Part))
  }
}

///|
/// How far the pointer goes for a finger's move of 1 px, by how fast it moves (dp per ms, smoothed: pad_speed), as a
/// desktop's trackpad does: slowly (up to 0.08) a steady 0.42 of the finger, to land on a 12 px close button; at the
/// pace of most moves (to 0.9) eased up to 1.75; fast eased on to 2.75 (by 2.1), to cross a 4K screen in a stroke.
/// Smooth throughout (no step in it, nor in how fast it grows where its parts meet), so speeding up never jolts it.
fn pad_gain(dp_per_ms : Double) -> Double {
  let ease = fn(t : Double) {
    let t = clamp01(t)
    t * t * (3.0 - 2.0 * t)
  }
  if dp_per_ms <= pad_fine_speed {
    pad_fine_gain
  } else if dp_per_ms <= pad_usual_speed {
    pad_fine_gain + (pad_usual_gain - pad_fine_gain) * ease((dp_per_ms - pad_fine_speed) / (pad_usual_speed - pad_fine_speed))
  } else {
    pad_usual_gain + (pad_most_gain - pad_usual_gain) * ease((dp_per_ms - pad_usual_speed) / pad_fast_span)
  }
}

///|
/// pad_gain's parts: how fast a finger goes (dp per ms) to its end of each, and the gain there.
let pad_fine_speed : Double = 0.08

///|
let pad_usual_speed : Double = 0.9

///|
let pad_fast_span : Double = 1.2

///|
let pad_fine_gain : Double = 0.42

///|
let pad_usual_gain : Double = 1.75

///|
let pad_most_gain : Double = 2.75

///|
/// How long a trackpad's finger's pace is smoothed over (ms): a touch screen's samples come unevenly, one quick and the
/// next slow, and the pointer would jerk with each.
let pad_speed_tau : Double = 24.0

///|
/// The pace `was` (dp per ms) smoothed with a move of `dist` dp over `dt` ms: each move counts by how long it took
/// (1 - e^(-dt/τ)), so as many samples a second as come give the same pace. None before: the move's own.
fn pad_speed(was : Double?, dist : Double, dt : Double, tau? : Double = pad_speed_tau) -> Double {
  let now = dist / dt
  match was {
    None => now
    Some(v) => v + (now - v) * (1.0 - @dmath.exp(-dt / tau))
  }
}

///|
/// Two fingers' scroll let go of still moving, going on by itself as a desktop's trackpad's does: their pace (stage px
/// per ms) as they let go dying away by e^(-t/τ), so the way gone by `t` ms is v·τ·(1 - e^(-t/τ)) — worked out from
/// when it began, not stepped frame by frame, so it goes as far at any frame rate — till its pace is under
/// `fling_least`; sent as the wheel at `where` (0..1) each frame drawn meanwhile, what was not sent yet. A press, a
/// wheel, or not driving any more stops it where it is.
priv struct ScrollFling {
  mut from : Double
  mut until : Double
  mut vx : Double
  mut vy : Double
  mut where_ : (Double, Double)
  mut sent_x : Double
  mut sent_y : Double
  /// each start or stop of it (what sends it reads it, its end followed as it is drawn: View::drawn_while)
  told : @signals.Signal[Int]
}

///|
/// How fast two fingers let go of must be going for their scroll to go on (stage px per ms), the most it goes on at,
/// how fast it dies away (ms) and the pace it stops at.
let fling_start : Double = 0.18

///|
let fling_most : Double = 4.5

///|
let fling_tau : Double = 260.0

///|
let fling_least : Double = 0.02

///|
/// How long two fingers' pace is smoothed over (ms), and how long they may have been still before they are let go of
/// for none to go on (they had stopped).
let fling_speed_tau : Double = 32.0

///|
let fling_still_ms : Double = 60.0

///|
fn scroll_fling_new() -> ScrollFling {
  {
    from: 0.0,
    until: -@double.infinity,
    vx: 0.0,
    vy: 0.0,
    where_: (0.5, 0.5),
    sent_x: 0.0,
    sent_y: 0.0,
    told: @signals.signal(0),
  }
}

///|
/// Whether it goes at `t`.
fn ScrollFling::goes_at(self : ScrollFling, t : Double) -> Bool {
  t >= self.from && t < self.until
}

///|
/// The way gone by `t` (stage px each way), as far as its end at most.
fn ScrollFling::gone_at(self : ScrollFling, t : Double) -> (Double, Double) {
  let k = fling_tau * (1.0 - @dmath.exp(-(dmin(t, self.until) - self.from) / fling_tau))
  (self.vx * k, self.vy * k)
}

///|
/// Started at `at`, two fingers let go going (vx, vy) stage px per ms, the wheel at `where_`: only where that is fast
/// enough (fling_start), as fast as fling_most at most. Whether it started.
fn ScrollFling::start(
  self : ScrollFling,
  at : Double,
  vx : Double,
  vy : Double,
  where_ : (Double, Double),
) -> Bool {
  let speed = (vx * vx + vy * vy).sqrt()
  if speed < fling_start {
    return false
  }
  let k = if speed > fling_most { fling_most / speed } else { 1.0 }
  self.from = at
  self.vx = vx * k
  self.vy = vy * k
  // (its pace under fling_least from then: v·e^(-t/τ) < least)
  self.until = at + fling_tau * @dmath.ln(speed * k / fling_least)
  self.where_ = where_
  self.sent_x = 0.0
  self.sent_y = 0.0
  self.told.set(self.told.untracked() + 1)
  true
}

///|
/// Stopped where it is (nothing more sent), if it goes.
fn ScrollFling::stop(self : ScrollFling) -> Unit {
  if self.until == -@double.infinity {
    return
  }
  self.until = -@double.infinity
  self.told.set(self.told.untracked() + 1)
}

///|
/// What of its way is not sent yet by `t` (stage px each way), taken as sent.
fn ScrollFling::take_at(self : ScrollFling, t : Double) -> (Double, Double) {
  if self.until == -@double.infinity || t < self.from {
    return (0.0, 0.0)
  }
  let (x, y) = self.gone_at(t)
  let d = (x - self.sent_x, y - self.sent_y)
  self.sent_x = x
  self.sent_y = y
  d
}

///|
/// Where the pointer is as the trackpad moves it (0..1 of the frame), ahead of the station saying so; `placed` once it
/// was moved or started where the station said its pointer is. Never set again from the station as it goes: that lags
/// the pad by the way there and back, and a quick second stroke would jump back.
priv struct PadPointer {
  mut x : Double
  mut y : Double
  mut placed : Bool
  /// each move of it (what draws it reads it)
  told : @signals.Signal[Int]
}

///|
fn pad_pointer_new() -> PadPointer {
  { x: 0.5, y: 0.5, placed: false, told: @signals.signal(0) }
}

///|
/// Started where the station says its pointer is (`at`), when it says.
fn PadPointer::start_at(self : PadPointer, at : (Double, Double)?) -> Unit {
  guard at is Some((x, y)) else { return }
  self.x = clamp01(x)
  self.y = clamp01(y)
  self.placed = true
  self.told.set(self.told.untracked() + 1)
}

///|
fn PadPointer::at(self : PadPointer) -> (Double, Double) {
  (self.x, self.y)
}

///|
/// Where it is and whether it was placed, as it is told (what draws it reads it).
fn PadPointer::placed_said(self : PadPointer) -> ((Double, Double), Bool) {
  self.told.get() |> ignore
  ((self.x, self.y), self.placed)
}

///|
fn PadPointer::by(self : PadPointer, dx : Double, dy : Double) -> Unit {
  self.placed = true
  self.x = clamp01(self.x + dx)
  self.y = clamp01(self.y + dy)
  self.told.set(self.told.untracked() + 1)
}
