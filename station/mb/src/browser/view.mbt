// A person's view of a tab of the station's browser (src/browser/view.ts): CDP's screencast for the frames (JPEG),
// Input.dispatch* for what they do, on a connection and a session of the view's own, so the agents' own sessions on
// the tab are left as they are. While a person drives it, its clipboard's text goes both ways (a binding the view's
// session adds while it is watched), and so do its login fields and its passkey sign-ins.
//
// Pull-driven: Chrome casts a frame only once those before it are acknowledged (it keeps at most two out), and a frame
// is acknowledged only when the one after it is asked for (`next`). Of two waiting, the newer is given and the older
// let go.

///|
/// `Math.round(x)`.
fn js_round(x : Double) -> Double {
  if x.is_nan() || x.is_inf() {
    x
  } else {
    (x + 0.5).floor()
  }
}

///|
/// The page's viewport in CSS pixels, as Page.getLayoutMetrics says it (what the screencast's frames show); None when
/// it says none.
pub fn viewport_of(m : J?) -> (Double, Double)? {
  let v = match at(m, "cssVisualViewport") {
    None | Some(Null) =>
      match at(m, "cssLayoutViewport") {
        None | Some(Null) => at(m, "layoutViewport")
        x => x
      }
    x => x
  }
  let width = js_round(js_num(at(v, "clientWidth")))
  let height = js_round(js_num(at(v, "clientHeight")))
  if width > 0.0 && height > 0.0 {
    Some((width, height))
  } else {
    None
  }
}

///|
/// JPEG quality of the cast frames: 82, as at 70 small text's edges rang (their colours bled round the strokes).
let quality : Int = 82

///|
/// The most pixels a CSS pixel is drawn with for a phone it is laid out for (`fit`).
let fit_scale_most : Double = 2.0

///|
/// At most this many frames are held unacknowledged (as Chrome sends at most).
let held_frames : Int = 2

///|
/// A press this soon after the last, this near it and of the same button, adds to its click count (a double click).
let click_ms : Double = 500.0

///|
let click_px : Double = 4.0

///|
fn ascii_at(b : Bytes, at_ : Int, s : String) -> Bool {
  if b.length() < at_ + s.length() {
    return false
  }
  for i in 0..<s.length() {
    if b[at_ + i].to_int() != s.unsafe_charcode_at(i) {
      return false
    }
  }
  true
}

///|
/// Whether an APP1 note (`Exif\0\0`, then a TIFF) says the picture is shown turned a quarter (orientation 5–8); None
/// for a note that is not EXIF or says no orientation (core-ts mediaFacts.ts `exifTurned`).
fn exif_turned(b : Bytes) -> Bool? {
  if b.length() < 14 || !ascii_at(b, 0, "Exif\u{0}\u{0}") {
    return None
  }
  let t = b[6:].to_bytes()
  let le = ascii_at(t, 0, "II")
  if !le && !ascii_at(t, 0, "MM") {
    return None
  }
  let u16 = (i : Int) => if i >= 0 && i + 2 <= t.length() {
    if le {
      t[i].to_int() | (t[i + 1].to_int() << 8)
    } else {
      (t[i].to_int() << 8) | t[i + 1].to_int()
    }
  } else {
    -1
  }
  let u32 = (i : Int) => if i >= 0 && i + 4 <= t.length() {
    let a = t[i].to_int64()
    let b_ = t[i + 1].to_int64()
    let c = t[i + 2].to_int64()
    let d = t[i + 3].to_int64()
    if le {
      a | (b_ << 8) | (c << 16) | (d << 24)
    } else {
      (a << 24) | (b_ << 16) | (c << 8) | d
    }
  } else {
    -1L
  }
  if u16(2) != 42 {
    return None
  }
  let ifd64 = u32(4)
  if ifd64 < 0L || ifd64 > 0x7fffffffL {
    return None
  }
  let ifd = ifd64.to_int()
  let count = u16(ifd)
  if count < 0 {
    return None
  }
  for i in 0..<count {
    let e = ifd + 2 + i * 12
    if u16(e) == 0x0112 {
      let o = u16(e + 8)
      return if o < 0 { None } else { Some(o >= 5 && o <= 8) }
    }
  }
  None
}

///|
/// A JPEG's size, from its frame header (SOFn); None when there is none (or it is no JPEG). The media reader's
/// (core-ts mediaFacts.ts `jpegSize`), its sides swapped where its EXIF orientation turns it a quarter.
pub fn jpeg_size(data : Bytes) -> (Int, Int)? {
  if data.length() < 4 || data[0] != b'\xff' || data[1] != b'\xd8' {
    return None
  }
  // (a film's header says `ftyp` at its fifth byte: no JPEG then)
  if data.length() >= 8 && ascii_at(data, 4, "ftyp") {
    return None
  }
  let get = (at_ : Int, n : Int) => if at_ >= 0 && n >= 0 && at_ + n <= data.length() {
    Some(data[at_:at_ + n].to_bytes())
  } else {
    None
  }
  let mut at_ = 2
  let mut turned = false
  for _step in 0..<256 {
    guard get(at_, 4) is Some(m) && m[0] == b'\xff' else { return None }
    let kind = m[1].to_int()
    if kind == 0xff {
      at_ += 1
      continue
    }
    if kind == 0x01 || (kind >= 0xd0 && kind <= 0xd8) {
      at_ += 2
      continue
    }
    if kind == 0xd9 || kind == 0xda {
      return None
    }
    let len = (m[2].to_int() << 8) | m[3].to_int()
    if len < 2 {
      return None
    }
    if kind == 0xe1 {
      match get(at_ + 4, len - 2) {
        Some(note) =>
          match exif_turned(note) {
            Some(t) => turned = t
            None => ()
          }
        None => ()
      }
    } else if kind >= 0xc0 && kind <= 0xcf && kind != 0xc4 && kind != 0xc8 && kind != 0xcc {
      guard get(at_ + 4, 5) is Some(f) else { return None }
      let height = (f[1].to_int() << 8) | f[2].to_int()
      let width = (f[3].to_int() << 8) | f[4].to_int()
      let (w, h) = if turned { (height, width) } else { (width, height) }
      return if w > 0 && h > 0 { Some((w, h)) } else { None }
    }
    at_ += 2 + len
  }
  None
}

///|
/// A point given as 0..1 of the frame, in the page's CSS pixels (what Input.dispatchMouseEvent takes).
pub fn to_viewport(x : Double, y : Double, viewport : (Double, Double)) -> (Double, Double) {
  let clamp = (v : Double) => if v.is_nan() || v.is_inf() {
    0.0
  } else if v < 0.0 {
    0.0
  } else if v > 1.0 {
    1.0
  } else {
    v
  }
  (clamp(x) * viewport.0, clamp(y) * viewport.1)
}

///|
/// The mouse buttons as PointerEvent.buttons has them, by CDP's names.
fn button_of(bits : Int) -> String {
  if (bits & 1) != 0 {
    "left"
  } else if (bits & 2) != 0 {
    "right"
  } else if (bits & 4) != 0 {
    "middle"
  } else if (bits & 8) != 0 {
    "back"
  } else if (bits & 16) != 0 {
    "forward"
  } else {
    "none"
  }
}

///|
/// Windows' virtual key codes of the keys that are no character (Chrome acts on them by these).
fn named_key(key : String) -> Int? {
  match key {
    "Backspace" => Some(8)
    "Tab" => Some(9)
    "Enter" => Some(13)
    "Shift" => Some(16)
    "Control" => Some(17)
    "Alt" => Some(18)
    "Pause" => Some(19)
    "CapsLock" => Some(20)
    "Escape" => Some(27)
    " " => Some(32)
    "PageUp" => Some(33)
    "PageDown" => Some(34)
    "End" => Some(35)
    "Home" => Some(36)
    "ArrowLeft" => Some(37)
    "ArrowUp" => Some(38)
    "ArrowRight" => Some(39)
    "ArrowDown" => Some(40)
    "Insert" => Some(45)
    "Delete" => Some(46)
    "Meta" => Some(91)
    "ContextMenu" => Some(93)
    _ => None
  }
}

///|
/// The punctuation keys' codes, by their code.
fn code_key(code : String) -> Int? {
  match code {
    "Space" => Some(32)
    "Semicolon" => Some(186)
    "Equal" => Some(187)
    "Comma" => Some(188)
    "Minus" => Some(189)
    "Period" => Some(190)
    "Slash" => Some(191)
    "Backquote" => Some(192)
    "BracketLeft" => Some(219)
    "Backslash" => Some(220)
    "BracketRight" => Some(221)
    "Quote" => Some(222)
    _ => None
  }
}

///|
pub fn key_code(key : String, code : String) -> Int {
  match named_key(key) {
    Some(n) => return n
    None => ()
  }
  // /^F([1-9]|1[0-9]|2[0-4])$/
  if key.has_prefix("F") && key.length() >= 2 && key.length() <= 3 && all_digits(slice(key, 1)) && !slice(key, 1).has_prefix("0") {
    let n = js_num(Some(js(slice(key, 1)))).to_int()
    if n >= 1 && n <= 24 {
      return 111 + n
    }
  }
  if code.length() == 4 && code.has_prefix("Key") {
    let c = code.unsafe_charcode_at(3)
    if c >= 'A'.to_int() && c <= 'Z'.to_int() {
      return c
    }
  }
  if code.length() == 6 && code.has_prefix("Digit") {
    let c = code.unsafe_charcode_at(5)
    if c >= '0'.to_int() && c <= '9'.to_int() {
      return c
    }
  }
  if code.length() == 7 && code.has_prefix("Numpad") {
    let c = code.unsafe_charcode_at(6)
    if c >= '0'.to_int() && c <= '9'.to_int() {
      return 96 + (c - '0'.to_int())
    }
  }
  match code_key(code) {
    Some(n) => return n
    None => ()
  }
  if key.length() == 1 {
    let c = key.unsafe_charcode_at(0)
    if c >= 'a'.to_int() && c <= 'z'.to_int() {
      return c - 32
    }
    if c >= 'A'.to_int() && c <= 'Z'.to_int() {
      return c
    }
    if c >= '0'.to_int() && c <= '9'.to_int() {
      return c
    }
  }
  0
}

///|
let mod_alt : Int = 1

///|
let mod_ctrl : Int = 2

///|
let mod_meta : Int = 4

///|
let mod_shift : Int = 8

///|
/// `x | 0` of a JavaScript number (ToInt32).
fn to_int32(d : Double) -> Int {
  if d.is_nan() || d.is_inf() {
    return 0
  }
  let t = if d < 0.0 { -((-d).floor()) } else { d.floor() }
  let m = t - (t / 4294967296.0).floor() * 4294967296.0
  m.to_int64().to_int()
}

///|
/// The number of code points of `s` (`[...s].length`).
fn point_count(s : String) -> Int {
  let mut n = 0
  for _ in s {
    n += 1
  }
  n
}

///|
/// A key press or release as Input.dispatchKeyEvent takes it (`e`: a ScreenInput of `t` key).
pub fn key_event(e : J) -> J {
  let ev = Some(e)
  let key = js_str(at(ev, "key"))
  let code = js_str(at(ev, "code"))
  let modifiers = to_int32(js_num(at(ev, "mods"))) & (mod_alt | mod_ctrl | mod_meta | mod_shift)
  let kc = key_code(key, code)
  let base : Array[(String, J)] = [
    ("key", at(ev, "key").unwrap_or(Null)),
    ("code", at(ev, "code").unwrap_or(Null)),
    ("modifiers", ji(modifiers)),
    ("windowsVirtualKeyCode", ji(kc)),
    ("nativeVirtualKeyCode", ji(kc)),
  ]
  // (a field the event did not carry is left out, as JSON.stringify leaves out undefined)
  let base = base.filter(f => !(f.0 == "key" && at(ev, "key") is None) && !(f.0 == "code" && at(ev, "code") is None))
  if text(at(ev, "kind")) == "up" {
    return jo([("type", js("keyUp"))] + base)
  }
  let shortcut = (modifiers & (mod_ctrl | mod_meta)) != 0
  // What a key types: its character, or Enter's; not with a shortcut's modifier held.
  let typed = if key == "Enter" {
    Some("\r")
  } else if point_count(key) == 1 && !shortcut {
    Some(key)
  } else {
    None
  }
  match typed {
    Some(t) => return jo([("type", js("keyDown"))] + base + [("text", js(t)), ("unmodifiedText", js(t))])
    None => ()
  }
  let command = if shortcut {
    match lower(key) {
      "a" => Some("selectAll")
      "c" => Some("copy")
      "x" => Some("cut")
      "v" => Some("paste")
      "z" => Some("undo")
      _ => None
    }
  } else {
    None
  }
  let commands = match command {
    None => []
    Some("undo") if (modifiers & mod_shift) != 0 => [("commands", jsa(["redo"]))]
    Some(c) => [("commands", jsa([c]))]
  }
  jo([("type", js("rawKeyDown"))] + base + commands)
}

///|
/// Whether the client data a device made of the station's (`theirs`, JSON) says what the station's says: the same
/// type, challenge and origin, not across origins.
pub fn same_client_data(theirs : String, ours : String) -> Bool {
  let a = parse(theirs) catch { _ => return false }
  let b = parse(ours) catch { _ => return false }
  let av = match a {
    Obj(_) => Some(a)
    _ => None
  }
  let bv = Some(b)
  same_value(at(av, "type"), at(bv, "type")) &&
  same_value(at(av, "challenge"), at(bv, "challenge")) &&
  same_value(at(av, "origin"), at(bv, "origin")) &&
  !is_true(at(av, "crossOrigin"))
}

///|
/// `a === b` of two JSON values (undefined as None; objects by identity: never equal here).
fn same_value(a : J?, b : J?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(Null), Some(Null)) => true
    (Some(Bool(x)), Some(Bool(y))) => x == y
    (Some(Num(x)), Some(Num(y))) => x == y
    (Some(Str(x)), Some(Str(y))) => x == y
    _ => false
  }
}

///|
/// Whether a page on `host` may ask for a passkey of relying party `rp_id`: the host itself, or a domain it is under
/// that is more than one label.
pub fn rp_for(rp_id : String, host : String) -> Bool {
  let l = lower(rp_id)
  let rp = if l.has_suffix(".") { slice(l, 0, b=l.length() - 1) } else { l }
  rp != "" && (rp == host || (rp.contains(".") && host.has_suffix("." + rp)))
}

///|
/// The host of an address (lower case, no trailing dot); "" for one with none (about:blank).
pub fn host_of(url : String) -> String {
  match url_of(url) {
    Some(u) => {
      let h = lower(u.hostname())
      if h.has_suffix(".") {
        slice(h, 0, b=h.length() - 1)
      } else {
        h
      }
    }
    None => ""
  }
}

///|
/// A frame Chrome cast and has not been told was taken.
priv struct Cast {
  ack : J
  data : Bytes
  meta : J
}

///|
pub(all) struct ViewParts {
  /// The view's own connection, and its session on the tab.
  cdp : Cdp
  session : String
  target_id : String
  /// Milliseconds, for telling a double click.
  now : () -> Double
  /// The tab's viewport (CSS pixels), as the frames say it.
  sized : (((Double, Double)) -> Unit)?
  used : (() -> Unit)?
  /// When the view ends.
  ended : (() -> Unit)?
  /// Whether the tab's context has a passkey of relying party `rp_id` its own authenticator signs.
  own_passkey : ((String) -> Bool)?
  /// A random UUID (a viewer's binding's owner).
  uuid : () -> String
  clock : Clock
}

///|
pub struct TabView {
  priv p : ViewParts
  priv mut watch_child_ : (((String) -> Unit) -> () -> Unit)?
  priv mut received : Array[Cast]
  priv mut delivered : Array[J]
  priv mut waiter : @effect.Deferred[Frame?]?
  priv mut ended : Bool
  /// The passkey sign-in a page asked last and not yet answered: its id, its origin, the client data made of it.
  priv mut asked : (String, String, String)?
  /// Who hears the passkey sign-ins (watch_passkey), told as the one asked is answered.
  priv mut passkey_heard : (Int, (J) -> Unit)?
  priv mut passkey_owner : String
  priv mut keyframe_ : Bool
  priv mut last : (Bytes, (String, Double, Double))?
  priv mut config : (String, Double, Double)?
  priv mut ts : Double
  priv mut viewport_ : (Double, Double)
  priv mut buttons : Int
  /// The last press: its count, when, where and which button.
  priv mut click : (Int, Double, Double, Double, String)
  priv mut unlisten : () -> Unit
  priv mut peek : Bool
  priv mut fitted : Bool
  priv mut device_passkeys : Bool
  priv mut heard_ids : Int
}

///|
pub fn TabView::new(p : ViewParts) -> TabView {
  let v : TabView = {
    p,
    watch_child_: None,
    received: [],
    delivered: [],
    waiter: None,
    ended: false,
    asked: None,
    passkey_heard: None,
    passkey_owner: "",
    keyframe_: false,
    last: None,
    config: None,
    ts: 0.0,
    viewport_: (0.0, 0.0),
    buttons: 0,
    click: (0, -@double.infinity, 0.0, 0.0, "none"),
    unlisten: () => (),
    peek: false,
    fitted: false,
    device_passkeys: true,
    heard_ids: 0,
  }
  v.unlisten = (p.cdp.on)(e => v.heard(e))
  (p.clock.spawn)(async fn() {
    (p.cdp.closed)()
    v.end()
  })
  v
}

///|
/// Chrome's own screencast, a JPEG a picture.
pub fn TabView::video(_self : TabView) -> J {
  jo([("capture", js("Chrome screencast")), ("encoder", js("JPEG"))])
}

///|
/// Starts casting; `viewport`: the page's size before the first frame says it. Laid out for the viewer's phone
/// (`fit`): its size and scale, and a phone's ways, and cast as large as that.
pub async fn TabView::start(self : TabView, options : ViewOptions, viewport? : (Double, Double)) -> Unit {
  match viewport {
    Some(v) => self.viewport_ = v
    None => ()
  }
  self.peek = options.peek
  self.device_passkeys = options.passkeys != Some(false)
  let cdp = self.p.cdp
  let session = self.p.session
  ignore(cdp.send("Page.enable", Obj([]), Some(session)))
  let fit = if self.peek { None } else { options.fit }
  let mut bounds = (options.max_width, options.max_height)
  match fit {
    Some((w, h, s)) => {
      let scale = if s < fit_scale_most { s } else { fit_scale_most }
      ignore(
        cdp.send(
          "Emulation.setDeviceMetricsOverride",
          jo([("width", jn(w)), ("height", jn(h)), ("deviceScaleFactor", jn(scale)), ("mobile", jb(true))]),
          Some(session),
        ),
      )
      self.viewport_ = (w, h)
      self.fitted = true
      bounds = (w * scale, h * scale)
    }
    None =>
      if viewport is None {
        let got = cdp.send("Page.getLayoutMetrics", Obj([]), Some(session)) catch { _ => Null }
        // The tab's size is its viewport's: told now, not only when a frame says another.
        match viewport_of(Some(got)) {
          Some(v) => {
            self.viewport_ = v
            match self.p.sized {
              Some(f) => f(v)
              None => ()
            }
          }
          None => ()
        }
      }
  }
  let most = (d : Double) => {
    let r = js_round(d)
    if r.is_nan() || r > 1.0 {
      jn(r)
    } else {
      jn(1.0)
    }
  }
  ignore(
    cdp.send(
      "Page.startScreencast",
      jo([
        ("format", js("jpeg")),
        ("quality", ji(quality)),
        ("maxWidth", most(bounds.0)),
        ("maxHeight", most(bounds.1)),
        ("everyNthFrame", ji(1)),
      ]),
      Some(session),
    ),
  )
}

///|
pub async fn TabView::next(self : TabView) -> Frame? {
  if self.ended {
    return None
  }
  // The frames given before were taken: Chrome may cast the next ones.
  let acks = self.delivered
  self.delivered = []
  for a in acks {
    self.ack(a)
  }
  if self.keyframe_ && self.last is Some(_) {
    return Some(self.again())
  }
  match self.take() {
    Some(f) => return Some(f)
    None => ()
  }
  let d : @effect.Deferred[Frame?] = @effect.Deferred::new()
  self.waiter = Some(d)
  d.wait() catch {
    _ => None
  }
}

///|
pub fn TabView::keyframe(self : TabView) -> Unit {
  self.keyframe_ = true
  match (self.waiter, self.last) {
    (Some(w), Some(_)) => {
      self.waiter = None
      ignore(w.succeed(Some(self.again())))
    }
    _ => ()
  }
}

///|
/// A person's input (a ScreenInput).
pub async fn TabView::input(self : TabView, event : J) -> Unit {
  if self.ended {
    return
  }
  let ev = Some(event)
  let t = text(at(ev, "t"))
  let kind = text(at(ev, "kind"))
  if t != "pointer" || kind != "move" {
    match self.p.used {
      Some(f) => f()
      None => ()
    }
  }
  let cdp = self.p.cdp
  let session = Some(self.p.session)
  match t {
    "pointer" => {
      let (x, y) = to_viewport(js_num(at(ev, "x")), js_num(at(ev, "y")), self.viewport_)
      let before = self.buttons
      let buttons = to_int32(js_num(at(ev, "buttons")))
      self.buttons = buttons
      let buttons_j = at(ev, "buttons").unwrap_or(Null)
      if kind == "move" {
        ignore(
          cdp.send(
            "Input.dispatchMouseEvent",
            jo([
              ("type", js("mouseMoved")),
              ("x", jn(x)),
              ("y", jn(y)),
              ("button", js(button_of(buttons))),
              ("buttons", buttons_j),
            ]),
            session,
          ),
        )
        return
      }
      if kind == "down" {
        let pressed = button_of(buttons & before.lnot())
        let button = if pressed == "none" { "left" } else { pressed }
        let now = (self.p.now)()
        let (count, at_, cx, cy, cb) = self.click
        let again = cb == button &&
          now - at_ <= click_ms &&
          (x - cx).abs() <= click_px &&
          (y - cy).abs() <= click_px
        let n = if again { count + 1 } else { 1 }
        self.click = (n, now, x, y, button)
        ignore(
          cdp.send(
            "Input.dispatchMouseEvent",
            jo([
              ("type", js("mousePressed")),
              ("x", jn(x)),
              ("y", jn(y)),
              ("button", js(button)),
              ("buttons", buttons_j),
              ("clickCount", ji(n)),
            ]),
            session,
          ),
        )
        return
      }
      let released = button_of(before & buttons.lnot())
      let button = if released == "none" { self.click.4 } else { released }
      let count = if self.click.0 > 1 { self.click.0 } else { 1 }
      ignore(
        cdp.send(
          "Input.dispatchMouseEvent",
          jo([
            ("type", js("mouseReleased")),
            ("x", jn(x)),
            ("y", jn(y)),
            ("button", js(button)),
            ("buttons", buttons_j),
            ("clickCount", ji(count)),
          ]),
          session,
        ),
      )
    }
    "wheel" => {
      let (x, y) = to_viewport(js_num(at(ev, "x")), js_num(at(ev, "y")), self.viewport_)
      let fs : Array[(String, J)] = [("type", js("mouseWheel")), ("x", jn(x)), ("y", jn(y))]
      match at(ev, "dx") {
        Some(d) => fs.push(("deltaX", d))
        None => ()
      }
      match at(ev, "dy") {
        Some(d) => fs.push(("deltaY", d))
        None => ()
      }
      fs.push(("button", js("none")))
      fs.push(("buttons", ji(self.buttons)))
      ignore(cdp.send("Input.dispatchMouseEvent", jo(fs), session))
    }
    "key" => ignore(cdp.send("Input.dispatchKeyEvent", key_event(event), session))
    "text" =>
      if !is_str(at(ev, "text"), "") {
        let fs = match at(ev, "text") {
          Some(x) => [("text", x)]
          None => []
        }
        ignore(cdp.send("Input.insertText", jo(fs), session))
      }
    _ => ()
  }
}

///|
/// A paste: the text inserted where the tab's focus is (Chrome's own clipboard is the machine's, left as it is).
pub async fn TabView::set_clipboard(self : TabView, clip : Clip, paste : Bool) -> Unit {
  if self.ended || clip.type_ != "text" || !paste {
    return
  }
  ignore(self.p.cdp.send("Input.insertText", jo([("text", js(clip.text))]), Some(self.p.session)))
}

///|
/// A binding the view's session watches while `on`: its calls heard, and what was added for it taken away again.
fn TabView::watch_binding(
  self : TabView,
  name : String,
  hook : String,
  heard : (J) -> Unit,
  enable_runtime? : Bool = false,
  undo_first? : () -> Unit = () => (),
) -> () -> Unit {
  let cdp = self.p.cdp
  let session = Some(self.p.session)
  let on = Ref(true)
  let script : Ref[J?] = Ref(None)
  let unlisten = (cdp.on)(e => if on.val &&
    e.method == "Runtime.bindingCalled" &&
    e.session_id == session &&
    text(at(Some(e.params), "name")) == name &&
    at(Some(e.params), "name") is Some(Str(_)) {
    heard(e.params)
  })
  let undo = () => {
    undo_first()
    if self.ended {
      return
    }
    cdp.tell("Runtime.removeBinding", jo([("name", js(name))]), session)
    match script.val {
      Some(id) => cdp.tell("Page.removeScriptToEvaluateOnNewDocument", jo([("identifier", id)]), session)
      None => ()
    }
  }
  (self.p.clock.spawn)(async fn() {
    (async fn() {
      // The binding needs no Runtime.enable (which a page could tell), but where it must follow navigations.
      ignore(cdp.send("Runtime.addBinding", jo([("name", js(name))]), session))
      if enable_runtime {
        ignore(cdp.send("Runtime.enable", Obj([]), session))
      }
      let added = cdp.send("Page.addScriptToEvaluateOnNewDocument", jo([("source", js(hook))]), session)
      script.val = match at(Some(added), "identifier") {
        None | Some(Null) => None
        x => x
      }
      ignore(cdp.send("Runtime.evaluate", jo([("expression", js(hook))]), session))
      if !on.val {
        undo()
      }
    })() catch {
      _ => ()
    }
  })
  () => {
    if !on.val {
      return
    }
    on.val = false
    unlisten()
    undo()
  }
}

///|
pub fn TabView::watch_clipboard(self : TabView, heard : (Clip) -> Unit) -> () -> Unit {
  self.watch_binding(copy_binding, copy_hook(), params => match at(Some(params), "payload") {
    Some(Str(u)) if u.length() > 0 => heard({ type_: "text", text: @jsjson.text(u) })
    _ => ()
  })
}

///|
/// The login field in focus, as the page's hook says it, with the tab's host as the browser has its address (asked
/// each time: the page may have gone elsewhere), until the returned function.
pub fn TabView::watch_login(self : TabView, heard : (J) -> Unit) -> () -> Unit {
  let on = Ref(true)
  let target_id = self.p.target_id
  let stop = self.watch_binding(login_binding, login_hook(), params => {
    let said = parse_obj(js_str(at(Some(params), "payload")))
    let field = match text(at(said, "field")) {
      "username" | "password" as f => Some(f)
      _ => None
    }
    guard field is Some(f) else {
      heard(Null)
      return
    }
    let filled = is_true(at(said, "filled"))
    (self.p.clock.spawn)(async fn() {
      let host = self.host(target_id)
      if on.val {
        let fields : Array[(String, J)] = [("host", js(host)), ("field", js(f))]
        if filled {
          fields.push(("filled", jb(true)))
        }
        heard(if host == "" { Null } else { jo(fields) })
      }
    })
  })
  () => {
    on.val = false
    stop()
  }
}

///|
/// Fills the login form in focus with what the person's app gave, only while the tab is on `f.host`, in a world of
/// the page's top frame of its own.
pub async fn TabView::fill(self : TabView, f : J) -> Unit {
  if self.ended {
    return
  }
  let cdp = self.p.cdp
  let session = Some(self.p.session)
  let fv = Some(f)
  if self.host(self.p.target_id) != lower(js_str(at(fv, "host"))) {
    return
  }
  let tree = cdp.send("Page.getFrameTree", Obj([]), session)
  guard at_path(Some(tree), ["frameTree", "frame", "id"]) is Some(Str(_) as frame_id) else { return }
  let world = cdp.send(
    "Page.createIsolatedWorld",
    jo([("frameId", frame_id), ("worldName", js("stillfail-fill"))]),
    session,
  )
  let context = at(Some(world), "executionContextId")
  let fs : Array[(String, J)] = [
    ("expression", js(fill_script(str_of(at(fv, "username")), str_of(at(fv, "password"))))),
  ]
  match context {
    Some(c) => fs.push(("contextId", c))
    None => ()
  }
  fs.push(("returnByValue", jb(true)))
  ignore(cdp.send("Runtime.evaluate", jo(fs), session))
}

///|
/// Whether `v` is base64url (`/^[A-Za-z0-9_-]+$/`, at most `most`).
fn b64_ok(v : J?, most? : Int = 1366) -> Bool {
  match v {
    Some(Str(u)) => {
      let s = @jsjson.text(u)
      s != "" &&
      s.length() <= most &&
      s.iter().all(c => is_ascii_alpha(c) || is_ascii_digit(c) || c == '_' || c == '-')
    }
    _ => false
  }
}

///|
/// A page's passkey sign-ins, as its hook asks them, each checked against the tab's address as the browser has it and
/// made into the client data the device is to sign; null as the one asked goes. Until the returned function, which
/// answers what is still asked as the browser would with none.
pub fn TabView::watch_passkey(self : TabView, heard : (J) -> Unit) -> () -> Unit {
  let cdp = self.p.cdp
  let session = Some(self.p.session)
  let target_id = self.p.target_id
  let owner = (self.p.uuid)()
  // Each viewer owns its binding as well as its subscription: page requests go to just that viewer, and an old
  // session removes only its own name on cleanup.
  let binding = passkey_binding_of(owner)
  let hook = passkey_hook(owner, device=self.device_passkeys)
  self.passkey_owner = owner
  let on = Ref(true)
  self.heard_ids += 1
  let me = self.heard_ids
  self.passkey_heard = Some((me, heard))
  let pending : Map[String, Int] = {}
  let requests = Ref(0)
  let stop = self.watch_binding(
    binding,
    hook,
    enable_runtime=true,
    undo_first=() => {
      match self.passkey_heard {
        Some((id, _)) if id == me => self.passkey_heard = None
        _ => ()
      }
      if self.ended {
        return
      }
      self.asked = None
      // The page transfers pending requests to another viewer, or refuses them if nobody is left.
      cdp.tell(
        "Runtime.evaluate",
        jo([
          ("expression", js("window.__stillfailPasskeyWatch && window.__stillfailPasskeyWatch(\{quote(owner)}, false)")),
        ]),
        session,
      )
    },
    params => {
      if !on.val {
        return
      }
      let said = parse_obj(js_str(at(Some(params), "payload")))
      guard text(at(said, "owner")) == owner && at(said, "owner") is Some(Str(_)) else { return }
      guard at(said, "id") is Some(Str(iu)) && iu.length() > 0 && iu.length() <= 32 else { return }
      let id = @jsjson.text(iu)
      if is_true(at(said, "gone")) {
        pending.remove(id)
        match self.asked {
          Some((aid, _, _)) if aid == id => {
            self.asked = None
            heard(Null)
          }
          _ => ()
        }
        return
      }
      if at(said, "uvpa") is Some(Str(uu)) && uu.length() <= 253 {
        let raw = lower(@jsjson.text(uu))
        let h = if raw.has_suffix(".") { slice(raw, 0, b=raw.length() - 1) } else { raw }
        let mut available = false
        match self.p.own_passkey {
          Some(f) if h != "" => {
            let parts = h.split(".").map(p => p.to_owned()).collect()
            for i in 0..<parts.length() {
              let rp = parts[i:].to_owned().join(".")
              if (i == 0 || rp.contains(".")) && f(rp) {
                available = true
                break
              }
            }
          }
          _ => ()
        }
        self.answer_now([("id", js(id)), ("available", jb(available))])
        return
      }
      let allow = match at(said, "allow") {
        Some(Arr(xs)) => xs.iter().take(64).collect()
        _ => []
      }
      guard at(said, "rpId") is Some(Str(ru)) &&
        b64_ok(at(said, "challenge"), most=32768) &&
        allow.iter().all(a => b64_ok(Some(a))) else {
        return
      }
      let rp_id = @jsjson.text(ru)
      let challenge = text(at(said, "challenge"))
      let user_verification = match at(said, "userVerification") {
        Some(Str(u)) =>
          match @jsjson.text(u) {
            "required" | "preferred" | "discouraged" as v => v
            _ => "preferred"
          }
        _ => "preferred"
      }
      requests.val += 1
      let request = requests.val
      pending[id] = request
      (self.p.clock.spawn)(async fn() {
        let url = self.url(target_id)
        if !on.val || pending.get(id) != Some(request) {
          return
        }
        pending.remove(id)
        let origin = match url_of(url) {
          // (a secure context only, as WebAuthn takes: https, or this machine's own)
          Some(u) =>
            if u.scheme == "https" ||
              (u.scheme == "http" && (u.hostname() == "localhost" || u.hostname() == "127.0.0.1")) {
              u.origin()
            } else {
              ""
            }
          None => ""
        }
        let host = host_of(url)
        if origin == "" || !rp_for(rp_id, host) {
          self.answer_now([("id", js(id)), ("error", js("NotAllowedError"))])
          return
        }
        // A passkey of the vault's in the tab's context: its own authenticator signs it, no device asked.
        match self.p.own_passkey {
          Some(f) if f(rp_id) => {
            self.answer_now([("id", js(id)), ("browser", jb(true))])
            return
          }
          _ => ()
        }
        // A viewer without host passkeys never invokes headful Chrome's OS WebAuthn dialog (hidden outside screencast).
        if !self.device_passkeys {
          self.answer_now([("id", js(id)), ("error", js("NotAllowedError"))])
          return
        }
        let client_data = stringify(
          jo([
            ("type", js("webauthn.get")),
            ("challenge", js(challenge)),
            ("origin", js(origin)),
            ("crossOrigin", jb(false)),
          ]),
        )
        // (one asked at a time, the latest: one before it is answered as given up)
        match self.asked {
          Some((before, _, _)) => self.answer_now([("id", js(before)), ("error", js("NotAllowedError"))])
          None => ()
        }
        self.asked = Some((id, origin, client_data))
        let l = lower(rp_id)
        let rp = if l.has_suffix(".") { slice(l, 0, b=l.length() - 1) } else { l }
        heard(
          jo([
            ("id", js(id)),
            ("host", js(host)),
            ("rpId", js(rp)),
            ("clientData", js(client_data)),
            ("allow", ja(allow)),
            ("userVerification", js(user_verification)),
          ]),
        )
      })
    },
  )
  () => {
    if on.val {
      on.val = false
    }
    stop()
  }
}

///|
/// Answers the page's passkey sign-in with what the person's app signed, only the one asked last, while the tab is
/// still on the origin it was asked on.
pub async fn TabView::passkey(self : TabView, a : J) -> Unit {
  let av = Some(a)
  guard self.asked is Some((aid, origin_asked, client_asked)) else { return }
  if self.ended || !is_str(at(av, "id"), aid) {
    return
  }
  self.asked = None
  match self.passkey_heard {
    Some((_, f)) => f(Null)
    None => ()
  }
  let origin = match url_of(self.url(self.p.target_id)) {
    Some(u) => u.origin()
    None => ""
  }
  if origin != origin_asked {
    return
  }
  if at(av, "error") is Some(_) || keys_of(a).contains("error") {
    self.answer(entries_of(a))
    return
  }
  let mut client_data = js(base64url(utf8(client_asked)))
  match at(av, "clientData") {
    Some(cd) => {
      if !same_client_data(from_utf8(from_base64url(js_str(Some(cd)))), client_asked) {
        self.answer([("id", at(av, "id").unwrap()), ("error", js("NotAllowedError"))])
        return
      }
      client_data = cd
    }
    None => ()
  }
  self.answer(entries_of(put(a, "clientData", client_data)))
}

///|
fn answer_expression(owner : String, fs : Array[(String, J)]) -> String {
  let id = match fs.search_by(f => f.0 == "id") {
    Some(i) => stringify(fs[i].1)
    None => "undefined"
  }
  "window.__stillfailPasskeyReply && window.__stillfailPasskeyReply(\{quote(owner)}, \{id}, \{stringify(jo(fs))})"
}

///|
/// The page's hook told how its ask went.
async fn TabView::answer(self : TabView, fs : Array[(String, J)]) -> Unit {
  ignore(
    self.p.cdp.send(
      "Runtime.evaluate",
      jo([("expression", js(answer_expression(self.passkey_owner, fs)))]),
      Some(self.p.session),
    ),
  ) catch {
    _ => ()
  }
}

///|
/// The same, not waited for (`void this.#answer(…)`).
fn TabView::answer_now(self : TabView, fs : Array[(String, J)]) -> Unit {
  self.p.cdp.tell(
    "Runtime.evaluate",
    jo([("expression", js(answer_expression(self.passkey_owner, fs)))]),
    Some(self.p.session),
  )
}

///|
/// The address of tab `target_id` as the browser has it now ("" for none).
async fn TabView::url(self : TabView, target_id : String) -> String {
  let got = self.p.cdp.send("Target.getTargetInfo", jo([("targetId", js(target_id))]), None) catch {
    _ => jo([("targetInfo", Null)])
  }
  match at_path(Some(got), ["targetInfo", "url"]) {
    None | Some(Null) => ""
    u => js_str(u)
  }
}

///|
async fn TabView::host(self : TabView, target_id : String) -> String {
  host_of(self.url(target_id))
}

///|
pub fn TabView::close(self : TabView) -> Unit {
  if self.ended {
    return
  }
  let cdp = self.p.cdp
  let session = Some(self.p.session)
  cdp.tell("Page.stopScreencast", Obj([]), session)
  // As it was laid out before (its session going takes it away too; said, for a Chrome that would keep it).
  if self.fitted {
    cdp.tell("Emulation.clearDeviceMetricsOverride", Obj([]), session)
  }
  let detached = (cdp.post)("Target.detachFromTarget", jo([("sessionId", js(self.p.session))]), None)
  (self.p.clock.spawn)(async fn() {
    ignore(detached.wait()) catch {
      _ => ()
    }
    (cdp.close)()
  })
  self.end()
}

///|
/// The tab's viewport as last cast (CSS pixels).
pub fn TabView::viewport(self : TabView) -> (Double, Double) {
  self.viewport_
}

///|
fn TabView::heard(self : TabView, e : CdpEvent) -> Unit {
  let session = self.p.session
  let p = Some(e.params)
  if e.method == "Page.screencastFrame" && e.session_id == Some(session) {
    if self.ended {
      return
    }
    let data = @base64.decode_lossy(match at(p, "data") {
      None | Some(Null) => ""
      d => js_str(d)
    })
    self.received.push({
      ack: at(p, "sessionId").unwrap_or(Null),
      data,
      meta: match at(p, "metadata") {
        None | Some(Null) => Obj([])
        Some(m) => m
      },
    })
    while self.received.length() > held_frames {
      let older = self.received.remove(0)
      self.ack(older.ack)
    }
    match self.waiter {
      Some(w) => {
        self.waiter = None
        ignore(w.succeed(self.take()))
      }
      None => ()
    }
  } else if (e.method == "Target.detachedFromTarget" && text(at(p, "sessionId")) == session && at(p, "sessionId") is Some(Str(_))) ||
    (e.method == "Inspector.detached" && e.session_id == Some(session)) {
    self.end()
  }
}

///|
/// The newest frame received, the older let go; None when none came.
fn TabView::take(self : TabView) -> Frame? {
  guard self.received.pop() is Some(newest) else { return None }
  let older = self.received
  self.received = []
  for o in older {
    self.ack(o.ack)
  }
  self.delivered.push(newest.ack)
  let meta = Some(newest.meta)
  let dw = js_num(at(meta, "deviceWidth"))
  let dh = js_num(at(meta, "deviceHeight"))
  if dw > 0.0 && dh > 0.0 && (dw != self.viewport_.0 || dh != self.viewport_.1) {
    self.viewport_ = (dw, dh)
    match self.p.sized {
      Some(f) => f(self.viewport_)
      None => ()
    }
  }
  let (w, h) = match jpeg_size(newest.data) {
    Some((jw, jh)) => (jw.to_double(), jh.to_double())
    None =>
      match self.config {
        Some((_, cw, ch)) => (cw, ch)
        None => self.viewport_
      }
  }
  let config = ("jpeg", w, h)
  let changed = match self.config {
    None => true
    Some((_, cw, ch)) => cw != w || ch != h || self.keyframe_
  }
  self.keyframe_ = false
  self.config = Some(config)
  self.last = Some((newest.data, config))
  let stamp = match at(meta, "timestamp") {
    Some(Num(t)) => js_round(t * 1.0e6)
    _ => (self.p.now)() * 1000.0
  }
  self.ts = if self.ts + 1.0 > stamp { self.ts + 1.0 } else { stamp }
  Some({ config: if changed { Some(config) } else { None }, key: true, ts: self.ts, data: newest.data })
}

///|
/// The last frame again, for a viewer that lost its decoder's state.
fn TabView::again(self : TabView) -> Frame {
  self.keyframe_ = false
  let (data, config) = self.last.unwrap()
  self.ts += 1.0
  { config: Some(config), key: true, ts: self.ts, data }
}

///|
fn TabView::ack(self : TabView, ack : J) -> Unit {
  self.p.cdp.tell("Page.screencastFrameAck", jo([("sessionId", ack)]), Some(self.p.session))
}

///|
fn TabView::end(self : TabView) -> Unit {
  if self.ended {
    return
  }
  self.ended = true
  (self.unlisten)()
  match self.waiter {
    Some(w) => {
      self.waiter = None
      ignore(w.succeed(None))
    }
    None => ()
  }
  match self.p.ended {
    Some(f) => f()
    None => ()
  }
}

///|
/// The view as one of the screens' views.
pub fn TabView::as_view(self : TabView) -> ScreenView {
  {
    next: async fn() { self.next() },
    keyframe: () => self.keyframe(),
    input: async fn(e) { self.input(e) },
    set_clipboard: async fn(c, p) { self.set_clipboard(c, p) },
    watch_clipboard: f => self.watch_clipboard(f),
    watch_login: f => self.watch_login(f),
    fill: async fn(f) { self.fill(f) },
    watch_passkey: f => self.watch_passkey(f),
    passkey: async fn(a) { self.passkey(a) },
    bounds: (_, _) => (),
    video: () => self.video(),
    viewport: () => self.viewport(),
    watch_child: f => match self.watch_child_ {
      Some(w) => w(f)
      None => () => ()
    },
    close: () => self.close(),
    peek: self.peek,
  }
}

///|
/// The watch a tab's opener's view keeps of the tabs its page opens (tabs.mbt sets it).
pub fn TabView::set_watch_child(self : TabView, f : ((String) -> Unit) -> () -> Unit) -> Unit {
  self.watch_child_ = Some(f)
}
