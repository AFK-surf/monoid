// A view of one of the station's screens while it lasts (station/src/mesh/screens.ts `answerScreen`, `ViewSession`):
// the stream answered, the source opened, its frames sent as the pace lets them, its sound beside them, and what the
// client sends taken (its acknowledgements, a key frame asked, its look, its input, its clipboard). The screens
// themselves are given as ports (`ScreenHubPort`, `ScreenSourcePort`, `ScreenViewPort`): the station's hub and sources
// (station/src/screens/) are not this package's. Words a person reads are the given `tr`'s.

///|
/// The longest address a tab's view is told.
pub let address_most : Int = 2048

///|
/// Words in a language by their key (`tr(lang, key, args)`).
pub type Tr = (String, String, Json) -> String

///|
/// A line of the log: level, part, words, what with them.
pub type Said = (String, String, String, Json) -> Unit

///|
/// A source that cannot be opened now (screens/hub.ts `ScreenRefused`): the status, the words' key and their arguments,
/// and what of its access is missing.
pub(all) suberror ScreenRefused {
  ScreenRefused(Int, String, Json, Json?)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for ScreenRefused with output(self, logger) {
  match self {
    ScreenRefused(_, key, _, _) => logger.write_string(key)
  }
}

///|
/// One encoded frame (source.ts `Frame`): its config before it where it changed, whether it is a key frame, its time
/// (µs) and its bytes.
pub(all) struct ScreenFrame {
  config : FrameConfig?
  key : Bool
  ts : Double
  data : Bytes
}

///|
/// A frame's format (source.ts `FrameConfig`).
pub(all) struct FrameConfig {
  codec : String
  width : Double
  height : Double
  description : Bytes?
  region : Region?
}

///|
/// A packet of system output (source.ts `AudioFrame`).
pub(all) struct AudioPacket {
  ts : Double
  data : Bytes
  codec : String
}

///|
/// A view a source opened (source.ts `ScreenView`): what it lacks is None. Its JSON is as the TypeScript's types say it.
pub(all) struct ScreenViewPort {
  next : async () -> ScreenFrame?
  next_audio : (async () -> AudioPacket?)?
  keyframe : () -> Unit
  input : async (Json) -> Unit
  rate : ((Double) -> Unit)?
  /// The bounds, and the part of the screen where one is looked at (None: not said).
  bounds : ((Double, Double, Region?) -> Unit)?
  regions : (() -> Bool)?
  video : (() -> Json?)?
  why : (() -> String?)?
  close : () -> Unit
  set_clipboard : (async (Clip, Bool) -> Unit)?
  watch_clipboard : (((Clip) -> Unit) -> () -> Unit)?
  watch_cursor : (((Json) -> Unit) -> () -> Unit)?
  /// The picture of a pointer of an app's own `watch_cursor` said as "custom:<id>".
  cursor_image : ((String) -> Bytes?)?
  watch_turn : (((Json) -> Unit) -> () -> Unit)?
  watch_windows : (((Json) -> Unit) -> () -> Unit)?
  window : ((Double?) -> Unit)?
  reveal : (async (String) -> Unit)?
  watch_login : (((Json) -> Unit) -> () -> Unit)?
  fill : (async (Json) -> Unit)?
  watch_passkey : (((Json) -> Unit) -> () -> Unit)?
  passkey : (async (Json) -> Unit)?
  watch_child : (((String) -> Unit) -> () -> Unit)?
  /// The clipboard set and heard with its mark (0 none, 1 concealed, 2 transient, 3 auto), where the view carries marks.
  set_clipboard_marked : (async (Clip, Bool, Int) -> Unit)?
  watch_clipboard_marked : (((Clip, Int) -> Unit) -> () -> Unit)?
  /// Hears whether an app on the screen holds the pointer.
  watch_pointer_lock : (((Bool) -> Unit) -> () -> Unit)?
}

///|
/// A screen (source.ts `ScreenSource`), as a view of it reads it. `open` raises `ScreenRefused` where it cannot be seen.
pub(all) struct ScreenSourcePort {
  kind : String
  title : () -> String
  open : async (Json) -> ScreenViewPort
  access : (() -> Json?)?
  clipboard : (() -> Array[String])?
  reveal : Bool
  peek : Bool
  open_url : Bool
  user_tab : Bool
  sleeping : (() -> Bool)?
  site : (() -> String?)?
  address : (() -> String?)?
  scale : (async () -> Json?)?
  set_scale : (async (Double) -> Json)?
  resolution : (async () -> Json?)?
  set_resolution : (async (Double, Double) -> Json)?
}

///|
/// One view on a screen as its hub keeps it (hub.ts `Watcher`).
pub(all) struct Watcher {
  name : String
  device : String
  self_ : String?
  client : String?
  app : String?
  control : Bool
  tell : (Json) -> Unit
  end : (String) -> Unit
  watch_only : (String?) -> Unit
}

///|
/// The station's screens (hub.ts `ScreenHub`), as a view needs them.
pub(all) struct ScreenHubPort {
  /// The source of an id now: the same one while it lasts (told apart by `physical_equal`).
  get : (String) -> ScreenSourcePort?
  /// Whether a view of `device` drives the screen, `taken` its person asking, `by` their name; and whose views it took
  /// the screen from.
  drive : (String, String, Bool, String) -> (Bool, Array[String])
  join : (String, Watcher) -> () -> Unit
  watch : (() -> Unit) -> () -> Unit
  when_stopping : (() -> Unit) -> () -> Unit
}

///|
fn same_source(a : ScreenSourcePort?, b : ScreenSourcePort) -> Bool {
  match a {
    Some(x) => physical_equal(x, b)
    None => false
  }
}

///|
/// What a person is told of a source's access when something is missing (hub.ts `accessShown`); None when nothing is.
pub fn access_shown(access : Json?, lang : String, tr : Tr) -> Json? {
  guard access is Some(Object(a)) else { return None }
  let capture = a.get("capture") is Some(True)
  let control = a.get("control") is Some(True)
  let truthy = (k : String) => match a.get(k) {
    None | Some(Null) | Some(False) => false
    Some(String(s)) => s != ""
    Some(Number(n, ..)) => n != 0.0 && !n.is_nan()
    _ => true
  }
  let unsupported = a.get("unsupported")
  let reason = a.get("reason")
  if capture && control && unsupported is None && reason is None {
    return None
  }
  let app = if truthy("app") { a.get("app").unwrap() } else { jstr("still.fail Helper") }
  let named = jobj([("app", app)])
  let none = jobj([])
  let reason_word = match reason {
    Some(String(r)) if r != "" => Some(r)
    _ => None
  }
  let message = match reason_word {
    Some(r) => tr(lang, "station.screen.\{r}", none)
    None =>
      match unsupported {
        Some(String("platform")) => tr(lang, "station.screen.unsupported", none)
        Some(String("helper")) => tr(lang, "station.screen.noHelper", none)
        _ => {
          let first = if !capture && !control {
            tr(lang, "station.screen.bothOff", named)
          } else if !capture {
            tr(lang, "station.screen.captureOff", named)
          } else {
            tr(lang, "station.screen.controlOff", named)
          }
          let then = tr(lang, if truthy("asking") { "station.screen.asking" } else { "station.screen.toAsk" }, named)
          "\{first} \{then}"
        }
      }
  }
  let help = match reason_word {
    Some(
      "linuxNoDisplay" | "linuxTools" | "linuxToolsFailed" | "linuxUnavailable" | "linuxPortalUnavailable" | "linuxX11FallbackUnavailable"
    ) => true
    _ => false
  }
  let out = [("capture", Json::boolean(capture)), ("control", Json::boolean(control)), ("message", jstr(message))]
  if truthy("app") {
    out.push(("app", a.get("app").unwrap()))
  }
  if truthy("path") {
    out.push(("path", a.get("path").unwrap()))
  }
  if truthy("asking") {
    out.push(("asking", Json::boolean(true)))
  }
  if help {
    out.push(("help", jstr("linux-desktop")))
  }
  Some(jobj(out))
}

///|
/// A tab's address as it is shown (hub.ts `addressShown`): none where it is none or too long.
pub fn address_shown(address : String?) -> String? {
  match address {
    Some(a) if a != "" && a.length() <= address_most => Some(a)
    _ => None
  }
}

///|
/// The language a core said in its headers (request.ts `langOfCore`).
pub fn lang_of_core(headers : Array[(String, String)]) -> String {
  for kv in headers {
    if lower(kv.0) == "stillfail-lang" {
      let l = lower(js_trim(kv.1))
      return if l == "" || l.has_prefix("zh") { "zh" } else { "en" }
    }
  }
  "zh"
}

///|
/// `s.toUpperCase()` as far as it can come to `POST`: ASCII, and the two letters that uppercase into it.
fn upper(s : String) -> String {
  let b = StringBuilder()
  for c in s {
    b.write_char(
      if c >= 'a' && c <= 'z' {
        (c.to_int() - 32).unsafe_to_char()
      } else if c == '\u{17f}' {
        'S'
      } else if c == '\u{131}' {
        'I'
      } else {
        c
      },
    )
  }
  b.to_string()
}

///|
/// `decodeURIComponent(s)`; None where it throws (a `%` not of two hex digits, bytes that are no UTF-8).
pub fn decode_uri_component(s : String) -> String? {
  @url.decode_uri_component(s)
}

///|
/// `/^\/admin\/api\/screens\/([^/?]+)\/view$/`: the screen's id as the path has it.
fn view_path(path : String) -> String? {
  let prefix = "/admin/api/screens/"
  let suffix = "/view"
  if !path.has_prefix(prefix) || !path.has_suffix(suffix) || path.length() < prefix.length() + suffix.length() + 1 {
    return None
  }
  let id = path.clamped_view(start=prefix.length(), end=path.length() - suffix.length()).to_owned()
  if id.iter().any(c => c == '/' || c == '?') {
    None
  } else {
    Some(id)
  }
}

///|
/// A line of JSON as JavaScript writes it (wire.ts `writeLine`).
async fn js_line(stream : @door.Stream, value : Json) -> Unit {
  (stream.write)(@utf8.encode(js_stringify(value) + "\n"))
}

///|
fn config_bytes(c : FrameConfig) -> Bytes {
  config_payload(c.codec, c.width, c.height, c.description, c.region)
}

///|
/// A stream whose head says `screen` (`answerScreen`): a view of a screen, for as long as both sides keep it. `carry`:
/// what came after the head line; `viewer`: who (`{name, email, role, device}`); `up`: whether the station has started;
/// `paths`: the ways of the connection it came on, whose counters say what of the view's link was lost (None: nothing
/// said of it) and where it goes (what the view starts at: `start_rate_of`); `rt`: the view's clock (ms); `host_now`:
/// the clock a frame's capture time is on (screen-pace.ts `hostNow`, the helpers' monotonic one; by default the view's);
/// `stall`: how long the station's loop stood still, and its end (the live clock's alone); `media_datagrams`: the
/// stream's frames of picture and sound sent as datagrams under the client's token from now on (the shell's
/// `istream.mediaDatagrams`), whether they are (None: a stream that cannot, on as before).
pub async fn answer_screen(
  hub : ScreenHubPort,
  stream : @door.Stream,
  carry : Bytes,
  head : Json,
  viewer : Json,
  up : () -> Bool,
  rt : @effect.Runtime,
  tr : Tr,
  said : Said,
  paths? : (() -> Array[LinkPath])? = None,
  host_now? : (() -> Double)? = None,
  stall? : (() -> Double, () -> Unit) = (() => 0.0, () => ()),
  media_datagrams? : (async (Double) -> Bool)? = None,
) -> Unit {
  let headers = match field(head, "headers") {
    Some(Object(m)) => {
      let out = []
      for k, v in m {
        if v is String(s) {
          out.push((k, s))
        }
      }
      out
    }
    _ => []
  }
  let lang = lang_of_core(headers)
  let refuse = async fn(status : Int, error : String, more : Array[(String, Json)]) {
    js_line(stream, jobj([("status", jnum(status.to_double())), ("headers", jobj([("content-type", jstr("application/json"))]))]))
    let body = [("error", jstr(error))]
    for m in more {
      body.push(m)
    }
    (stream.write)(@utf8.encode(js_stringify(jobj(body))))
    (stream.finish)()
  }
  let verb = match field(head, "method") {
    Some(String(m)) => upper(m)
    _ => "GET"
  }
  let path = str_of(field(head, "path")).unwrap_or("")
  guard view_path(path) is Some(raw_id) && verb == "POST" else {
    return refuse(404, "a screen is viewed with POST /admin/api/screens/<id>/view", [])
  }
  if !up() {
    return refuse(502, "station unreachable: not started", [])
  }
  let none = jobj([])
  guard decode_uri_component(raw_id) is Some(id) else { return refuse(404, tr(lang, "station.screen.notFound", none), []) }
  guard (hub.get)(id) is Some(source) else { return refuse(404, tr(lang, "station.screen.notFound", none), []) }
  let ask = asked(field(head, "screen").unwrap_or(Json::null()))
  let ask_codecs = match field(ask, "codecs") {
    Some(Array(xs)) => xs
    _ => []
  }
  if ask_codecs.length() == 0 {
    return refuse(400, "screen.codecs: one of h265, h264, jpeg", [])
  }
  let peek = field(ask, "peek") is Some(True)
  if peek && !source.peek {
    return refuse(501, "this screen is not previewed", [])
  }
  let read_only = field(viewer, "role") is Some(String("viewer"))
  if read_only && source.sleeping.map(f => f()).unwrap_or(false) {
    return refuse(403, tr(lang, "station.screen.readOnlySleeping", none), [])
  }
  let name = match field(viewer, "name") {
    Some(String(n)) if n != "" => n
    _ => str_of(field(viewer, "email")).unwrap_or("")
  }
  let device = str_of(field(viewer, "device")).unwrap_or("")
  let drives = field(ask, "control") is Some(True) && !read_only
  let (driven, driven_took) = if drives {
    (hub.drive)(id, device, field(ask, "taken") is Some(True), name)
  } else {
    (false, [])
  }
  // (asked once before the view opens: a front's connection reads its paths anew as it is asked, so the loss is
  // counted from the link as the view begins)
  let initial_paths = match paths {
    Some(f) => Some(f())
    None => None
  }
  // (a preview's at START_RATE: two pictures a second, no higher than the source's own)
  let initial_rate = match initial_paths {
    Some(ways) if !peek => start_rate_of(ways)
    _ => start_rate
  }
  let options = [
    ("maxWidth", field(ask, "maxWidth").unwrap()),
    ("maxHeight", field(ask, "maxHeight").unwrap()),
    ("codecs", Json::array(ask_codecs)),
  ]
  if field(ask, "audio") is Some(True) {
    options.push(("audio", Json::boolean(true)))
    if field(ask, "opus") is Some(True) {
      options.push(("opus", Json::boolean(true)))
    }
  }
  options.push(("bitrate", jnum(initial_rate)))
  if field(ask, "fps") is Some(f) {
    options.push(("fps", f))
  }
  if peek {
    options.push(("peek", Json::boolean(true)))
  }
  if field(ask, "fit") is Some(f) && driven {
    options.push(("fit", f))
  }
  if field(ask, "gamut") is Some(g) {
    options.push(("gamut", g))
  }
  let no_passkeys = match field(ask, "passkeys") {
    Some(False) => true
    Some(True) => false
    _ =>
      match field(ask, "app") {
        Some(String("ios" | "android" | "web")) => true
        _ => false
      }
  }
  if driven && no_passkeys {
    options.push(("passkeys", Json::boolean(false)))
  }
  if field(ask, "chroma444") is Some(True) {
    options.push(("chroma", jstr("444")))
  }
  let view = (source.open)(jobj(options)) catch {
    ScreenRefused(status, key, args, access) => {
      let shown = access_shown(access, lang, tr)
      let message = match shown {
        Some(s) => str_of(field(s, "message")).unwrap_or("")
        None => tr(lang, key, args)
      }
      return refuse(status, message, match shown { Some(s) => [("access", s)]; None => [] })
    }
    e => return refuse(503, tr(lang, "station.screen.failed", jobj([("said", jstr(message_of(e)))])), [])
  }
  if !same_source((hub.get)(id), source) {
    (view.close)()
    return refuse(404, tr(lang, "station.screen.notFound", none), [])
  }
  // its picture and sound as datagrams where the client takes them under its token and the link carries them (the
  // reply says so), else on the stream as before
  let reply_headers = [("content-type", jstr(screen_type))]
  match (field(ask, "datagrams"), media_datagrams) {
    (Some(Number(token, ..)), Some(send)) => {
      let sent = send(token) catch { _ => false }
      if sent {
        reply_headers.push((dgram_header, jstr(token.to_int64().to_string())))
      }
    }
    _ => ()
  }
  let wrote = (async fn() -> Bool {
    js_line(stream, jobj([("status", jnum(200.0)), ("headers", jobj(reply_headers))]))
    true
  })() catch {
    _ => false
  }
  if !wrote {
    (view.close)()
    return
  }
  let access = access_shown(source.access.map(f => f()).unwrap_or(None), lang, tr)
  let access_control = match access {
    Some(a) => !(field(a, "control") is Some(False))
    None => true
  }
  let control = driven && access_control
  let took = if control { driven_took } else { [] }
  let now = () => rt.now().to_double()
  let (stalled, stall_done) = stall
  let max_width = num_of(field(ask, "maxWidth")).unwrap_or(1920.0)
  let max_height = num_of(field(ask, "maxHeight")).unwrap_or(1080.0)
  let quality = str_of(field(ask, "quality"))
  let pacer = Pacer::new(now, start=Some(initial_rate), fps=num_of(field(ask, "fps")), stalled~)
  let sizer = Sizer::new(now, { max_width, max_height }, quality~)
  let session = ViewSession::new(
    hub,
    id,
    source,
    view,
    stream,
    FrameIn::new(stream.read, carry~),
    name,
    device,
    str_of(field(ask, "self")),
    str_of(field(ask, "client")),
    str_of(field(ask, "app")),
    control,
    took,
    peek,
    field(ask, "audio") is Some(True),
    access,
    lang,
    pacer,
    sizer,
    { max_width, max_height },
    quality,
    now,
    host_now.unwrap_or(now),
    rt,
    tr,
    said,
    paths,
    initial_rate,
    field(ask, "binaryCursor") is Some(True),
    field(ask, "customCursor") is Some(True),
    field(ask, "privateClip") is Some(True),
  )
  session.run() catch {
    e => {
      stall_done()
      raise e
    }
  }
  stall_done()
}

///|
/// Digital silence (`silent`): every byte 0.
fn silent(pcm : Bytes) -> Bool {
  pcm.iter().all(b => b == b'\x00')
}

///|
/// PCM's packets of silence in a row from which they are left out (`QUIET`: 200 ms).
pub let quiet : Int = 10

///|
priv struct PendingMove {
  id : Int
  buttons : Int
  mut run : async () -> Unit
}

///|
/// One view while it lasts (`ViewSession`).
priv struct ViewSession {
  hub : ScreenHubPort
  id : String
  source : ScreenSourcePort
  view : ScreenViewPort
  stream : @door.Stream
  frames : FrameIn
  name : String
  device : String
  self_ : String?
  client : String?
  app : String?
  mut control : Bool
  took : Array[String]
  peek : Bool
  audio : Bool
  access : Json?
  lang : String
  pacer : Pacer
  sizer : Sizer
  own : Bounds
  quality : String?
  now : () -> Double
  rt : @effect.Runtime
  tr : Tr
  said : Said
  latency : FrameLatency
  /// How much of what went over its link was lost, from its connection's paths.
  loss : LinkLoss
  paths : (() -> Array[LinkPath])?
  sharpen : Sharpener
  /// The rate the source was opened at.
  start_rate : Double
  /// The client reads the pointer as `cursor` frames (asked `binaryCursor`), not a state's JSON.
  binary_cursor : Bool
  /// The client draws the pointers of apps' own (asked `customCursor`), and those whose pictures it was sent.
  custom_cursor : Bool
  /// The client reads `privateClipboard` frames (asked `privateClip`).
  private_clip : Bool
  /// The controllers its input drove (their slots, as they came): let go of as it is made to only look.
  pads : Array[Int]
  mut unlock : () -> Unit
  cursor_images_sent : Map[String, Bool]
  mut closed : Bool
  over : @effect.Deferred[Unit]
  /// The writes, in order: each waits for the one before.
  mut writes : @effect.Deferred[Unit]
  /// The inputs, in order, each once the one before was posted; unsent pointer moves of the same buttons coalesce.
  mut inputs : @effect.Deferred[Unit]
  mut move_seq : Int
  mut pending_move : PendingMove?
  mut wake_ : @effect.Deferred[Unit]
  mut timed : Bool
  mut sound_on : Bool
  mut leave : () -> Unit
  mut unwatch : () -> Unit
  mut unclip : () -> Unit
  mut clip_known : Bytes?
  mut unlogin : () -> Unit
  mut unpasskey : () -> Unit
  mut unchild : () -> Unit
  mut unpoint : () -> Unit
  mut unturn : () -> Unit
  mut unwindows : () -> Unit
  mut title : String
  mut site : String?
  mut address : String?
  /// The keys down and the pointer as its input last left them, by `code || key`.
  keys : Map[String, Json]
  mut pointer : Json?
  mut rate : Double?
  mut still_wait : Bool
  mut size : (Double, Double)?
  mut region : Region?
}

///|
fn done_now() -> @effect.Deferred[Unit] {
  let d = @effect.Deferred::new()
  ignore(d.succeed(()))
  d
}

///|
fn ViewSession::new(
  hub : ScreenHubPort,
  id : String,
  source : ScreenSourcePort,
  view : ScreenViewPort,
  stream : @door.Stream,
  frames : FrameIn,
  name : String,
  device : String,
  self_ : String?,
  client : String?,
  app : String?,
  control : Bool,
  took : Array[String],
  peek : Bool,
  audio : Bool,
  access : Json?,
  lang : String,
  pacer : Pacer,
  sizer : Sizer,
  own : Bounds,
  quality : String?,
  now : () -> Double,
  host_now : () -> Double,
  rt : @effect.Runtime,
  tr : Tr,
  said : Said,
  paths : (() -> Array[LinkPath])?,
  start_rate : Double,
  binary_cursor : Bool,
  custom_cursor : Bool,
  private_clip : Bool,
) -> ViewSession {
  let loss = LinkLoss::new(now)
  // (its counters as the view begins: what went before is no part of it)
  if paths is Some(f) {
    ignore(loss.step(f()))
  }
  {
    loss,
    paths,
    hub,
    id,
    source,
    view,
    stream,
    frames,
    name,
    device,
    self_,
    client,
    app,
    control,
    took,
    peek,
    audio: audio && !peek,
    access,
    lang,
    pacer,
    sizer,
    own,
    quality,
    now,
    rt,
    tr,
    said,
    latency: FrameLatency::new(host_now),
    sharpen: Sharpener::new(),
    start_rate,
    binary_cursor,
    custom_cursor,
    private_clip,
    pads: [],
    unlock: () => (),
    cursor_images_sent: {},
    closed: false,
    over: @effect.Deferred::new(),
    writes: done_now(),
    inputs: done_now(),
    move_seq: 0,
    pending_move: None,
    wake_: done_now(),
    timed: false,
    sound_on: true,
    leave: () => (),
    unwatch: () => (),
    unclip: () => (),
    clip_known: None,
    unlogin: () => (),
    unpasskey: () => (),
    unchild: () => (),
    unpoint: () => (),
    unturn: () => (),
    unwindows: () => (),
    title: (source.title)(),
    site: source.site.map(f => f()).unwrap_or(None),
    address: address_shown(source.address.map(f => f()).unwrap_or(None)),
    keys: Map([]),
    pointer: None,
    rate: None,
    still_wait: false,
    size: None,
    region: None,
  }
}

///|
fn ViewSession::wake(self : ViewSession) -> Unit {
  ignore(self.wake_.succeed(()))
}

///|
/// A frame written after those before it (`#send`); what it gives is done once it is written (or failed).
fn ViewSession::send(self : ViewSession, kind : Int, payload : Bytes) -> @effect.Deferred[Unit] {
  let before = self.writes
  let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.writes = mine
  ignore(
    self.rt.fork_daemon("screen write", on_error=_ => ignore(mine.succeed(())), () => {
      before.wait() catch { _ => () }
      (self.stream.write)(frame(kind, payload)) catch {
        _ => self.stop(None)
      }
      ignore(mine.succeed(()))
    }),
  )
  mine
}

///|
/// The pointer as the client is told it (`#cursorShown`): one of an app's own, its picture sent first (once a view), to
/// a client that draws them; else, and where its source has no picture of it, "default".
fn ViewSession::cursor_shown(self : ViewSession, cursor : Json) -> Json {
  guard field(cursor, "shape") is Some(String(shape)) && shape.has_prefix("custom:") else { return cursor }
  if self.custom_cursor && self.cursor_images_sent.contains(shape) {
    return cursor
  }
  let image = match self.view.cursor_image {
    Some(f) if self.custom_cursor => f(shape)
    _ => None
  }
  match image {
    Some(b) => {
      if self.cursor_images_sent.length() >= cursor_images_most {
        self.cursor_images_sent.clear()
      }
      self.cursor_images_sent[shape] = true
      ignore(self.send(kind_cursor_image, b))
      cursor
    }
    None =>
      match cursor {
        Object(m) => {
          let out : Map[String, Json] = Map([])
          for k, v in m {
            out[k] = v
          }
          out["shape"] = Json::string("default")
          Json::object(out)
        }
        _ => cursor
      }
  }
}

///|
fn ViewSession::state(self : ViewSession, state : Json) -> @effect.Deferred[Unit] {
  self.send(kind_state, @utf8.encode(js_stringify(state)))
}

///|
/// What the client asks of the source, after what it asked before (`#then`); unsent pointer moves of the same buttons
/// coalesce to the latest.
fn ViewSession::then_(self : ViewSession, f : async () -> Unit, move_? : Int? = None) -> Unit {
  if move_ is Some(buttons) {
    if self.pending_move is Some(pm) && pm.buttons == buttons {
      pm.run = f
      return
    }
    self.move_seq += 1
    let slot : PendingMove = { id: self.move_seq, buttons, run: f }
    self.pending_move = Some(slot)
    let before = self.inputs
    let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
    self.inputs = mine
    ignore(
      self.rt.fork_daemon("screen input", on_error=_ => ignore(mine.succeed(())), () => {
        before.wait() catch { _ => () }
        if self.pending_move is Some(cur) && cur.id == slot.id {
          self.pending_move = None
        }
        (slot.run)() catch {
          e => (self.said)("info", "screens", "input not posted", jobj([("screen", jstr(self.id)), ("error", jstr(message_of(e)))]))
        }
        ignore(mine.succeed(()))
      }),
    )
    return
  }
  self.pending_move = None
  let before = self.inputs
  let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.inputs = mine
  ignore(
    self.rt.fork_daemon("screen input", on_error=_ => ignore(mine.succeed(())), () => {
      before.wait() catch { _ => () }
      f() catch {
        e => (self.said)("info", "screens", "input not posted", jobj([("screen", jstr(self.id)), ("error", jstr(message_of(e)))]))
      }
      ignore(mine.succeed(()))
    }),
  )
}

///|
/// What a background fiber of the view let escape, said.
fn ViewSession::failed(self : ViewSession, what : String, e : Error) -> Unit {
  (self.said)("info", "screens", what, jobj([("screen", jstr(self.id)), ("error", jstr(message_of(e)))]))
}

///|
/// Ends the view once (`#stop`): its capture stops, its people are told. `reason` None: the stream broke, nothing is
/// written.
fn ViewSession::stop(self : ViewSession, reason : String?) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  (self.unclip)()
  (self.unlock)()
  (self.unlogin)()
  (self.unpasskey)()
  (self.unchild)()
  (self.unpoint)()
  (self.unturn)()
  (self.unwindows)()
  (self.view.close)()
  (self.leave)()
  (self.unwatch)()
  self.wake()
  guard reason is Some(r) else {
    ignore(self.over.succeed(()))
    return
  }
  let written = self.state(jobj([("ended", jstr(r))]))
  ignore(
    self.rt.fork_daemon("screen end", on_error=_ => ignore(self.over.succeed(())), () => {
      written.wait() catch { _ => () }
      self.writes.wait() catch { _ => () }
      (self.stream.finish)() catch { _ => () }
      ignore(self.over.succeed(()))
    }),
  )
}

///|
/// Another member made it only look (`#watchOnly`, `by`: who took it).
fn ViewSession::watch_only(self : ViewSession, by : String?) -> Unit {
  if self.closed || !self.control {
    return
  }
  self.control = false
  (self.unclip)()
  (self.unlock)()
  (self.unlogin)()
  (self.unpasskey)()
  (self.unchild)()
  let held : Array[Json] = []
  for _, e in self.keys {
    held.push(with_fields(e, [("kind", jstr("up"))]))
  }
  let at = self.pointer
  self.keys.clear()
  self.pointer = None
  if at is Some(p) && !(field(p, "buttons") is Some(Number(0.0, ..))) {
    held.push(with_fields(p, [("kind", jstr("up")), ("buttons", jnum(0.0))]))
  }
  for index in self.pads {
    held.push(pad_released_json(index))
  }
  self.pads.clear()
  for e in held {
    self.then_(() => (self.view.input)(e))
  }
  let patch = [("control", Json::boolean(false)), ("login", Json::null()), ("passkey", Json::null())]
  // (an app's hold on the pointer is a driver's: said gone, to a view that was told it)
  if self.view.watch_pointer_lock is Some(_) {
    patch.push(("pointerLock", Json::boolean(false)))
  }
  if by is Some(b) {
    patch.push(("takenBy", jstr(b)))
  }
  ignore(self.state(jobj(patch)))
}

///|
/// A controller let go of (source.ts `gamepadReleased`), as an input's JSON.
fn pad_released_json(index : Int) -> Json {
  parse_input(jobj([("t", jstr("gamepad")), ("index", jnum(index.to_double())), ("connected", Json::boolean(false))])).unwrap()
}

///|
/// `{...v, ...fields}`: each field where it was, a new one at the end.
fn with_fields(v : Json, fields : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  if v is Object(o) {
    for k, x in o {
      m[k] = x
    }
  }
  for f in fields {
    m[f.0] = f.1
  }
  Json::object(m)
}

///|
/// A frame went (`#still`): once the screen has been still for STILL_MS, the picture again sharper where the rate went
/// up since. `key`: the frame was a key frame.
fn ViewSession::still(self : ViewSession, key : Bool) -> Unit {
  let rate = match self.view.rate {
    Some(_) => Some(self.rate.unwrap_or(self.start_rate))
    None => None
  }
  self.sharpen.sent((self.now)(), rate, key~)
  if self.still_wait {
    return
  }
  self.still_wait = true
  self.still_after(still_ms)
}

///|
fn ViewSession::still_after(self : ViewSession, ms : Double) -> Unit {
  ignore(
    self.rt.fork_daemon("screen still", on_error=e => self.failed("sharpening a still screen failed", e), () => {
      @effect.sleep(ms.ceil().to_int())
      if self.closed {
        return
      }
      let left = self.sharpen.left((self.now)())
      if left > 0.0 {
        return self.still_after(left)
      }
      self.still_wait = false
      if self.sharpen.due((self.now)(), self.rate) {
        (self.view.keyframe)()
      }
    }),
  )
}

///|
/// What of the link was lost, said as it changes (`#watchLoss`): a share each LOSS_EVERY_MS, the same not said again,
/// sampled whether or not the client's acknowledgements come.
async fn ViewSession::watch_loss(self : ViewSession, paths : () -> Array[LinkPath]) -> Unit {
  while !self.closed {
    @effect.sleep(loss_every_ms) // timer: a sample of this machine (the connection's packet counters)
    if self.closed {
      return
    }
    if self.loss.step(paths()) is Some(loss) {
      ignore(self.state(jobj([("loss", jnum(loss))])))
    }
  }
}

///|
/// The source asked for the bit rate the link carries, and the size that makes sharpest (`#pace`).
fn ViewSession::pace(self : ViewSession) -> Unit {
  guard self.pacer.asked_rate() is Some(rate) && self.view.rate is Some(set_rate) else { return }
  match self.rate {
    Some(r) if (rate - r).abs() < r * 0.05 => ()
    _ => {
      self.rate = Some(rate)
      set_rate(js_round(rate))
    }
  }
  if self.size is Some((width, height)) && self.view.bounds is Some(_) {
    if self.sizer.step(rate, self.pacer.through_rate(), width, height) is Some(b) {
      self.bounds(b)
    }
  }
}

///|
fn ViewSession::bounds(self : ViewSession, b : Bounds) -> Unit {
  guard self.view.bounds is Some(set) else { return }
  set(b.max_width, b.max_height, self.region)
}

///|
/// The client looks at a part of the screen, or the whole again (`#look`).
fn ViewSession::look(self : ViewSession, region : Region?, b : Bounds) -> Unit {
  guard self.view.bounds is Some(_) && self.view.regions is Some(regions) && regions() else { return }
  if region == self.region && b == self.sizer.asked_bounds() {
    return
  }
  self.region = region
  self.bounds(self.sizer.ask(b))
}

///|
/// Waits for `wake` (or `ms`, where it is said).
async fn ViewSession::sleep_or_wake(self : ViewSession, ms : Int?) -> Unit {
  let w : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.wake_ = w
  if ms is Some(ms) {
    ignore(
      self.rt.fork_daemon("screen wait", on_error=_ => ignore(w.succeed(())), () => {
        @effect.sleep(ms)
        ignore(w.succeed(()))
      }),
    )
  }
  w.wait() catch { _ => () }
}

///|
/// Frames out, while the client keeps up (`#pump`).
async fn ViewSession::pump(self : ViewSession) -> Unit {
  while !self.closed {
    if !self.pacer.may() {
      self.pace()
      self.sleep_or_wake(None)
      continue
    }
    let wait = self.pacer.wait()
    if wait > 0.0 {
      self.sleep_or_wake(Some(wait.to_int()))
      continue
    }
    let next = (self.view.next)() catch {
      ScreenRefused(_, key, args, access) => {
        let message = match access_shown(access, self.lang, self.tr) {
          Some(s) => str_of(field(s, "message")).unwrap_or("")
          None => (self.tr)(self.lang, key, args)
        }
        self.stop(Some(message))
        return
      }
      e => {
        (self.said)("warn", "screens", "a screen's frame was not had", jobj([("screen", jstr(self.id)), ("error", jstr(message_of(e)))]))
        None
      }
    }
    if self.closed {
      return
    }
    guard next is Some(f) else {
      if !same_source((self.hub.get)(self.id), self.source) || self.source.kind != "desktop" {
        return self.stop(Some("gone"))
      }
      let why = self.view.why.map(w => w()).unwrap_or(None).unwrap_or("")
      (self.said)("warn", "screens", "a screen's capture ended", jobj([("screen", jstr(self.id)), ("why", jstr(why))]))
      let words = if why != "" { why } else { (self.tr)(self.lang, "station.screen.captureEndedUnsaid", jobj([])) }
      return self.stop(Some((self.tr)(self.lang, "station.screen.captureEnded", jobj([("said", jstr(words))]))))
    }
    if f.config is Some(c) {
      if c.codec != "jpeg" {
        self.pacer.set_ceiling(
          if self.peek {
            own_rate(c.width, c.height)
          } else {
            rate_ceiling(c.width, c.height, self.quality)
          },
        )
        self.size = Some((c.width, c.height))
      }
      ignore(self.send(kind_config, config_bytes(c)))
    }
    self.pacer.sent(f.ts, f.data.length().to_double())
    self.latency.sent(f.ts)
    self.send(kind_video, video_payload(f.key, f.ts, f.data)).wait() catch { _ => () }
    self.still(f.key)
    // (a screen that keeps changing: its pictures as sharp as the rate now once it went up well past its key frame's)
    if !self.closed && self.view.rate is Some(_) && self.sharpen.due_moving((self.now)(), self.rate) {
      (self.view.keyframe)()
    }
  }
}

///|
/// One audio packet in flight (`#audio`): left out before the first round trip, while muted, and (PCM's) while the
/// pictures wait in front of the link or after QUIET packets of silence.
async fn ViewSession::audio_loop(self : ViewSession, next_audio : async () -> AudioPacket?) -> Unit {
  let mut configured = false
  let mut zeros = 0
  let ended = (async fn() {
    while !self.closed {
      let next = next_audio()
      guard !self.closed && next is Some(p) else { break }
      if !configured {
        self
        .send(
          kind_audio_config,
          @utf8.encode(js_stringify(jobj([("codec", jstr(p.codec)), ("sampleRate", jnum(48000.0)), ("channels", jnum(2.0))]))),
        )
        .wait()
        configured = true
      }
      let pcm = p.codec == "pcm_s16le"
      zeros = if pcm && silent(p.data) { zeros + 1 } else { 0 }
      if !self.timed || !self.sound_on || (pcm && (self.pacer.backlogged() || zeros >= quiet)) {
        continue
      }
      let b = @buffer.Buffer(size_hint=8 + p.data.length())
      b.write_uint64_be(js_round(p.ts).to_uint64())
      b.write_bytes(p.data)
      self.send(kind_audio, b.to_bytes()).wait()
    }
  })() catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  if ended is Some(e) {
    (self.said)("info", "screens", "system audio ended", jobj([("error", jstr("Error: \{message_of(e)}"))]))
  }
}

///|
/// What the client says, until it finishes (`#read`).
async fn ViewSession::read(self : ViewSession) -> Unit {
  let failed = (async fn() {
    while true {
      let got = self.frames.next()
      if self.closed {
        return
      }
      guard got is Some((kind, payload)) else { return self.stop(Some("finished")) }
      self.take(kind, payload)
    }
  })() catch {
    _ => true
  } noraise {
    _ => false
  }
  if failed {
    self.stop(None)
  }
}

///|
/// One frame the client sent.
fn ViewSession::take(self : ViewSession, kind : Int, payload : Bytes) -> Unit {
  if kind == kind_ack {
    if payload.length() < 8 {
      return
    }
    let mut v = 0UL
    for i in 0..<8 {
      v = (v << 8) | payload[i].to_uint64()
    }
    let acked = v.to_double()
    self.pacer.acked(acked)
    if self.pacer.rtt() is Some(_) {
      self.timed = true
    }
    self.latency.acked(acked, self.pacer.rtt().unwrap_or(0.0))
    if self.latency.take() is Some((frame, before)) {
      ignore(self.state(jobj([("latency", jobj([("frame", jnum(frame)), ("before", jnum(before))]))])))
    }
    self.pace()
    self.wake()
  } else if kind == kind_keyframe {
    (self.view.keyframe)()
  } else if kind == kind_sound {
    if payload.length() == 1 {
      self.sound_on = payload[0] != b'\x00'
    }
  } else if kind == kind_look {
    if parse_look(payload, self.own) is Some((region, b)) {
      self.look(region, b)
    }
  } else if kind == kind_input {
    self.input(payload_json(payload).unwrap_or(Json::null()))
  } else if kind == kind_set_clipboard {
    guard self.control && self.view.set_clipboard is Some(set) else { return }
    guard parse_clip(payload) is Some((clip, paste)) else { return }
    let privacy = parse_clip_privacy(payload)
    let types = self.source.clipboard.map(f => f()).unwrap_or([])
    let t = match clip {
      Text(_) => "text"
      Png(_) => "png"
    }
    if !types.contains(t) {
      return
    }
    self.clip_known = Some(clip_payload(clip))
    // (with its mark where the view carries marks)
    match self.view.set_clipboard_marked {
      Some(marked) => self.then_(() => marked(clip, paste, privacy))
      None => self.then_(() => set(clip, paste))
    }
  }
}

///|
/// A client's input frame (`KIND.input`).
fn ViewSession::input(self : ViewSession, raw : Json) -> Unit {
  match parse_window_pick(raw) {
    NotOne => ()
    pick => {
      if self.view.window is Some(set) {
        let id = match pick {
          Window(n) => Some(n)
          _ => None
        }
        self.then_(async fn() { set(id) })
      }
      return
    }
  }
  if !self.control {
    return
  }
  if parse_scale(raw) is Some(percent) {
    if self.source.set_scale is Some(set) {
      self.then_(() => {
        let scale = set(percent) catch {
          e => {
            (self.said)(
              "info",
              "screens",
              "the display's scale was not set",
              jobj([("screen", jstr(self.id)), ("percent", jnum(percent)), ("error", jstr(message_of(e)))]),
            )
            return
          }
        }
        ignore(self.state(jobj([("scale", scale)])))
      })
    }
    return
  }
  if parse_resolution(raw) is Some((width, height)) {
    if self.source.set_resolution is Some(set) {
      self.then_(() => {
        let resolution = set(width, height) catch {
          e => {
            (self.said)(
              "info",
              "screens",
              "the display's resolution was not set",
              jobj([("screen", jstr(self.id)), ("width", jnum(width)), ("height", jnum(height)), ("error", jstr(message_of(e)))]),
            )
            return
          }
        }
        ignore(self.state(jobj([("resolution", resolution)])))
      })
    }
    return
  }
  if parse_reveal(raw) is Some(path) {
    if self.source.reveal && self.view.reveal is Some(reveal) {
      self.then_(() => reveal(path))
    }
    return
  }
  if parse_fill(raw) is Some(fill) {
    if self.control && self.view.fill is Some(f) {
      self.then_(() => f(fill))
    }
    return
  }
  if parse_passkey(raw) is Some(answer) {
    if self.control && self.view.passkey is Some(f) {
      self.then_(() => f(answer))
    }
    return
  }
  guard parse_input(raw) is Some(e) else { return }
  match (field(e, "t"), field(e, "kind")) {
    (Some(String("pointer")), _) => self.pointer = Some(e)
    (Some(String("gamepad")), _) => {
      let index = num_of(field(e, "index")).unwrap_or(0.0).to_int()
      match (self.pads.search(index), field(e, "connected")) {
        (None, Some(True)) => self.pads.push(index)
        (Some(i), Some(False)) => ignore(self.pads.remove(i))
        _ => ()
      }
    }
    (Some(String("key")), kind) => {
      let code = str_of(field(e, "code")).unwrap_or("")
      let which = if code != "" { code } else { str_of(field(e, "key")).unwrap_or("") }
      if kind is Some(String("down")) {
        self.keys[which] = e
      } else {
        self.keys.remove(which)
      }
    }
    _ => ()
  }
  // (relative moves add up, none coalesced away)
  let move_ = match (field(e, "t"), field(e, "kind"), field(e, "buttons")) {
    (Some(String("pointer")), Some(String("move")), Some(Number(b, ..))) if !(field(e, "relative") is Some(True)) =>
      Some(b.to_int())
    _ => None
  }
  self.then_(() => (self.view.input)(e), move_~)
}

///|
/// The view, from its first state to its end (`run`).
async fn ViewSession::run(self : ViewSession) -> Unit {
  let video = self.view.video.map(f => f()).unwrap_or(None)
  let first = [("title", jstr(self.title)), ("control", Json::boolean(self.control))]
  if self.site is Some(s) && s != "" {
    first.push(("site", jstr(s)))
  }
  if self.address is Some(a) {
    first.push(("address", jstr(a)))
  }
  if self.source.open_url {
    first.push(("openUrl", Json::boolean(true)))
  }
  if self.source.user_tab {
    first.push(("userTab", Json::boolean(true)))
  }
  if self.took.length() > 0 {
    first.push(("took", Json::array(self.took.map(jstr))))
  }
  if self.access is Some(a) {
    first.push(("access", a))
  }
  if video is Some(v) {
    first.push(("video", v))
  }
  ignore(self.state(jobj(first)))
  if !self.peek {
    self.leave = (self.hub.join)(self.id, {
      name: self.name,
      device: self.device,
      self_: self.self_,
      client: self.client,
      app: self.app,
      control: self.control,
      tell: people => ignore(self.state(people)),
      end: by => self.stop(Some((self.tr)(self.lang, "station.screen.endedBy", jobj([("by", jstr(by))])))),
      watch_only: by => self.watch_only(by),
    })
  }
  let unwatch = (self.hub.watch)(() => {
    if !same_source((self.hub.get)(self.id), self.source) {
      return self.stop(Some("gone"))
    }
    let title = (self.source.title)()
    let site = self.source.site.map(f => f()).unwrap_or(None)
    let address = address_shown(self.source.address.map(f => f()).unwrap_or(None))
    if title != self.title || site != self.site || address != self.address {
      let patch = []
      if title != self.title {
        self.title = title
        patch.push(("title", jstr(title)))
      }
      if site != self.site {
        self.site = site
        patch.push(("site", jstr(site.unwrap_or(""))))
      }
      if address != self.address {
        self.address = address
        patch.push(("address", jstr(address.unwrap_or(""))))
      }
      ignore(self.state(jobj(patch)))
    }
  })
  let unstop = (self.hub.when_stopping)(() => self.stop(Some("stopping")))
  self.unwatch = () => {
    unwatch()
    unstop()
  }
  let types = if self.control { self.source.clipboard.map(f => f()).unwrap_or([]) } else { [] }
  if types.length() > 0 && self.view.watch_clipboard is Some(watch) {
    let heard = (clip : Clip, privacy : Int) => {
      let t = match clip {
        Text(_) => "text"
        Png(_) => "png"
      }
      if self.closed || !types.contains(t) || !clip_fits(clip) {
        return
      }
      let payload = clip_payload(clip)
      if self.clip_known is Some(k) && k == payload {
        return
      }
      self.clip_known = Some(payload)
      // Marked private (a password manager's): with its mark to a client that reads it, else as any copy.
      if privacy >= 1 && privacy <= 3 && self.private_clip {
        ignore(self.send(kind_private_clipboard, private_clip_payload(clip, privacy)))
      } else {
        ignore(self.send(kind_clipboard, payload))
      }
    }
    self.unclip = match self.view.watch_clipboard_marked {
      Some(marked) => marked(heard)
      None => watch(clip => heard(clip, 0))
    }
  }
  // Whether an app on the screen holds the pointer (a game's), to a person who drives it.
  if self.control && self.view.watch_pointer_lock is Some(watch) {
    self.unlock = watch(locked => if !self.closed { ignore(self.state(jobj([("pointerLock", Json::boolean(locked))]))) })
  }
  let told = (k : String) => (v : Json) => if !self.closed { ignore(self.state(jobj([(k, v)]))) }
  if self.control && self.view.watch_login is Some(watch) {
    self.unlogin = watch(told("login"))
  }
  if self.control && self.view.watch_passkey is Some(watch) {
    self.unpasskey = watch(told("passkey"))
  }
  if self.control && self.view.watch_child is Some(watch) {
    self.unchild = watch(s => told("childScreen")(jstr(s)))
  }
  if self.view.watch_cursor is Some(watch) {
    self.unpoint = watch(cursor => if !self.closed {
      let cursor = self.cursor_shown(cursor)
      if self.binary_cursor {
        ignore(self.send(kind_cursor, cursor_payload(cursor)))
      } else {
        ignore(self.state(jobj([("cursor", cursor)])))
      }
    })
  }
  if self.view.watch_windows is Some(watch) {
    self.unwindows = watch(w => if !self.closed {
      ignore(
        self.state(
          jobj([("windows", field(w, "windows").unwrap_or(Json::null())), ("window", field(w, "window").unwrap_or(Json::null()))]),
        ),
      )
    })
  }
  if self.view.watch_turn is Some(watch) {
    self.unturn = watch(told("turn"))
  }
  if self.control && self.source.scale is Some(scale) {
    ignore(
      self.rt.fork_daemon("screen scale", on_error=_ => (), () => {
        let s = scale() catch { _ => return }
        if s is Some(v) && !(v is Null) && !self.closed {
          ignore(self.state(jobj([("scale", v)])))
        }
      }),
    )
  }
  if self.control && self.source.resolution is Some(resolution) {
    ignore(
      self.rt.fork_daemon("screen resolution", on_error=_ => (), () => {
        let r = resolution() catch { _ => return }
        if r is Some(v) && !(v is Null) && !self.closed {
          ignore(self.state(jobj([("resolution", v)])))
        }
      }),
    )
  }
  ignore(
    self.rt.fork_daemon("screen stopped", on_error=_ => self.stop(None), () => {
      ignore((self.stream.stopped)()) catch { _ => () }
      self.stop(None)
    }),
  )
  ignore(self.rt.fork_daemon("screen read", on_error=e => self.failed("reading a screen's viewer failed", e), () => self.read()))
  if self.audio && self.view.next_audio is Some(next_audio) {
    ignore(self.rt.fork_daemon("screen audio", on_error=e => self.failed("a screen's audio failed", e), () => self.audio_loop(next_audio)))
  }
  // (a preview's card shows no figures)
  if self.paths is Some(paths) && !self.peek {
    ignore(self.rt.fork_daemon("screen loss", on_error=e => self.failed("watching a screen's loss failed", e), () => self.watch_loss(paths)))
  }
  self.pump()
  self.over.wait()
}
