// The station user's X11 desktop (src/screens/x11-desktop.ts). ffmpeg captures it and xdotool posts input;
// LinuxScreenTools can prepare them when the machine has no pair of its own. A view keeps only the newest frame, so a
// slow client cannot build a queue of old pictures. Wayland needs its own portal: an Xwayland DISPLAY alone does not
// capture the Wayland desktop.

///|
const X11_MAX_FRAME : Int = 16777216

///|
const X11_OPEN_TIMEOUT : Double = 10000

///|
const X11_FRESH_MS : Double = 2000

///|
/// xdotool temporarily changes the X keymap for characters outside the layout. Give applications time to read it.
const TYPE_DELAY_MS : Double = 20

///|
/// What the X11 desktop is given (x11-desktop.ts `X11DesktopOptions`): who is told it changed, its title, what
/// prepares its programs, its environment (none: the station's) and its own binaries (a test's).
pub(all) struct X11DesktopOptions {
  changed : () -> Unit
  title : (() -> String)?
  tools : LinuxScreenTools?
  mut env : Env?
  ffmpeg : String?
  xdotool : String?
  prepare_wait_ms : Double?
}

///|
/// The X11 desktop (x11-desktop.ts `X11Desktop`).
pub struct X11Desktop {
  priv io : Io
  priv o : X11DesktopOptions
  priv views : Array[(Int, () -> Unit)]
  priv mut h264 : @effect.Deferred[Bool]?
  priv mut h264_path : String?
  priv mut size_ : (Double, Double)
  priv mut reason : String?
  priv mut looked : Double
  priv looking : Shared[Unit]
  priv mut preparing : @effect.Deferred[Unit]?
  priv mut prepare_failed : Bool
  priv mut closed : Bool
  priv mut next_view : Int
}

///|
pub fn X11Desktop::new(io : Io, o : X11DesktopOptions) -> X11Desktop {
  {
    io,
    o,
    views: [],
    h264: None,
    h264_path: None,
    size_: (0.0, 0.0),
    reason: Some("linuxNoDisplay"),
    looked: 0.0,
    looking: Shared::new(),
    preparing: None,
    prepare_failed: false,
    closed: false,
    next_view: 0,
  }
}

///|
/// Its environment now (the options' own, which its desktop's owner sets anew, else the station's).
pub fn X11Desktop::set_env(self : X11Desktop, env : Env) -> Unit {
  self.o.env = Some(env)
}

///|
fn X11Desktop::env(self : X11Desktop) -> Env {
  match self.o.env {
    Some(e) => e
    None => (self.io.os.env)()
  }
}

///|
pub fn X11Desktop::title(self : X11Desktop) -> String {
  match self.o.title {
    Some(f) => f()
    None => (self.io.os.hostname)()
  }
}

///|
pub fn X11Desktop::size(self : X11Desktop) -> (Double, Double) {
  self.size_
}

///|
pub fn X11Desktop::access(self : X11Desktop) -> ScreenAccess {
  match self.reason {
    Some(r) => ScreenAccess::new(false, false, reason=Some(r))
    None => ScreenAccess::new(true, true)
  }
}

///|
async fn X11Desktop::binaries(self : X11Desktop, env : Env) -> LinuxToolPair? {
  let ffmpeg = executable(self.io, self.o.ffmpeg.unwrap_or("ffmpeg"), env)
  let xdotool = executable(self.io, self.o.xdotool.unwrap_or("xdotool"), env)
  match (ffmpeg, xdotool) {
    (Some(f), Some(x)) => return Some({ ffmpeg: f, xdotool: x, env })
    _ => ()
  }
  if self.o.ffmpeg.unwrap_or("") != "" || self.o.xdotool.unwrap_or("") != "" {
    return None
  }
  match self.o.tools {
    Some(t) => t.prepared(env)
    None => None
  }
}

///|
async fn X11Desktop::prepare(self : X11Desktop, env : Env) -> Unit {
  guard self.o.tools is Some(tools) else { return }
  if self.preparing is Some(_) || !tools.can_prepare(env) || self.preparing is Some(_) {
    return
  }
  self.prepare_failed = false
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.preparing = Some(d)
  (self.io.spawn)(async fn() {
    tools.prepare(env) catch {
      _ => {
        self.prepare_failed = true
        if !self.closed {
          self.io.log.warn("screen", "could not prepare the Linux screen tools")
        }
      }
    }
    self.preparing = None
    if !self.closed {
      self.io.go(async fn() { self.refresh(force=true) })
    }
    ignore(d.succeed(()))
  })
}

///|
/// Ask the X server in the station's own session; neither a display name nor a running process implies access.
pub async fn X11Desktop::refresh(self : X11Desktop, force? : Bool = false) -> Unit {
  if !force && self.io.clock.ms() - self.looked < X11_FRESH_MS {
    return
  }
  self.looking
  .start(self.io, async fn() {
    let r = try Ok(self.inspect()) catch { e => Err(e) }
    match r {
      Ok((size, reason)) =>
        if size != self.size_ || reason != self.reason {
          self.size_ = size
          self.reason = reason
          (self.o.changed)()
        }
      Err(_) => ()
    }
    self.looked = self.io.clock.ms()
    match r {
      Err(e) => raise e
      _ => ()
    }
  })
  .wait()
}

///|
/// `/^(\d+)\s+(\d+)\s*$/`.
fn geometry_of(s : String) -> (String, String)? {
  let r = Reader::new(s, 0)
  guard r.digits() is Some(w) else { return None }
  if !r.spaces1() {
    return None
  }
  guard r.digits() is Some(h) else { return None }
  r.spaces()
  if r.at != r.s.length() {
    return None
  }
  Some((w, h))
}

///|
async fn X11Desktop::inspect(self : X11Desktop) -> ((Double, Double), String?) {
  let env = self.env()
  let empty = (0.0, 0.0)
  if env.get("XDG_SESSION_TYPE").map(t => t.to_lower()) == Some("wayland") || env.truthy("WAYLAND_DISPLAY") is Some(_) {
    return (empty, Some("linuxWayland"))
  }
  if env.truthy("DISPLAY") is None {
    return (empty, Some("linuxNoDisplay"))
  }
  guard self.binaries(env) is Some(pair) else {
    return (
      empty,
      Some(if self.preparing is Some(_) { "linuxToolsPreparing" } else if self.prepare_failed { "linuxToolsFailed" } else { "linuxTools" }),
    )
  }
  try {
    let out = (self.io.procs.exec)(pair.xdotool, ["getdisplaygeometry"], ExecOptions::new(env=Some(pair.env), timeout=Some(3000.0)))
    guard geometry_of(out) is Some((ws, hs)) else { raise fail("invalid display size") }
    let width = js_number(ws)
    let height = js_number(hs)
    if !is_integer(width) || !is_integer(height) || width < 2.0 || height < 2.0 || width > 16384.0 || height > 16384.0 {
      raise fail("invalid display size")
    }
    ((width, height), None)
  } catch {
    _ => (empty, Some("linuxUnavailable"))
  }
}

///|
fn X11Desktop::forget(self : X11Desktop, id : Int) -> Unit {
  take_out(self.views, id)
}

///|
pub async fn X11Desktop::open(self : X11Desktop, options : ViewOptions) -> ScreenView {
  if !options.codecs.contains(Jpeg) && !options.codecs.contains(H264) {
    raise self.io.refused(415, "station.screen.codec", args=jo([("codec", js("H.264 or JPEG"))]))
  }
  self.refresh(force=true)
  let env = self.env()
  if self.reason == Some("linuxTools") || self.reason == Some("linuxToolsFailed") {
    self.prepare(env)
  }
  match self.preparing {
    Some(preparing) => {
      // A first opening can take the pair as soon as it is ready. If a download takes longer, say so and let the
      // person reopen it; preparation continues even if the view was closed in the meantime.
      let d : @effect.Deferred[Unit] = @effect.Deferred::new()
      let stop = (self.io.clock.after)(self.o.prepare_wait_ms.unwrap_or(8000.0), () => ignore(d.succeed(())))
      self.io.go(async fn() {
        preparing.wait()
        stop()
        ignore(d.succeed(()))
      })
      d.wait()
      self.refresh(force=true)
    }
    None => ()
  }
  match self.reason {
    Some(r) => raise self.io.refused(503, "station.screen.\{r}", access=Some(self.access()))
    None => ()
  }
  // Both were found by refresh, but may have been removed since.
  guard self.binaries(env) is Some(pair) else {
    raise self.io.refused(503, "station.screen.linuxTools", access=Some(ScreenAccess::new(false, false, reason=Some("linuxTools"))))
  }
  let ffmpeg = pair.ffmpeg
  let xdotool = pair.xdotool
  let child_env = pair.env
  if options.codecs.contains(H264) {
    if self.h264_path != Some(ffmpeg) {
      self.h264_path = Some(ffmpeg)
      self.h264 = None
    }
    let h264 = match self.h264 {
      Some(d) => d
      None => {
        let d : @effect.Deferred[Bool] = @effect.Deferred::new()
        self.h264 = Some(d)
        self.io.go(async fn() {
          let found = try {
            has_word(
              (self.io.procs.exec)(ffmpeg, ["-hide_banner", "-encoders"], ExecOptions::new(env=Some(child_env), timeout=Some(3000.0))),
              "libx264",
            )
          } catch {
            _ => false
          }
          ignore(d.succeed(found))
        })
        d
      }
    }
    if h264.wait() {
      self.next_view += 1
      let id = self.next_view
      let view = X11H264View::new(self.io, ffmpeg, xdotool, child_env, self.size_, options, () => self.forget(id))
      self.views.push((id, () => view.close()))
      try {
        view.video_.ready.wait()
        return view.view()
      } catch {
        error => {
          view.close()
          if !options.codecs.contains(Jpeg) {
            raise self.io.refused(503, "station.screen.failed", args=jo([("said", js(message_of(error)))]))
          }
        }
      }
    } else if !options.codecs.contains(Jpeg) {
      raise self.io.refused(415, "station.screen.codec", args=jo([("codec", js("H.264"))]))
    }
  }
  self.next_view += 1
  let id = self.next_view
  let view = X11View::new(self.io, ffmpeg, xdotool, child_env, self.size_, options, () => self.forget(id))
  self.views.push((id, () => view.close()))
  try {
    view.ready.wait()
    view.view()
  } catch {
    error => {
      view.close()
      raise self.io.refused(503, "station.screen.failed", args=jo([("said", js(message_of(error)))]))
    }
  }
}

///|
/// `/\b<word>\b/.test(s)`.
fn has_word(s : String, word : String) -> Bool {
  let cs = s.to_array()
  let w = word.to_array()
  let wordy = (c : Char) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
  for i in 0..<cs.length() {
    if i + w.length() > cs.length() {
      break
    }
    let mut all = true
    for k in 0..<w.length() {
      if cs[i + k] != w[k] {
        all = false
        break
      }
    }
    if !all {
      continue
    }
    let before = i == 0 || wordy(cs[i - 1]) != wordy(w[0])
    let end = i + w.length()
    let after = end == cs.length() || wordy(cs[end]) != wordy(w[w.length() - 1])
    if before && after {
      return true
    }
  }
  false
}

///|
pub fn X11Desktop::close(self : X11Desktop) -> Unit {
  self.closed = true
  match self.o.tools {
    Some(t) => t.close()
    None => ()
  }
  for v in self.views.copy() {
    (v.1)()
  }
}

///|
pub fn X11Desktop::source(self : X11Desktop) -> ScreenSource {
  {
    ..ScreenSource::bare("desktop", DesktopKind, () => self.title(), () => self.size(), async fn(o) { self.open(o) }),
    access: Some(() => self.access()),
  }
}

///|
/// The JPEG encoder needs even dimensions and does not enlarge a screen beyond its native size.
fn fitted(size : (Double, Double), max_width : Double, max_height : Double) -> (Double, Double) {
  let scale = js_min(1.0, js_min(js_max(2.0, max_width) / size.0, js_max(2.0, max_height) / size.1))
  (
    js_max(2.0, (size.0 * scale / 2.0).floor() * 2.0),
    js_max(2.0, (size.1 * scale / 2.0).floor() * 2.0),
  )
}

///|
/// DOM KeyboardEvent.code is a physical position. Xorg's evdev keycodes are Linux input codes plus 8.
pub let evdev : Map[String, Int] = {
  "Escape": 1, "Digit1": 2, "Digit2": 3, "Digit3": 4, "Digit4": 5, "Digit5": 6, "Digit6": 7, "Digit7": 8, "Digit8": 9,
  "Digit9": 10, "Digit0": 11, "Minus": 12, "Equal": 13, "Backspace": 14, "Tab": 15, "KeyQ": 16, "KeyW": 17, "KeyE": 18,
  "KeyR": 19, "KeyT": 20, "KeyY": 21, "KeyU": 22, "KeyI": 23, "KeyO": 24, "KeyP": 25, "BracketLeft": 26,
  "BracketRight": 27, "Enter": 28, "ControlLeft": 29, "KeyA": 30, "KeyS": 31, "KeyD": 32, "KeyF": 33, "KeyG": 34,
  "KeyH": 35, "KeyJ": 36, "KeyK": 37, "KeyL": 38, "Semicolon": 39, "Quote": 40, "Backquote": 41, "ShiftLeft": 42,
  "Backslash": 43, "KeyZ": 44, "KeyX": 45, "KeyC": 46, "KeyV": 47, "KeyB": 48, "KeyN": 49, "KeyM": 50, "Comma": 51,
  "Period": 52, "Slash": 53, "ShiftRight": 54, "NumpadMultiply": 55, "AltLeft": 56, "Space": 57, "CapsLock": 58,
  "F1": 59, "F2": 60, "F3": 61, "F4": 62, "F5": 63, "F6": 64, "F7": 65, "F8": 66, "F9": 67, "F10": 68, "NumLock": 69,
  "ScrollLock": 70, "Numpad7": 71, "Numpad8": 72, "Numpad9": 73, "NumpadSubtract": 74, "Numpad4": 75, "Numpad5": 76,
  "Numpad6": 77, "NumpadAdd": 78, "Numpad1": 79, "Numpad2": 80, "Numpad3": 81, "Numpad0": 82, "NumpadDecimal": 83,
  "IntlBackslash": 86, "F11": 87, "F12": 88, "IntlRo": 89, "Convert": 92, "KanaMode": 93, "NonConvert": 94,
  "NumpadComma": 95, "NumpadEnter": 96, "ControlRight": 97, "NumpadDivide": 98, "PrintScreen": 99, "AltRight": 100,
  "Home": 102, "ArrowUp": 103, "PageUp": 104, "ArrowLeft": 105, "ArrowRight": 106, "End": 107, "ArrowDown": 108,
  "PageDown": 109, "Insert": 110, "Delete": 111, "AudioVolumeMute": 113, "AudioVolumeDown": 114, "AudioVolumeUp": 115,
  "NumpadEqual": 117, "Pause": 119, "Lang1": 122, "Lang2": 123, "IntlYen": 124, "MetaLeft": 125, "MetaRight": 126,
  "OSLeft": 125, "OSRight": 126, "ContextMenu": 127, "MediaTrackNext": 163, "MediaPlayPause": 164,
  "MediaTrackPrevious": 165, "MediaStop": 166, "F13": 183, "F14": 184, "F15": 185, "F16": 186, "F17": 187, "F18": 188,
  "F19": 189, "F20": 190, "F21": 191, "F22": 192, "F23": 193, "F24": 194,
}

///|
/// xdotool accepts a decimal string as a literal X keycode.
fn key_of(code : String) -> String? {
  evdev.get(code).map(e => (e + 8).to_string())
}

///|
let x11_mods : Array[(Int, Array[String])] = [
  (1, [key_of("AltLeft").unwrap(), key_of("AltRight").unwrap()]),
  (2, [key_of("ControlLeft").unwrap(), key_of("ControlRight").unwrap()]),
  (4, [key_of("MetaLeft").unwrap(), key_of("MetaRight").unwrap()]),
  (8, [key_of("ShiftLeft").unwrap(), key_of("ShiftRight").unwrap()]),
]

///|
let x11_buttons : Array[(Int, Int)] = [(1, 1), (2, 3), (4, 2)]

///|
/// One view's input on the X11 desktop through xdotool, one command after another.
priv struct X11Input {
  io : Io
  xdotool : String
  env : Env
  screen : (Double, Double)
  keys : Array[String]
  buttons : Array[Int]
  chain : Chain
  mut wheel_x : Double
  mut wheel_y : Double
  mut ended : Bool
}

///|
fn X11Input::new(io : Io, xdotool : String, env : Env, screen : (Double, Double)) -> X11Input {
  { io, xdotool, env, screen, keys: [], buttons: [], chain: Chain::new(), wheel_x: 0.0, wheel_y: 0.0, ended: false }
}

///|
async fn X11Input::command(self : X11Input, args : Array[String], timeout? : Double = 3000.0) -> Unit {
  ignore((self.io.procs.exec)(self.xdotool, args, ExecOptions::new(env=Some(self.env), timeout=Some(timeout))))
}

///|
async fn X11Input::typed(self : X11Input, t : String) -> Unit {
  self.command(
    ["type", "--delay", num_text(TYPE_DELAY_MS), "--", t],
    timeout=5000.0 + points_len(t).to_double() * TYPE_DELAY_MS * 3.0,
  )
}

///|
fn[T : Eq] remove_from(a : Array[T], v : T) -> Unit {
  match a.search(v) {
    Some(i) => ignore(a.remove(i))
    None => ()
  }
}

///|
fn[T : Eq] add_to(a : Array[T], v : T) -> Unit {
  if !a.contains(v) {
    a.push(v)
  }
}

///|
async fn X11Input::input(self : X11Input, event : ScreenInput) -> Unit {
  self.chain.then(self.io, async fn() {
    if self.ended {
      return
    }
    let (w, h) = self.screen
    let point = (x : Double, y : Double) => [
      num_text(js_max(0.0, js_min(w - 1.0, js_round(x * (w - 1.0))))),
      num_text(js_max(0.0, js_min(h - 1.0, js_round(y * (h - 1.0))))),
    ]
    match event {
      Pointer(x~, y~, buttons~, delta~, ..) => {
        // A relative move goes only as far as it says, wherever the pointer is (an app holding it).
        match delta {
          Some(d) if d.relative =>
            if d.moved && (d.dx != 0.0 || d.dy != 0.0) {
              self.command(["mousemove_relative", "--", num_text(js_round(d.dx)), num_text(js_round(d.dy))])
            }
          _ => self.command(["mousemove"] + point(x, y))
        }
        for b in x11_buttons {
          let (bit, button) = b
          let down = (buttons & bit) != 0
          let was = self.buttons.contains(button)
          if down == was {
            continue
          }
          self.command([if down { "mousedown" } else { "mouseup" }, button.to_string()])
          if down {
            add_to(self.buttons, button)
          } else {
            remove_from(self.buttons, button)
          }
        }
      }
      Wheel(x~, y~, dx~, dy~) => {
        self.command(["mousemove"] + point(x, y))
        self.wheel_x = self.wheel_x + dx / 100.0
        self.wheel_y = self.wheel_y + dy / 100.0
        for axis in ["x", "y"] {
          let value = if axis == "x" { self.wheel_x } else { self.wheel_y }
          let whole = js_trunc(value)
          if whole == 0.0 {
            continue
          }
          let count = js_min(20.0, abs_d(whole))
          let sign = if whole > 0.0 { 1.0 } else { -1.0 }
          if axis == "x" {
            self.wheel_x = self.wheel_x - sign * count
          } else {
            self.wheel_y = self.wheel_y - sign * count
          }
          let button = if axis == "y" {
            if whole > 0.0 {
              5
            } else {
              4
            }
          } else if whole > 0.0 {
            7
          } else {
            6
          }
          self.command(["click", "--repeat", num_text(count), "--delay", "0", button.to_string()])
        }
      }
      Key(kind~, key~, code~, mods~) => {
        guard key_of(code) is Some(k) else {
          if kind == "down" && points_len(key) == 1 && (mods & 6) == 0 {
            self.typed(key)
          }
          return
        }
        if kind == "up" {
          self.command(["keyup", k])
          remove_from(self.keys, k)
          return
        }
        let temporary = x11_mods
          .filter(m => (mods & m.0) != 0 && !m.1.contains(k) && !m.1.iter().any(x => self.keys.contains(x)))
          .map(m => m.1[0])
        for m in temporary {
          self.command(["keydown", m])
          add_to(self.keys, m)
        }
        self.command(["keydown", k])
        add_to(self.keys, k)
        for m in temporary.rev() {
          self.command(["keyup", m])
          remove_from(self.keys, m)
        }
      }
      Text(t) => if t != "" { self.typed(t) }
      _ => ()
    }
  })
}

///|
fn X11Input::close(self : X11Input) -> Unit {
  if self.ended {
    return
  }
  self.ended = true
  // Release anything this view pressed even if its client disappeared while dragging or typing.
  self.chain.after(self.io, async fn() {
    for k in self.keys.copy() {
      self.command(["keyup", k]) catch {
        _ => ()
      }
    }
    for b in self.buttons.copy() {
      self.command(["mouseup", b.to_string()]) catch {
        _ => ()
      }
    }
    self.keys.clear()
    self.buttons.clear()
  })
}

///|
/// A JPEG view of the X11 desktop: ffmpeg's MJPEG pictures, the newest kept.
priv struct X11View {
  io : Io
  ready : @effect.Deferred[Unit]
  mut child : Child?
  inputs : X11Input
  picture : (Double, Double)
  gone : () -> Unit
  carry : @buffer.Buffer
  mut latest : (Bytes, Double)?
  waiting : Array[(Frame?) -> Unit]
  mut config : Bool
  mut last_ts : Double
  mut ended : Bool
  mut opened : Bool
  mut timer : () -> Unit
  mut stderr : String
  mut why_ : String?
}

///|
fn X11View::new(
  io : Io,
  ffmpeg : String,
  xdotool : String,
  env : Env,
  screen : (Double, Double),
  options : ViewOptions,
  gone : () -> Unit,
) -> X11View {
  let picture = fitted(screen, options.max_width, options.max_height)
  let v = {
    io,
    ready: @effect.Deferred::new(),
    child: None,
    inputs: X11Input::new(io, xdotool, env, screen),
    picture,
    gone,
    carry: Buffer(),
    latest: None,
    waiting: [],
    config: true,
    last_ts: 0.0,
    ended: false,
    opened: false,
    timer: () => (),
    stderr: "",
    why_: None,
  }
  // Bound this experimental software encoder's CPU use even when a client asks for a higher frame rate.
  let fps = js_min(15.0, js_max(1.0, js_round(options.fps.unwrap_or(15.0))))
  let args = [
    "-nostdin", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "1", "-framerate", num_text(fps), "-video_size",
    "\{num_text(screen.0)}x\{num_text(screen.1)}", "-i", env.get("DISPLAY").unwrap_or(""), "-vf", "scale=\{num_text(picture.0)}:\{num_text(picture.1)}:flags=fast_bilinear",
    "-c:v", "mjpeg", "-q:v", "5", "-threads", "1", "-f", "image2pipe", "pipe:1",
  ]
  let child = (io.procs.spawn)(ffmpeg, args, SpawnOptions::piped(env=Some(env)), {
    out: d => v.read(d),
    err: d => v.stderr = last_units(v.stderr + @utf8.decode_lossy(d), 2000),
    error: e => v.end(e),
    close: (_, _) => v.end(if trim_js(v.stderr) != "" { trim_js(v.stderr) } else { "X11 capture ended" }),
  })
  v.child = Some(child)
  (child.end_input)(None)
  v.timer = (io.clock.after)(X11_OPEN_TIMEOUT, () => v.end("X11 capture did not produce a frame"))
  v
}

///|
fn X11View::read(self : X11View, chunk : Bytes) -> Unit {
  if self.ended {
    return
  }
  self.carry.write_bytes(chunk)
  while self.carry.length() > 0 {
    let all = self.carry.to_bytes()
    let start = index_of(all, b"\xff\xd8")
    if start < 0 {
      let keep = if all.length() - 1 > 0 { all.length() - 1 } else { 0 }
      self.carry.reset()
      self.carry.write_bytesview(all[keep:])
      return
    }
    let all = if start > 0 {
      let rest = Bytes::from_array(all[start:].to_array())
      self.carry.reset()
      self.carry.write_bytes(rest)
      rest
    } else {
      all
    }
    let end = index_of(all, b"\xff\xd9", from=2)
    if end < 0 {
      if all.length() > X11_MAX_FRAME {
        self.end("X11 frame is too large")
      }
      return
    }
    if end + 2 > X11_MAX_FRAME {
      self.end("X11 frame is too large")
      return
    }
    let data = Bytes::from_array(all[0:end + 2].to_array())
    self.carry.reset()
    self.carry.write_bytesview(all[end + 2:])
    let ts = js_max(self.last_ts + 1.0, self.io.clock.us())
    self.last_ts = ts
    if self.waiting.length() > 0 {
      (self.waiting.remove(0))(Some(self.frame(data, ts)))
    } else {
      self.latest = Some((data, ts))
    }
    if !self.opened {
      self.opened = true
      (self.timer)()
      ignore(self.ready.succeed(()))
    }
  }
}

///|
fn X11View::frame(self : X11View, data : Bytes, ts : Double) -> Frame {
  let config = if self.config {
    Some({ codec: Jpeg, width: self.picture.0, height: self.picture.1, description: None, region: None })
  } else {
    None
  }
  self.config = false
  { config, key: true, ts, data }
}

///|
async fn X11View::next(self : X11View) -> Frame? {
  if self.ended {
    return None
  }
  match self.latest {
    Some((data, ts)) => {
      self.latest = None
      return Some(self.frame(data, ts))
    }
    None => ()
  }
  let d : @effect.Deferred[Frame?] = @effect.Deferred::new()
  self.waiting.push(f => ignore(d.succeed(f)))
  d.wait()
}

///|
fn X11View::end(self : X11View, message : String, closed? : Bool = false) -> Unit {
  if self.ended {
    return
  }
  self.ended = true
  if !closed {
    self.why_ = Some(message)
  }
  (self.timer)()
  if !self.opened {
    ignore(self.ready.fail(fail(message)))
  }
  match self.child {
    Some(c) => (c.kill)("SIGTERM")
    None => ()
  }
  self.latest = None
  for w in self.waiting.copy() {
    w(None)
  }
  self.waiting.clear()
  self.inputs.close()
  (self.gone)()
}

///|
fn X11View::close(self : X11View) -> Unit {
  self.end("X11 view closed", closed=true)
}

///|
fn X11View::view(self : X11View) -> ScreenView {
  {
    ..ScreenView::bare(
      async fn() { self.next() },
      // Each JPEG is a key frame.
      () => (),
      async fn(e) { self.inputs.input(e) },
      () => self.close(),
    ),
    video: Some(() => { capture: "X11", encoder: Some("ffmpeg MJPEG (software)"), hardware: None }),
    why: Some(() => self.why_),
  }
}

///|
/// The same X11 input as the JPEG view, with an on-demand H.264 encoder for clients that can decode it.
priv struct X11H264View {
  inputs : X11Input
  video_ : X11H264
  gone : () -> Unit
  mut ended : Bool
}

///|
fn X11H264View::new(
  io : Io,
  ffmpeg : String,
  xdotool : String,
  env : Env,
  screen : (Double, Double),
  options : ViewOptions,
  gone : () -> Unit,
) -> X11H264View {
  // Raw frames live in memory while the encoder takes them; cap each view to a 4K picture.
  let picture = fitted(screen, js_min(options.max_width, 3840.0), js_min(options.max_height, 2160.0))
  let fps = js_min(15.0, js_max(1.0, js_round(options.fps.unwrap_or(15.0))))
  let me : Ref[X11H264View?] = Ref(None)
  let video = X11H264::new(io, ffmpeg, env, screen, picture, fps, options.bitrate, () => match me.val {
    Some(v) => v.close()
    None => ()
  })
  let v = { inputs: X11Input::new(io, xdotool, env, screen), video_: video, gone, ended: false }
  me.val = Some(v)
  v
}

///|
fn X11H264View::close(self : X11H264View) -> Unit {
  if self.ended {
    return
  }
  self.ended = true
  self.video_.close()
  self.inputs.close()
  (self.gone)()
}

///|
fn X11H264View::view(self : X11H264View) -> ScreenView {
  {
    ..ScreenView::bare(
      async fn() { self.video_.next() },
      () => self.video_.keyframe(),
      async fn(e) { self.inputs.input(e) },
      () => self.close(),
    ),
    rate: Some(b => self.video_.rate(b)),
    video: Some(() => self.video_.video()),
    why: Some(() => self.video_.why()),
  }
}
