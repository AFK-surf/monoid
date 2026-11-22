// Native Linux desktop source backed by `stillfail-screen-linux` (`src/screens/linux-native.ts`).
// Reuses `HelperView` + `LastingView` over the 5-byte binary pipe protocol.

///|
pub const LINUX_SCREEN_BINARY : String = "stillfail-screen-linux"

///|
let linux_screen_found : Map[String, String] = Map::new()

///|
/// Locate `stillfail-screen-linux`: STILLFAIL_SCREEN_LINUX, beside station code, or built in checkout.
pub fn linux_screen_binary(io : Io, env : Env) -> String? {
  let key = env.get("STILLFAIL_SCREEN_LINUX").unwrap_or("")
  match linux_screen_found.get(key) {
    Some(kept) => return Some(kept)
    None => ()
  }
  let candidates = [
    env.get("STILLFAIL_SCREEN_LINUX"),
    Some(pj([io.os.code_dir, LINUX_SCREEN_BINARY])),
    Some(pj([io.os.code_dir, "..", "..", "native", "screen-linux", "target", "release", LINUX_SCREEN_BINARY])),
  ]
  for p in candidates {
    match p {
      Some(p) if p != "" && (io.fs.exists_sync)(p) => {
        linux_screen_found[key] = p
        return Some(p)
      }
      _ => ()
    }
  }
  None
}

///|
/// How `stillfail-screen-linux` is started (a test's fake in tests), with the discovered desktop env.
pub(all) struct LinuxNativeStart {
  start : (String, Array[String], Env, ChildEvents) -> Child
}

///|
fn default_linux_native_start(io : Io) -> LinuxNativeStart {
  {
    start: (binary, args, env, events) => (io.procs.spawn)(
      binary,
      args,
      { env: Some(env), group: false, verbatim: false, stdio: ("pipe", "pipe", "ignore") },
      events,
    ),
  }
}

///|
pub(all) struct LinuxNativeOptions {
  binary : String?
  changed : () -> Unit
  title : (() -> String)?
  mut env : Env?
  start : LinuxNativeStart?
}

///|
const LINUX_NATIVE_FRESH_MS : Double = 2000

///|
const LINUX_NATIVE_STATUS_TIMEOUT_MS : Double = 3000

///|
/// Native Linux desktop backed by `stillfail-screen-linux` (linux-native.ts `LinuxNativeDesktop`).
pub struct LinuxNativeDesktop {
  priv io : Io
  priv o : LinuxNativeOptions
  priv views : Array[LastingView]
  priv mut available_ : Bool
  priv mut backend_ : String?
  priv mut size_ : (Double, Double)
  priv mut looked : Double
  priv looking : Shared[Unit]
}

///|
pub fn LinuxNativeDesktop::new(io : Io, o : LinuxNativeOptions) -> LinuxNativeDesktop {
  {
    io,
    o,
    views: [],
    available_: false,
    backend_: None,
    size_: (0.0, 0.0),
    looked: 0.0,
    looking: Shared::new(),
  }
}

///|
pub fn LinuxNativeDesktop::set_env(self : LinuxNativeDesktop, env : Env) -> Unit {
  self.o.env = Some(env)
}

///|
fn LinuxNativeDesktop::env(self : LinuxNativeDesktop) -> Env {
  match self.o.env {
    Some(e) => e
    None => (self.io.os.env)()
  }
}

///|
fn LinuxNativeDesktop::starter(self : LinuxNativeDesktop) -> LinuxNativeStart {
  self.o.start.unwrap_or(default_linux_native_start(self.io))
}

///|
pub fn LinuxNativeDesktop::title(self : LinuxNativeDesktop) -> String {
  match self.o.title {
    Some(f) => f()
    None => (self.io.os.hostname)()
  }
}

///|
pub fn LinuxNativeDesktop::size(self : LinuxNativeDesktop) -> (Double, Double) {
  self.size_
}

///|
pub fn LinuxNativeDesktop::available(self : LinuxNativeDesktop) -> Bool {
  self.o.binary is Some(_) && self.available_
}

///|
pub fn LinuxNativeDesktop::backend(self : LinuxNativeDesktop) -> String? {
  self.backend_
}

///|
pub fn LinuxNativeDesktop::access(self : LinuxNativeDesktop) -> ScreenAccess {
  if self.o.binary is None {
    return ScreenAccess::new(false, false, unsupported=Some("helper"))
  }
  if !self.available_ {
    return ScreenAccess::new(false, false, reason=Some("linuxUnavailable"))
  }
  ScreenAccess::new(true, true)
}

///|
pub async fn LinuxNativeDesktop::refresh(self : LinuxNativeDesktop, force? : Bool = false) -> Unit {
  if self.o.binary is None {
    self.available_ = false
    self.backend_ = None
    self.size_ = (0.0, 0.0)
    return
  }
  if !force && self.io.clock.ms() - self.looked < LINUX_NATIVE_FRESH_MS {
    return
  }
  self.looking
  .start(self.io, async fn() {
    try {
      let told = self.ask_status()
      let ok = get(Some(told), "ok") is Some(Bool(true)) && get(Some(told), "capture") is Some(Bool(true))
      let backend = match text(get(Some(told), "backend")) {
        Some("wayland") => Some("wayland")
        Some("x11") => Some("x11")
        _ => None
      }
      let display = get(Some(told), "display")
      let w = if ok { number_or_zero(get(display, "width")) } else { 0.0 }
      let h = if ok { number_or_zero(get(display, "height")) } else { 0.0 }
      let next_avail = ok && w >= 2.0 && h >= 2.0
      let changed = next_avail != self.available_ || backend != self.backend_ || (w, h) != self.size_
      self.available_ = next_avail
      self.backend_ = backend
      self.size_ = (w, h)
      if changed {
        (self.o.changed)()
      }
    } catch {
      e => {
        let was = self.available_
        self.available_ = false
        self.backend_ = None
        self.size_ = (0.0, 0.0)
        if was {
          (self.o.changed)()
        }
        self.io.log.warn("screens", "stillfail-screen-linux status failed", fields=jo([("error", js(message_of(e)))]))
      }
    }
    self.looked = self.io.clock.ms()
  })
  .wait()
}

///|
async fn LinuxNativeDesktop::ask_status(self : LinuxNativeDesktop) -> J {
  guard self.o.binary is Some(binary) else { raise fail("stillfail-screen-linux is not there") }
  let d : @effect.Deferred[J] = @effect.Deferred::new()
  let said = Buffer()
  let finished = Ref(false)
  let unarm : Ref[() -> Unit] = Ref(() => ())
  let done = (error : String?) => {
    if finished.val {
      return
    }
    finished.val = true
    (unarm.val)()
    match error {
      Some(e) => ignore(d.fail(fail(e)))
      None =>
        match (try Ok(parse(@utf8.decode_lossy(said.to_bytes()))) catch { e => Err(e) }) {
          Ok(told) => ignore(d.succeed(told))
          Err(e) => ignore(d.fail(fail(json_error_message(e))))
        }
    }
  }
  let child = (self.starter().start)(binary, ["status"], self.env(), {
    out: b => said.write_bytes(b),
    err: _ => (),
    error: e => done(Some(e)),
    close: (_, _) => done(None),
  })
  unarm.val = (self.io.clock.after)(LINUX_NATIVE_STATUS_TIMEOUT_MS, () => (child.kill)("SIGTERM"))
  (child.end_input)(None)
  d.wait()
}

///|
pub async fn LinuxNativeDesktop::open(self : LinuxNativeDesktop, options : ViewOptions) -> ScreenView {
  guard self.o.binary is Some(binary) else {
    raise self.io.refused(501, "station.screen.noHelper", access=Some(self.access()))
  }
  guard codec_for(options, [H264, Jpeg]) is Some(codec) else {
    raise self.io.refused(415, "station.screen.codec", args=jo([("codec", js("H.264, JPEG"))]))
  }
  self.refresh()
  if !self.available_ {
    raise self.io.refused(503, "station.screen.linuxUnavailable", access=Some(self.access()))
  }
  let input = LinuxInput::new()
  let ask = jsome([
    ("codec", Some(js(codec.name()))),
    ("maxWidth", Some(jn(options.max_width))),
    ("maxHeight", Some(jn(options.max_height))),
    ("bitrate", options.bitrate.map(b => jn(js_round(b)))),
    ("fps", options.fps.map(jn)),
  ])
  let first = self.start_view(binary, codec, ask, input) catch {
    e => raise self.io.refused(503, "station.screen.failed", args=jo([("said", js(message_of(e)))]))
  }
  let view_ref : Ref[LastingView?] = Ref(None)
  let view = LastingView::new(self.io, first, async fn() { self.start_view(binary, codec, ask, input) }, () => {
    match view_ref.val {
      Some(v) =>
        match self.views.search_by(x => physical_equal(x, v)) {
          Some(i) => ignore(self.views.remove(i))
          None => ()
        }
      None => ()
    }
  })
  view_ref.val = Some(view)
  self.views.push(view)
  view.view()
}

///|
async fn LinuxNativeDesktop::start_view(
  self : LinuxNativeDesktop,
  binary : String,
  codec : Codec,
  ask : J,
  input : LinuxInput,
) -> HelperView {
  let told = ChildTold::new()
  let child = (self.starter().start)(binary, ["view"], self.env(), told.events())
  (child.write)(@utf8.encode(stringify(ask) + "\n"), None)
  let capture = if self.backend_ == Some("wayland") {
    "Wayland (wlr-screencopy)"
  } else {
    "X11 (MIT-SHM+XDamage)"
  }
  let view = HelperView::new(
    self.io,
    codec,
    child_pipe(self.io, child, told),
    () => (),
    input=Some(input.input_ops()),
    capture~,
    audio=false,
    mic=false,
  )
  try {
    ignore(view.ready.wait())
    view
  } catch {
    e => {
      view.close()
      raise e
    }
  }
}

///|
pub fn LinuxNativeDesktop::close(self : LinuxNativeDesktop) -> Unit {
  for v in self.views.copy() {
    v.close()
  }
}

///|
pub fn LinuxNativeDesktop::source(self : LinuxNativeDesktop) -> ScreenSource {
  {
    ..ScreenSource::bare("desktop", DesktopKind, () => self.title(), () => self.size(), async fn(o) { self.open(o) }),
    access: Some(() => self.access()),
  }
}
