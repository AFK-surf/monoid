// This Windows machine's display as a screen source (`desktop`; src/screens/win-desktop.ts): stillfail-screen
// (station/native/screen) captures the main display with Windows.Graphics.Capture, encodes H.265 or H.264 with Media
// Foundation (the hardware encoder where there is one), or a JPEG a picture, and posts the input with SendInput. Each
// view is a process of its own, started with `view` and spoken to on its standard input and output in still.fail
// Helper's messages (desktop.mbt `HelperView`); it ends as its input does.
//
// Nothing is granted on Windows: a station runs in its person's session, where the display can be captured and
// driven. What cannot be is what Windows keeps from any app there: the sign-in and UAC's secure desktop, and windows of
// apps run as administrator.

///|
pub const SCREEN_BINARY : String = "stillfail-screen.exe"

///|
/// Where stillfail-screen was found, by its override (STILLFAIL_SCREEN): looked for again only where it was not.
let screen_found : Map[String, String] = Map::new()

///|
/// The release's stillfail-screen: STILLFAIL_SCREEN, beside the station's code in a release, or built in the checkout.
pub fn screen_binary(io : Io, env : Env) -> String? {
  let key = env.get("STILLFAIL_SCREEN").unwrap_or("")
  match screen_found.get(key) {
    Some(kept) => return Some(kept)
    None => ()
  }
  let candidates = [
    env.get("STILLFAIL_SCREEN"),
    Some(pj([io.os.code_dir, SCREEN_BINARY])),
    Some(pj([io.os.code_dir, "..", "..", "native", "screen", "target", "release", SCREEN_BINARY])),
  ]
  for p in candidates {
    match p {
      Some(p) if p != "" && (io.fs.exists_sync)(p) => {
        screen_found[key] = p
        return Some(p)
      }
      _ => ()
    }
  }
  None
}

///|
/// A scale as stillfail-screen says it, checked: none when it is not one.
pub fn scale_of(told : J?) -> ScreenScale? {
  let n = (v : J) => match v {
    Num(d) => is_integer(d) && d >= 100.0 && d <= 500.0
    _ => false
  }
  guard told is Some(Obj(_) as t) else { return None }
  guard get(Some(t), "percent") is Some(Num(percent)) && n(Num(percent)) else { return None }
  guard get(Some(t), "recommended") is Some(Num(recommended)) && n(Num(recommended)) else { return None }
  guard get(Some(t), "steps") is Some(Arr(steps)) && steps.iter().all(n) else { return None }
  Some({ percent, recommended, steps: steps.map(s => num(Some(s)).unwrap()) })
}

///|
/// A resolution as a helper says it (stillfail-screen, still.fail Helper), checked: none when it is not one.
pub fn resolution_of(told : J?) -> ScreenResolution? {
  let n = (v : J?) => match v {
    Some(Num(d)) => is_integer(d) && d > 0.0 && d <= 16384.0
    _ => false
  }
  let size = (v : J) => v is Obj(_) && n(get(Some(v), "width")) && n(get(Some(v), "height"))
  guard told is Some(t) && size(t) else { return None }
  guard get(Some(t), "modes") is Some(Arr(modes)) && modes.iter().all(size) else { return None }
  Some({
    width: num(get(Some(t), "width")).unwrap(),
    height: num(get(Some(t), "height")).unwrap(),
    modes: modes.map(m => (num(get(Some(m), "width")).unwrap(), num(get(Some(m), "height")).unwrap())),
  })
}

///|
/// How the process is started (a test's own in tests): stdin and stdout piped, stderr let go, no window.
pub(all) struct ScreenStart {
  start : (String, Array[String], ChildEvents) -> Child
}

///|
fn default_start(io : Io) -> ScreenStart {
  { start: (binary, args, events) => (io.procs.spawn)(binary, args, { env: None, group: false, verbatim: false, stdio: ("pipe", "pipe", "ignore") }, events) }
}

///|
/// What the Windows desktop is given: stillfail-screen (none where the release has none), agent-desktop, who is told
/// it changed, its title, and how its processes are started.
pub(all) struct WindowsDesktopOptions {
  binary : String?
  ui : String?
  changed : () -> Unit
  title : (() -> String)?
  start : ScreenStart?
}

///|
/// A status this recent is not asked again (unless forced).
const WIN_FRESH_MS : Double = 2000

///|
/// A child's events, as they come, to who listens later (a pipe's listeners, given after it started).
struct ChildTold {
  mut out : (Bytes) -> Unit
  mut close : (Int?, String?) -> Unit
  mut error : (String) -> Unit
}

///|
fn ChildTold::new() -> ChildTold {
  { out: _ => (), close: (_, _) => (), error: _ => () }
}

///|
fn ChildTold::events(self : ChildTold) -> ChildEvents {
  { out: b => (self.out)(b), err: _ => (), error: e => (self.error)(e), close: (c, s) => (self.close)(c, s) }
}

///|
/// The Windows display (win-desktop.ts `WindowsDesktop`).
pub struct WindowsDesktop {
  priv io : Io
  priv o : WindowsDesktopOptions
  priv views : Array[LastingView]
  priv mut status_ : (Double, Double, Bool)?
  priv mut looked : Double
  priv looking : Shared[Unit]
  /// The display's scale before a view first changed it, put back once the last view ends; none while unchanged.
  priv mut original : Double?
  priv scaling : Chain
  priv mut original_size : (Double, Double)?
  priv sizing : Chain
}

///|
pub fn WindowsDesktop::new(io : Io, o : WindowsDesktopOptions) -> WindowsDesktop {
  {
    io,
    o,
    views: [],
    status_: None,
    looked: 0.0,
    looking: Shared::new(),
    original: None,
    scaling: Chain::new(),
    original_size: None,
    sizing: Chain::new(),
  }
}

///|
fn WindowsDesktop::starter(self : WindowsDesktop) -> ScreenStart {
  self.o.start.unwrap_or(default_start(self.io))
}

///|
pub fn WindowsDesktop::title(self : WindowsDesktop) -> String {
  match self.o.title {
    Some(f) => f()
    None => (self.io.os.hostname)()
  }
}

///|
pub fn WindowsDesktop::size(self : WindowsDesktop) -> (Double, Double) {
  match self.status_ {
    Some((w, h, _)) => (w, h)
    None => (0.0, 0.0)
  }
}

///|
pub fn WindowsDesktop::clipboard(self : WindowsDesktop) -> Array[String] {
  if self.o.binary is None {
    []
  } else {
    ["text", "png"]
  }
}

///|
pub fn WindowsDesktop::access(self : WindowsDesktop) -> ScreenAccess {
  if self.o.binary is None {
    return ScreenAccess::new(false, false, unsupported=Some("helper"))
  }
  // A Windows without the capture (before 10 1903).
  match self.status_ {
    Some((_, _, false)) => ScreenAccess::new(false, false, unsupported=Some("platform"))
    _ => ScreenAccess::new(true, true)
  }
}

///|
/// The display's size as Windows has it now (at most a moment old, unless `force`).
pub async fn WindowsDesktop::refresh(self : WindowsDesktop, force? : Bool = false) -> Unit {
  if self.o.binary is None {
    return
  }
  if !force && self.io.clock.ms() - self.looked < WIN_FRESH_MS {
    return
  }
  self.looking
  .start(self.io, async fn() {
    try {
      let told = self.ask(["status"])
      let display = get(Some(told), "display")
      let status = (
        number_or_zero(get(display, "width")),
        number_or_zero(get(display, "height")),
        !(get(Some(told), "capture") is Some(Bool(false))),
      )
      let before = self.status_
      self.status_ = Some(status)
      match before {
        Some(b) if b == status => ()
        _ => (self.o.changed)()
      }
    } catch {
      e => self.io.log.warn("screens", "stillfail-screen did not say the display", fields=jo([("error", js(message_of(e)))]))
    }
    self.looked = self.io.clock.ms()
  })
  .wait()
}

///|
/// What `stillfail-screen <args>` says (its one JSON line); fails with what it said wrong.
async fn WindowsDesktop::ask(self : WindowsDesktop, args : Array[String]) -> J {
  guard self.o.binary is Some(binary) else { raise fail("stillfail-screen is not there") }
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
          Ok(told) =>
            match get(Some(told), "error") {
              Some(Str(_) as e) => ignore(d.fail(fail(text(Some(e)).unwrap_or(""))))
              _ => ignore(d.succeed(told))
            }
          Err(e) => ignore(d.fail(fail(json_error_message(e))))
        }
    }
  }
  let child = (self.starter().start)(binary, args, {
    out: b => said.write_bytes(b),
    err: _ => (),
    error: e => done(Some(e)),
    close: (_, _) => done(None),
  })
  unarm.val = (self.io.clock.after)(10000.0, () => (child.kill)("SIGTERM"))
  (child.end_input)(None)
  d.wait()
}

///|
/// As it is once the changes asked before are made.
pub async fn WindowsDesktop::scale(self : WindowsDesktop) -> ScreenScale? {
  self.scaling.then(self.io, async fn() {
    let told = self.ask(["scale"]) catch {
      e => {
        self.io.log.info("screens", "the display's scale was not had", fields=jo([("error", js(message_of(e)))]))
        return None
      }
    }
    scale_of(Some(told))
  })
}

///|
pub async fn WindowsDesktop::set_scale(self : WindowsDesktop, percent : Double) -> ScreenScale {
  self.scaling.then(self.io, async fn() {
    if self.original is None {
      guard scale_of(Some(self.ask(["scale"]))) is Some(before) else { raise fail("the display's scale was not had") }
      self.original = Some(before.percent)
    }
    guard scale_of(Some(self.ask(["scale", num_text(js_round(percent))]))) is Some(now) else {
      raise fail("the display's scale was not had")
    }
    self.io.log.info(
      "screens",
      "the display's scale set",
      fields=jsome([("percent", Some(jn(now.percent))), ("was", self.original.map(jn))]),
    )
    now
  })
}

///|
/// As it is once the changes asked before are made.
pub async fn WindowsDesktop::resolution(self : WindowsDesktop) -> ScreenResolution? {
  self.sizing.then(self.io, async fn() {
    let told = self.ask(["resolution"]) catch {
      e => {
        self.io.log.info("screens", "the display's resolution was not had", fields=jo([("error", js(message_of(e)))]))
        return None
      }
    }
    resolution_of(Some(told))
  })
}

///|
fn size_j(s : (Double, Double)?) -> J {
  match s {
    Some((w, h)) => jo([("width", jn(w)), ("height", jn(h))])
    None => Null
  }
}

///|
pub async fn WindowsDesktop::set_resolution(self : WindowsDesktop, width : Double, height : Double) -> ScreenResolution {
  self.sizing.then(self.io, async fn() {
    if self.original_size is None {
      guard resolution_of(Some(self.ask(["resolution"]))) is Some(before) else {
        raise fail("the display's resolution was not had")
      }
      self.original_size = Some((before.width, before.height))
    }
    guard resolution_of(Some(self.ask(["resolution", "\{num_text(js_round(width))}x\{num_text(js_round(height))}"]))) is Some(now) else {
      raise fail("the display's resolution was not had")
    }
    self.io.log.info(
      "screens",
      "the display's resolution set",
      fields=jo([("width", jn(now.width)), ("height", jn(now.height)), ("was", size_j(self.original_size))]),
    )
    // (its size another now: listed anew)
    (self.o.changed)()
    now
  })
}

///|
/// The last view ended: the display's scale and resolution as they were before a view changed them.
fn WindowsDesktop::put_back(self : WindowsDesktop) -> Unit {
  if self.views.length() > 0 {
    return
  }
  match self.original_size {
    Some((w, h)) => {
      self.original_size = None
      let size = jo([("width", jn(w)), ("height", jn(h))])
      self.sizing.after(self.io, async fn() {
        try {
          ignore(self.ask(["resolution", "\{num_text(w)}x\{num_text(h)}"]))
          self.io.log.info("screens", "the display's resolution put back", fields=size)
          (self.o.changed)()
        } catch {
          e =>
            self.io.log.warn(
              "screens",
              "the display's resolution was not put back",
              fields=spread(size, jo([("error", js(message_of(e)))])),
            )
        }
      })
    }
    None => ()
  }
  guard self.original is Some(original) else { return }
  self.original = None
  self.scaling.after(self.io, async fn() {
    try {
      ignore(self.ask(["scale", num_text(original)]))
      self.io.log.info("screens", "the display's scale put back", fields=jo([("percent", jn(original))]))
    } catch {
      e =>
        self.io.log.warn(
          "screens",
          "the display's scale was not put back",
          fields=jo([("percent", jn(original)), ("error", js(message_of(e)))]),
        )
    }
  })
}

///|
pub async fn WindowsDesktop::open(self : WindowsDesktop, options : ViewOptions) -> ScreenView {
  guard self.o.binary is Some(binary) else {
    raise self.io.refused(501, "station.screen.noHelper", access=Some(self.access()))
  }
  // H.265 where it is taken, H.264, else a JPEG a picture (an agent's view, a client without either).
  guard codec_for(options, [H265, H264, Jpeg]) is Some(codec) else {
    raise self.io.refused(415, "station.screen.codec", args=jo([("codec", js("H.264, JPEG"))]))
  }
  self.refresh()
  if self.status_ is Some((_, _, false)) {
    raise self.io.refused(501, "station.screen.unsupported", access=Some(self.access()))
  }
  let input = WinInput::new()
  // The system output too, as Opus where the viewer decodes it.
  let audio = options.audio && !options.peek
  let ask = jsome([
    ("codec", Some(js(codec.name()))),
    ("audio", if audio { Some(jb(true)) } else { None }),
    ("audioCodec", if audio && options.opus { Some(js("opus")) } else { None }),
    ("maxWidth", Some(jn(options.max_width))),
    ("maxHeight", Some(jn(options.max_height))),
    ("bitrate", options.bitrate.map(b => jn(js_round(b)))),
    ("fps", options.fps.map(jn)),
    ("peek", if options.peek { Some(jb(true)) } else { None }),
    ("agent", if options.agent { Some(jb(true)) } else { None }),
  ])
  let first = self.start_view(binary, codec, ask, audio, input) catch {
    e => raise self.io.refused(503, "station.screen.failed", args=jo([("said", js(message_of(e)))]))
  }
  let view_ref : Ref[LastingView?] = Ref(None)
  let view = LastingView::new(self.io, first, async fn() { self.start_view(binary, codec, ask, audio, input) }, () => {
    match view_ref.val {
      Some(v) =>
        match self.views.search_by(x => physical_equal(x, v)) {
          Some(i) => ignore(self.views.remove(i))
          None => ()
        }
      None => ()
    }
    self.put_back()
  })
  view_ref.val = Some(view)
  self.views.push(view)
  view.view()
}

///|
/// One process for a view, answering (its info had); fails with what it said.
async fn WindowsDesktop::start_view(
  self : WindowsDesktop,
  binary : String,
  codec : Codec,
  ask : J,
  audio : Bool,
  input : WinInput,
) -> HelperView {
  let told = ChildTold::new()
  let child = (self.starter().start)(binary, ["view"], told.events())
  (child.write)(@utf8.encode(stringify(ask) + "\n"), None)
  let view = HelperView::new(
    self.io,
    codec,
    child_pipe(self.io, child, told),
    () => (),
    input=Some(input.input_ops()),
    capture="Windows.Graphics.Capture",
    audio~,
    mic=true,
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
/// Its apps' accessibility trees: agent-desktop started here, in the person's session as the station is.
pub async fn WindowsDesktop::ui(self : WindowsDesktop, args : Array[String]) -> J {
  match self.o.ui {
    Some(binary) => process_ui(self.io, binary)(args)
    None => raise fail("this station's release carries no agent-desktop (update the station)")
  }
}

///|
/// The station stopping: every view ends.
pub fn WindowsDesktop::close(self : WindowsDesktop) -> Unit {
  for v in self.views.copy() {
    v.close()
  }
}

///|
pub fn WindowsDesktop::source(self : WindowsDesktop) -> ScreenSource {
  {
    ..ScreenSource::bare("desktop", DesktopKind, () => self.title(), () => self.size(), async fn(o) { self.open(o) }),
    reveal: true,
    access: Some(() => self.access()),
    clipboard: Some(() => self.clipboard()),
    scale: Some(async fn() { self.scale() }),
    set_scale: Some(async fn(p) { self.set_scale(p) }),
    resolution: Some(async fn() { self.resolution() }),
    set_resolution: Some(async fn(w, h) { self.set_resolution(w, h) }),
    ui: Some(async fn(args) { self.ui(args) }),
  }
}

///|
/// Started again this many times within RESTARTS_MS, a view ends instead.
const RESTARTS : Int = 3

///|
const RESTARTS_MS : Double = 60000

///|
/// A view that outlives its process (win-desktop.ts `LastingView`): one that ended without being asked is started
/// again, and the view goes on from a key frame with its config, the clipboard still watched. Closed, or started again
/// too often, it ends as any view does.
pub struct LastingView {
  priv io : Io
  priv mut view_ : HelperView
  priv again : async () -> HelperView
  priv gone : () -> Unit
  priv mut closed : Bool
  priv mut restarts : Array[Double]
  /// The process being started again: every pending `next` waits for the one.
  priv restarting : Shared[Bool]
  priv mut heard : (Int, (Clip) -> Unit)?
  priv mut unwatch : (() -> Unit)?
  priv mut pointer : (Int, (ScreenCursor) -> Unit)?
  priv mut unpoint : (() -> Unit)?
  /// Who hears the virtual microphone, heard again from a process started again.
  priv mut mic_heard : (Int, (ScreenMic) -> Unit)?
  priv mut unmic : (() -> Unit)?
  priv mut rate_ : Double?
  priv mut bounds_ : (Double, Double, Region?)?
  priv mut next_id : Int
}

///|
pub fn LastingView::new(io : Io, view : HelperView, again : async () -> HelperView, gone : () -> Unit) -> LastingView {
  {
    io,
    view_: view,
    again,
    gone,
    closed: false,
    restarts: [],
    restarting: Shared::new(),
    heard: None,
    unwatch: None,
    pointer: None,
    unpoint: None,
    mic_heard: None,
    unmic: None,
    rate_: None,
    bounds_: None,
    next_id: 0,
  }
}

///|
pub async fn LastingView::next(self : LastingView) -> Frame? {
  while true {
    let view = self.view_
    let frame = view.next()
    if frame is Some(_) || self.closed {
      return frame
    }
    // Another `next` already started it again: this one asks the new process.
    if physical_equal(self.view_, view) && !self.restarting.start(self.io, async fn() { self.restart() }).wait() {
      return None
    }
    if self.closed {
      return None
    }
  }
  None
}

///|
pub async fn LastingView::next_audio(self : LastingView) -> AudioFrame? {
  while true {
    let view = self.view_
    let audio = view.next_audio()
    if audio is Some(_) || self.closed || !view.has_audio() {
      return audio
    }
    if physical_equal(self.view_, view) && !self.restarting.start(self.io, async fn() { self.restart() }).wait() {
      return None
    }
    if self.closed {
      return None
    }
  }
  None
}

///|
async fn LastingView::restart(self : LastingView) -> Bool {
  let now = self.io.clock.ms()
  let kept = self.restarts.filter(t => now - t < RESTARTS_MS)
  kept.push(now)
  self.restarts = kept
  if self.restarts.length() > RESTARTS {
    self.io.log.warn("screens", "stillfail-screen keeps ending; the view ends")
    self.close()
    return false
  }
  try {
    let view = (self.again)()
    if self.closed {
      view.close()
      return false
    }
    self.io.log.info("screens", "stillfail-screen ended by itself; started again")
    self.view_ = view
    match self.heard {
      Some((_, f)) => self.unwatch = Some(view.watch_clipboard(f))
      None => ()
    }
    match self.pointer {
      Some((_, f)) => self.unpoint = Some(view.watch_cursor(f))
      None => ()
    }
    match self.mic_heard {
      Some((_, f)) => self.unmic = Some(view.watch_mic(f))
      None => ()
    }
    match self.rate_ {
      Some(r) => view.rate(r)
      None => ()
    }
    match self.bounds_ {
      Some((w, h, r)) => view.bounds(w, h, r)
      None => ()
    }
    true
  } catch {
    e => {
      self.io.log.warn("screens", "stillfail-screen did not start again", fields=jo([("error", js(message_of(e)))]))
      self.close()
      false
    }
  }
}

///|
pub fn LastingView::keyframe(self : LastingView) -> Unit {
  self.view_.keyframe()
}

///|
pub fn LastingView::video(self : LastingView) -> ScreenVideo {
  self.view_.video()
}

///|
pub fn LastingView::rate(self : LastingView, bits : Double) -> Unit {
  self.rate_ = Some(bits)
  self.view_.rate(bits)
}

///|
pub fn LastingView::bounds(self : LastingView, w : Double, h : Double, region : Region?) -> Unit {
  self.bounds_ = Some((w, h, region))
  self.view_.bounds(w, h, region)
}

///|
pub fn LastingView::regions(self : LastingView) -> Bool {
  self.view_.regions()
}

///|
pub fn LastingView::input(self : LastingView, event : ScreenInput) -> Unit {
  self.view_.input(event)
}

///|
pub fn LastingView::set_clipboard(self : LastingView, clip : Clip, paste : Bool) -> Unit {
  self.view_.set_clipboard(clip, paste)
}

///|
pub fn LastingView::watch_clipboard(self : LastingView, heard : (Clip) -> Unit) -> () -> Unit {
  self.next_id += 1
  let id = self.next_id
  self.heard = Some((id, heard))
  self.unwatch = Some(self.view_.watch_clipboard(heard))
  () => match self.heard {
    Some((i, _)) if i == id => {
      self.heard = None
      match self.unwatch {
        Some(f) => f()
        None => ()
      }
      self.unwatch = None
    }
    _ => ()
  }
}

///|
pub fn LastingView::reveal(self : LastingView, path : String) -> Unit {
  self.view_.reveal(path)
}

///|
pub fn LastingView::watch_cursor(self : LastingView, heard : (ScreenCursor) -> Unit) -> () -> Unit {
  self.next_id += 1
  let id = self.next_id
  self.pointer = Some((id, heard))
  self.unpoint = Some(self.view_.watch_cursor(heard))
  () => match self.pointer {
    Some((i, _)) if i == id => {
      self.pointer = None
      match self.unpoint {
        Some(f) => f()
        None => ()
      }
      self.unpoint = None
    }
    _ => ()
  }
}

///|
pub fn LastingView::cursor_image(self : LastingView, shape : String) -> Bytes? {
  self.view_.cursor_image(shape)
}

///|
pub fn LastingView::close(self : LastingView) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.view_.close()
  (self.gone)()
}

///|
pub fn LastingView::watch_mic(self : LastingView, heard : (ScreenMic) -> Unit) -> () -> Unit {
  self.next_id += 1
  let id = self.next_id
  self.mic_heard = Some((id, heard))
  self.unmic = Some(self.view_.watch_mic(heard))
  () => match self.mic_heard {
    Some((i, _)) if i == id => {
      self.mic_heard = None
      match self.unmic {
        Some(f) => f()
        None => ()
      }
      self.unmic = None
    }
    _ => ()
  }
}

///|
pub fn LastingView::view(self : LastingView) -> ScreenView {
  {
    ..ScreenView::bare(
      async fn() { self.next() },
      () => self.keyframe(),
      async fn(e) { self.input(e) },
      () => self.close(),
    ),
    next_audio: Some(async fn() { self.next_audio() }),
    rate: Some(b => self.rate(b)),
    bounds: Some((w, h, r) => self.bounds(w, h, r)),
    regions: Some(() => self.regions()),
    video: Some(() => self.video()),
    set_clipboard: Some(async fn(c, p) { self.set_clipboard(c, p) }),
    watch_clipboard: Some(f => self.watch_clipboard(f)),
    reveal: Some(async fn(p) { self.reveal(p) }),
    watch_cursor: Some(f => self.watch_cursor(f)),
    cursor_image: Some(s => self.cursor_image(s)),
    watch_mic: Some(f => self.watch_mic(f)),
    feed_mic: Some((p, e) => self.view_.feed_mic(p, e)),
  }
}

///|
/// A view's process as the helper's connection (win-desktop.ts `childPipe`): its output read, its input written;
/// destroyed, its input ends (the process ends with it) and it is ended outright if it has not in a moment.
pub fn child_pipe(io : Io, child : Child, told : ChildTold) -> HelperPipe {
  let closed = Ref(false)
  let data_l : Array[(Bytes) -> Unit] = []
  let close_l : Array[() -> Unit] = []
  let close = () => {
    if closed.val {
      return
    }
    closed.val = true
    for f in close_l.copy() {
      f()
    }
  }
  told.out = b => for f in data_l.copy() {
    f(b)
  }
  // Its output read to the end first: what it said as it went is had.
  told.close = (_, _) => close()
  told.error = e => {
    io.log.warn("screens", "stillfail-screen did not start", fields=jo([("error", js(e))]))
    close()
  }
  {
    write: b => (child.write)(b, None),
    destroy: () => {
      (child.end_input)(None)
      ignore((io.clock.after)(2000.0, () => if (child.running)() { (child.kill)("SIGTERM") }))
    },
    on_data: f => data_l.push(f),
    on_error: _ => (),
    on_close: f => close_l.push(f),
  }
}
