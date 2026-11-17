// Linux desktop views made with GStreamer (src/screens/linux-portal.ts). Wayland uses the session's XDG RemoteDesktop
// and ScreenCast portals; X11 can use this path when ffmpeg and xdotool are unavailable. Each helper sends complete
// JPEGs.

///|
const PORTAL_MAX_FRAME : Int = 16777216

///|
const CONSENT_WAIT : Double = 4000

///|
const FRAME_WAIT : Double = 12000

///|
/// What the portal's desktop is given (linux-portal.ts `PortalOptions`).
pub(all) struct PortalOptions {
  changed : () -> Unit
  mut env : Env
  /// "wayland" (none) or "x11".
  mode : String?
  title : (() -> String)?
  python : String?
  helper : String?
  consent_wait_ms : Double?
}

///|
/// Beside the source in development, beside the station's main.js in its release.
fn portal_helper_path(io : Io, mode : String?) -> String {
  pj([io.os.code_dir, if mode == Some("x11") { "linux-x11.py" } else { "linux-portal.py" }])
}

///|
/// A Linux desktop through a GStreamer helper (linux-portal.ts `LinuxGstDesktop`).
pub struct LinuxGstDesktop {
  priv io : Io
  priv o : PortalOptions
  priv views : Array[PortalProcess]
  priv running : Array[PortalProcess]
  priv mut pending : PortalProcess?
  priv mut failed : Bool
  priv mut size_ : (Double, Double)
  priv mut closed : Bool
}

///|
pub fn LinuxGstDesktop::new(io : Io, o : PortalOptions) -> LinuxGstDesktop {
  { io, o, views: [], running: [], pending: None, failed: false, size_: (0.0, 0.0), closed: false }
}

///|
pub fn LinuxGstDesktop::set_env(self : LinuxGstDesktop, env : Env) -> Unit {
  self.o.env = env
}

///|
fn LinuxGstDesktop::x11(self : LinuxGstDesktop) -> Bool {
  self.o.mode == Some("x11")
}

///|
pub fn LinuxGstDesktop::title(self : LinuxGstDesktop) -> String {
  match self.o.title {
    Some(f) => f()
    None => (self.io.os.hostname)()
  }
}

///|
pub fn LinuxGstDesktop::size(self : LinuxGstDesktop) -> (Double, Double) {
  self.size_
}

///|
pub fn LinuxGstDesktop::access(self : LinuxGstDesktop) -> ScreenAccess {
  match self.pending {
    Some(p) if !p.is_ready() =>
      return if self.x11() {
        ScreenAccess::new(false, false, reason=Some("linuxDesktopStarting"))
      } else {
        ScreenAccess::new(false, false, reason=Some("linuxPortalConsent"), asking=true)
      }
    _ => ()
  }
  if self.failed {
    return ScreenAccess::new(
      false,
      false,
      reason=Some(if self.x11() { "linuxX11FallbackUnavailable" } else { "linuxPortalUnavailable" }),
    )
  }
  ScreenAccess::new(true, true)
}

///|
/// Listing the desktop never opens a permission dialog.
pub async fn LinuxGstDesktop::refresh(self : LinuxGstDesktop, force? : Bool = false) -> Unit {
  ignore(self)
  ignore(force)
}

///|
fn[T] drop_one(a : Array[T], v : T) -> Unit {
  match a.search_by(x => physical_equal(x, v)) {
    Some(i) => ignore(a.remove(i))
    None => ()
  }
}

///|
pub async fn LinuxGstDesktop::open(self : LinuxGstDesktop, options : ViewOptions) -> ScreenView {
  if !options.codecs.contains(Jpeg) {
    raise self.io.refused(415, "station.screen.codec", args=jo([("codec", js("JPEG"))]))
  }
  let failure = if self.x11() { "linuxX11FallbackUnavailable" } else { "linuxPortalUnavailable" }
  if self.closed {
    raise self.io.refused(503, "station.screen.\{failure}")
  }
  let helper = self.o.helper.unwrap_or(portal_helper_path(self.io, self.o.mode))
  // (looked at off the station's thread, and only where no helper is up: a concurrent open's is taken after)
  if self.pending is None && !(self.io.fs.access)(helper, 0) {
    raise self.io.refused(503, "station.screen.\{failure}", access=Some(ScreenAccess::new(false, false, reason=Some(failure))))
  }
  if self.closed {
    raise self.io.refused(503, "station.screen.\{failure}")
  }
  if self.pending is None {
    self.failed = false
    let me : Ref[PortalProcess?] = Ref(None)
    let process = PortalProcess::new(
      self.io,
      self.o.python.unwrap_or("/usr/bin/python3"),
      helper,
      self.o.env,
      size => {
        self.size_ = size
        (self.o.changed)()
      },
      () => match me.val {
        Some(p) => {
          drop_one(self.views, p)
          match self.pending {
            Some(x) if physical_equal(x, p) => {
              self.pending = None
              self.failed = !p.normal
            }
            _ => ()
          }
          if !self.closed {
            (self.o.changed)()
          }
        }
        None => ()
      },
      if self.x11() { "X11 / GStreamer" } else { "XDG Desktop Portal / PipeWire" },
    )
    me.val = Some(process)
    self.pending = Some(process)
    self.running.push(process)
    self.io.go(async fn() {
      process.exited.wait()
      drop_one(self.running, process)
    })
    self.io.go(async fn() {
      process.ready.wait()
      (self.o.changed)()
    })
  }
  let pending = self.pending.unwrap()
  try {
    let d : @effect.Deferred[Bool] = @effect.Deferred::new()
    let stop = (self.io.clock.after)(self.o.consent_wait_ms.unwrap_or(CONSENT_WAIT), () => ignore(d.succeed(false)))
    self.io.go(async fn() {
      match (try Ok(pending.ready.wait()) catch { e => Err(e) }) {
        Ok(_) => ignore(d.succeed(true))
        Err(e) => ignore(d.fail(e))
      }
    })
    let ready = try Ok(d.wait()) catch { e => Err(e) }
    stop()
    let ready = match ready {
      Ok(r) => r
      Err(e) => raise e
    }
    if !ready {
      (self.o.changed)()
      raise self.io.refused(
        503,
        if self.x11() { "station.screen.linuxDesktopStarting" } else { "station.screen.linuxPortalConsent" },
        access=Some(self.access()),
      )
    }
    // An open consumes the prepared portal session. Concurrent opens prepare their own and ask separately.
    match self.pending {
      Some(p) if physical_equal(p, pending) => ()
      _ => return self.open(options)
    }
    self.pending = None
    self.views.push(pending)
    pending.start(options)
    pending.view()
  } catch {
    ScreenRefused(..) as e => raise e
    _ => {
      pending.close()
      self.failed = true
      (self.o.changed)()
      raise self.io.refused(503, "station.screen.\{failure}", access=Some(self.access()))
    }
  }
}

///|
pub async fn LinuxGstDesktop::close(self : LinuxGstDesktop) -> Unit {
  self.closed = true
  match self.pending {
    Some(p) => p.close()
    None => ()
  }
  for v in self.views.copy() {
    v.close()
  }
  // Closed means no helper is left running: a closed view's helper may still be releasing its keys.
  ignore(@effect.all(self.running.copy().map(p => async fn() { p.exited.wait() })))
}

///|
pub fn LinuxGstDesktop::source(self : LinuxGstDesktop) -> ScreenSource {
  {
    ..ScreenSource::bare("desktop", DesktopKind, () => self.title(), () => self.size(), async fn(o) { self.open(o) }),
    access: Some(() => self.access()),
  }
}

///|
/// One helper process: a portal session prepared, then a view (linux-portal.ts `PortalProcess`).
pub struct PortalProcess {
  priv io : Io
  ready : @effect.Deferred[Unit]
  exited : @effect.Deferred[Unit]
  priv first : @effect.Deferred[Unit]
  priv mut child : Child?
  priv size_changed : ((Double, Double)) -> Unit
  priv gone : () -> Unit
  priv capture : String
  priv keys : Array[Int]
  priv carry : Carry
  priv mut picture : (Double, Double)
  priv mut latest : (Bytes, Double, (Double, Double))?
  priv mut last : (Bytes, Double, (Double, Double))?
  priv mut shown : (Double, Double)?
  priv waiting : Array[(Frame?, Error?) -> Unit]
  priv mut failure : Error?
  priv mut why_ : String?
  priv mut config : Bool
  priv mut last_ts : Double
  priv chain : Chain
  priv mut opened : Bool
  priv mut ready_ : Bool
  priv mut ended : Bool
  mut normal : Bool
  priv mut error : String
}

///|
pub fn PortalProcess::new(
  io : Io,
  python : String,
  helper : String,
  env : Env,
  size_changed : ((Double, Double)) -> Unit,
  gone : () -> Unit,
  capture : String,
) -> PortalProcess {
  let p = {
    io,
    ready: @effect.Deferred::new(),
    exited: @effect.Deferred::new(),
    first: @effect.Deferred::new(),
    child: None,
    size_changed,
    gone,
    capture,
    keys: [],
    carry: Carry::new(),
    picture: (0.0, 0.0),
    latest: None,
    last: None,
    shown: None,
    waiting: [],
    failure: None,
    why_: None,
    config: true,
    last_ts: 0.0,
    chain: Chain::new(),
    opened: false,
    ready_: false,
    ended: false,
    normal: false,
    error: "",
  }
  let started = Ref(false)
  let child = (io.procs.spawn)(python, ["-u", helper], SpawnOptions::piped(env=Some(env)), {
    out: d => p.read(d),
    err: d => p.error = last_units(p.error + @utf8.decode_lossy(d), 2000),
    error: e => {
      p.end(fail(e))
      // never started
      match p.child {
        Some(c) if (c.pid)() is None => ignore(p.exited.succeed(()))
        _ => ()
      }
      ignore(started)
    },
    close: (_, _) => {
      p.end(fail(if trim_js(p.error) != "" { trim_js(p.error) } else { "desktop portal ended" }))
      ignore(p.exited.succeed(()))
    },
  })
  p.child = Some(child)
  p
}

///|
pub fn PortalProcess::is_ready(self : PortalProcess) -> Bool {
  self.ready_ && !self.ended
}

///|
pub async fn PortalProcess::start(self : PortalProcess, options : ViewOptions) -> Unit {
  self.send(
    jo([
      ("op", js("start")),
      ("maxWidth", jn(options.max_width)),
      ("maxHeight", jn(options.max_height)),
      ("fps", jn(options.fps.unwrap_or(15.0))),
    ]),
  )
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  let stop = (self.io.clock.after)(FRAME_WAIT, () => ignore(d.fail(fail("desktop portal did not produce a frame"))))
  self.io.go(async fn() {
    match (try Ok(self.first.wait()) catch { e => Err(e) }) {
      Ok(_) => ignore(d.succeed(()))
      Err(e) => ignore(d.fail(e))
    }
  })
  let r = try Ok(d.wait()) catch { e => Err(e) }
  stop()
  match r {
    Ok(_) => ()
    Err(e) => raise e
  }
}

///|
async fn PortalProcess::send(self : PortalProcess, command : J) -> Unit {
  if self.ended {
    raise fail("desktop portal closed")
  }
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  match self.child {
    Some(c) =>
      (c.write)(@utf8.encode(stringify(command) + "\n"), Some(e => match e {
        Some(m) => ignore(d.fail(fail(m)))
        None => ignore(d.succeed(()))
      }))
    None => ignore(d.fail(fail("desktop portal closed")))
  }
  d.wait()
}

///|
fn PortalProcess::read(self : PortalProcess, chunk : Bytes) -> Unit {
  if self.ended {
    return
  }
  self.carry.push(chunk)
  while self.carry.length >= 5 {
    let kind = self.carry.byte_at(0).to_int()
    let length = self.carry.u32_at(1)
    if length > PORTAL_MAX_FRAME.to_int64() {
      self.end(fail("desktop portal frame is too large"))
      return
    }
    let length = length.to_int()
    if self.carry.length < length + 5 {
      return
    }
    ignore(self.carry.take(5))
    let body = self.carry.take(length)
    if kind == 1 {
      try {
        let message = parse(@utf8.decode_lossy(body))
        let t = text(get(Some(message), "type"))
        if t == Some("ready") {
          self.ready_ = true
          let w = num(get(Some(message), "width"))
          let h = num(get(Some(message), "height"))
          match (w, h) {
            (Some(w), Some(h)) if w != 0.0 && h != 0.0 && !w.is_nan() && !h.is_nan() => (self.size_changed)((w, h))
            _ => ()
          }
          ignore(self.ready.succeed(()))
        } else if t == Some("picture") {
          let ok = (v : J?) => match v {
            Some(Num(d)) => is_integer(d) && d >= 1.0 && d <= 16384.0
            _ => false
          }
          if !ok(get(Some(message), "width")) || !ok(get(Some(message), "height")) {
            raise fail("invalid desktop picture size")
          }
          self.picture = (num(get(Some(message), "width")).unwrap(), num(get(Some(message), "height")).unwrap())
        } else if t == Some("error") {
          let m = text(get(Some(message), "message")).unwrap_or("")
          self.end(fail(if m != "" { m } else { "desktop portal failed" }))
        } else if t == Some("input_error") && text(get(Some(message), "code")) == Some("textUnsupported") {
          self.end(self.io.refused(422, "station.screen.linuxTextUnsupported"))
        }
      } catch {
        e => self.end(e)
      }
      if self.ended {
        return
      }
    } else if kind == 2 {
      if self.picture.0 == 0.0 || self.picture.1 == 0.0 {
        self.end(fail("desktop portal sent a picture without its size"))
        return
      }
      let ts = js_max(self.last_ts + 1.0, self.io.clock.us())
      self.last_ts = ts
      let picture = (body, ts, self.picture)
      self.last = Some(picture)
      if self.waiting.length() > 0 {
        (self.waiting.remove(0))(Some(self.frame(picture)), None)
      } else {
        self.latest = Some(picture)
      }
      if !self.opened {
        self.opened = true
        ignore(self.first.succeed(()))
      }
    } else {
      self.end(fail("unrecognized desktop portal frame"))
      return
    }
  }
}

///|
fn PortalProcess::frame(self : PortalProcess, picture : (Bytes, Double, (Double, Double))) -> Frame {
  let (data, ts, size) = picture
  let changed = match self.shown {
    Some(s) => s != size
    None => true
  }
  let config = if self.config || changed {
    Some({ codec: Jpeg, width: size.0, height: size.1, description: None, region: None })
  } else {
    None
  }
  self.config = false
  self.shown = Some(size)
  { config, key: true, ts, data }
}

///|
pub async fn PortalProcess::next(self : PortalProcess) -> Frame? {
  match self.failure {
    Some(e) => raise e
    None => ()
  }
  if self.ended {
    return None
  }
  match self.latest {
    Some(p) => {
      self.latest = None
      return Some(self.frame(p))
    }
    None => ()
  }
  let d : @effect.Deferred[Frame?] = @effect.Deferred::new()
  self.waiting.push((f, e) => match e {
    Some(e) => ignore(d.fail(e))
    None => ignore(d.succeed(f))
  })
  d.wait()
}

///|
pub fn PortalProcess::keyframe(self : PortalProcess) -> Unit {
  // Like a browser tab's JPEG view, replay the last picture if the desktop has not changed since it was sent.
  guard self.last is Some((data, _, size)) && !self.ended else { return }
  self.config = true
  let ts = js_max(self.last_ts + 1.0, self.io.clock.us())
  self.last_ts = ts
  let picture = (data, ts, size)
  if self.waiting.length() > 0 {
    (self.waiting.remove(0))(Some(self.frame(picture)), None)
  } else {
    self.latest = Some(picture)
  }
}

///|
pub fn PortalProcess::video(self : PortalProcess) -> ScreenVideo {
  { capture: self.capture, encoder: Some("GStreamer JPEG (software)"), hardware: None }
}

///|
/// Consecutive pointer, key and modifier events must reach the portal in the same order they arrived.
pub async fn PortalProcess::input(self : PortalProcess, event : ScreenInput) -> Unit {
  self.chain.then(self.io, async fn() { self.post(event) })
}

///|
async fn PortalProcess::post(self : PortalProcess, event : ScreenInput) -> Unit {
  guard event is Key(kind~, key~, code~, mods~) else {
    return self.send(jo([("op", js("input")), ("event", event.to_j())]))
  }
  guard evdev.get(code) is Some(keycode) else {
    if kind == "down" && points_len(key) == 1 && (mods & 6) == 0 {
      self.send(jo([("op", js("input")), ("event", jo([("t", js("text")), ("text", js(key))]))]))
    }
    return
  }
  let send = async fn(code : Int, kind : String) {
    self.send(jo([("op", js("input")), ("event", jo([("t", js("key")), ("keycode", ji(code)), ("kind", js(kind))]))]))
  }
  if kind == "up" {
    send(keycode, "up")
    remove_from(self.keys, keycode)
    return
  }
  let mods_ : Array[(Int, Array[Int])] = [(1, [56, 100]), (2, [29, 97]), (4, [125, 126]), (8, [42, 54])]
  let temporary = mods_
    .filter(m => (mods & m.0) != 0 && !m.1.contains(keycode) && !m.1.iter().any(c => self.keys.contains(c)))
    .map(m => m.1[0])
  for m in temporary {
    send(m, "down")
    add_to(self.keys, m)
  }
  send(keycode, "down")
  add_to(self.keys, keycode)
  for m in temporary.rev() {
    send(m, "up")
    remove_from(self.keys, m)
  }
}

///|
fn PortalProcess::end(self : PortalProcess, error : Error, terminate? : Bool = true) -> Unit {
  if self.ended {
    return
  }
  self.ended = true
  if error is ScreenRefused(..) {
    self.failure = Some(error)
  }
  if !self.normal {
    self.why_ = Some(message_of(error))
  }
  if !self.ready_ {
    ignore(self.ready.fail(error))
  }
  if !self.opened {
    ignore(self.first.fail(error))
  }
  match self.child {
    Some(child) => {
      if terminate {
        (child.kill)("SIGTERM")
      }
      ignore((self.io.clock.after)(2000.0, () => if (child.running)() { (child.kill)("SIGKILL") }))
    }
    None => ()
  }
  self.latest = None
  self.last = None
  for w in self.waiting.copy() {
    w(None, self.failure)
  }
  self.waiting.clear()
  (self.gone)()
}

///|
pub fn PortalProcess::why(self : PortalProcess) -> String? {
  self.why_
}

///|
pub fn PortalProcess::close(self : PortalProcess) -> Unit {
  if self.ended {
    return
  }
  self.normal = true
  // A live helper can release its virtual keys and buttons before the portal session closes.
  match self.child {
    Some(c) if (c.input_open)() => (c.end_input)(Some(@utf8.encode("{\"op\":\"close\"}\n")))
    _ => ()
  }
  self.end(fail("desktop portal closed"), terminate=false)
}

///|
pub fn PortalProcess::view(self : PortalProcess) -> ScreenView {
  {
    ..ScreenView::bare(async fn() { self.next() }, () => self.keyframe(), async fn(e) { self.input(e) }, () => self.close()),
    video: Some(() => self.video()),
    why: Some(() => self.why()),
  }
}
