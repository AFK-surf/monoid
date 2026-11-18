// What a person can see and drive on this station (src/screens/source.ts): the machine's display, a simulator, a
// device on adb, a tab of the station's browser. A source opens views; a view is pull-driven (`next` gives a frame only
// when asked), so a slow link lowers the frame rate instead of queueing frames. The mesh layer carries views
// (`/admin/api/screens`); sources know nothing of it.

///|
#derive(Eq)
pub(all) enum Codec {
  H265
  H264
  Jpeg
}

///|
pub fn Codec::name(self : Codec) -> String {
  match self {
    H265 => "h265"
    H264 => "h264"
    Jpeg => "jpeg"
  }
}

///|
pub fn codec_of(s : String) -> Codec? {
  match s {
    "h265" => Some(H265)
    "h264" => Some(H264)
    "jpeg" => Some(Jpeg)
    _ => None
  }
}

/// A part of the screen, 0..1 of its width and height: its left, its top, its width, its height.
#derive(Eq)
pub(all) struct Region {
  x : Double
  y : Double
  w : Double
  h : Double
}

///|
pub fn Region::to_j(self : Region) -> J {
  jo([("x", jn(self.x)), ("y", jn(self.y)), ("w", jn(self.w)), ("h", jn(self.h))])
}

/// `description`: H.264's avcC, H.265's hvcC. `region`: the part of the screen the frames after it show; none: the whole.
pub(all) struct FrameConfig {
  codec : Codec
  width : Double
  height : Double
  description : Bytes?
  region : Region?
}

///|
pub fn FrameConfig::to_j(self : FrameConfig) -> J {
  jsome([
    ("codec", Some(js(self.codec.name()))),
    ("width", Some(jn(self.width))),
    ("height", Some(jn(self.height))),
    ("description", self.description.map(d => js(b64(d)))),
    ("region", self.region.map(r => r.to_j())),
  ])
}

///|
/// One encoded frame: H.264 or H.265 as length-prefixed NAL units (AVCC, HVCC), or a whole JPEG. `ts`: microseconds,
/// rising.
pub(all) struct Frame {
  config : FrameConfig?
  key : Bool
  ts : Double
  data : Bytes
}

///|
pub fn Frame::to_j(self : Frame) -> J {
  jsome([
    ("config", self.config.map(c => c.to_j())),
    ("key", Some(jb(self.key))),
    ("ts", Some(jn(self.ts))),
    ("data", Some(js(b64(self.data)))),
  ])
}

///|
/// A 20 ms packet of system output: 3840 bytes of interleaved stereo PCM16, or one Opus packet of those 960 frames.
pub(all) struct AudioFrame {
  ts : Double
  data : Bytes
  codec : String
}

///|
pub fn AudioFrame::to_j(self : AudioFrame) -> J {
  jo([("ts", jn(self.ts)), ("data", js(b64(self.data))), ("codec", js(self.codec))])
}

///|
/// The longest Opus packet (RFC 6716 3.2.1).
pub const OPUS_MAX : Int = 1275

///|
/// A person's input; coordinates are 0..1 of the screen. `mods`: bit 0 alt, 1 ctrl, 2 meta, 3 shift (CDP's order).
pub(all) enum ScreenInput {
  Pointer(kind~ : String, x~ : Double, y~ : Double, buttons~ : Int)
  Wheel(x~ : Double, y~ : Double, dx~ : Double, dy~ : Double)
  Key(kind~ : String, key~ : String, code~ : String, mods~ : Int)
  Text(String)
  /// A foldable simulator's hinge (`ScreenSource.poses`): "closed", "book", "open".
  Pose(String)
  /// What Device Hub does of a device besides its keys and a finger: "volume_up", "volume_down", "memory_warning",
  /// "rotate".
  Device(String)
  /// A button of a simulator's device, held as long as it is here (its HID usage).
  Button(page~ : Int, usage~ : Int, down~ : Bool)
}

///|
/// A number as JavaScript's bit operators take it (ToInt32).
fn to_int32(d : Double) -> Int {
  if d.is_nan() || d.is_inf() {
    return 0
  }
  let t = js_trunc(d)
  let m = t - (t / 4294967296.0).floor() * 4294967296.0
  m.to_int64().to_int()
}

///|
/// A person's input as the view's wire has it (checked there before it comes here).
pub fn input_of(j : J) -> ScreenInput? {
  let s = (k : String) => text(get(Some(j), k)).unwrap_or("")
  let n = (k : String) => num(get(Some(j), k)).unwrap_or(0.0)
  match text(get(Some(j), "t")) {
    Some("pointer") => Some(Pointer(kind=s("kind"), x=n("x"), y=n("y"), buttons=to_int32(n("buttons"))))
    Some("wheel") => Some(Wheel(x=n("x"), y=n("y"), dx=n("dx"), dy=n("dy")))
    Some("key") => Some(Key(kind=s("kind"), key=s("key"), code=s("code"), mods=to_int32(n("mods"))))
    Some("text") => Some(Text(s("text")))
    Some("pose") => Some(Pose(s("name")))
    Some("device") => Some(Device(s("name")))
    Some("button") => Some(Button(page=to_int32(n("page")), usage=to_int32(n("usage")), down=get(Some(j), "down") is Some(Bool(true))))
    _ => None
  }
}

///|
pub fn ScreenInput::to_j(self : ScreenInput) -> J {
  match self {
    Pointer(kind~, x~, y~, buttons~) => jo([("t", js("pointer")), ("kind", js(kind)), ("x", jn(x)), ("y", jn(y)), ("buttons", ji(buttons))])
    Wheel(x~, y~, dx~, dy~) => jo([("t", js("wheel")), ("x", jn(x)), ("y", jn(y)), ("dx", jn(dx)), ("dy", jn(dy))])
    Key(kind~, key~, code~, mods~) => jo([("t", js("key")), ("kind", js(kind)), ("key", js(key)), ("code", js(code)), ("mods", ji(mods))])
    Text(t) => jo([("t", js("text")), ("text", js(t))])
    Pose(name) => jo([("t", js("pose")), ("name", js(name))])
    Device(name) => jo([("t", js("device")), ("name", js(name))])
    Button(page~, usage~, down~) => jo([("t", js("button")), ("page", ji(page)), ("usage", ji(usage)), ("down", jb(down))])
  }
}

///|
/// The viewer's own screen (a phone), in its CSS pixels and their scale.
pub(all) struct ViewFit {
  width : Double
  height : Double
  scale : Double
}

///|
/// What a view asks of a source: its bounds, the codecs it takes, a preview's (`peek`), what to encode at first, the
/// most frames a second, its own screen, sound (and Opus), Display P3 (source.ts `ViewOptions`).
pub(all) struct ViewOptions {
  max_width : Double
  max_height : Double
  codecs : Array[Codec]
  peek : Bool
  bitrate : Double?
  fps : Double?
  fit : ViewFit?
  audio : Bool
  opus : Bool
  gamut : String?
}

///|
pub fn ViewOptions::new(
  max_width : Double,
  max_height : Double,
  codecs : Array[Codec],
  peek? : Bool = false,
  bitrate? : Double? = None,
  fps? : Double? = None,
  audio? : Bool = false,
  opus? : Bool = false,
  gamut? : String? = None,
) -> ViewOptions {
  { max_width, max_height, codecs, peek, bitrate, fps, fit: None, audio, opus, gamut }
}

///|
pub fn view_options_of(j : J) -> ViewOptions {
  let fit = match get(Some(j), "fit") {
    Some(Obj(_) as f) =>
      Some({ width: num(get(Some(f), "width")).unwrap_or(0.0), height: num(get(Some(f), "height")).unwrap_or(0.0), scale: num(get(Some(f), "scale")).unwrap_or(1.0) })
    _ => None
  }
  // (a falsy number is as none: `options.bitrate ? …`, `options.fps ? …`)
  let truthy = (k : String) => match num(get(Some(j), k)) {
    Some(d) if d != 0.0 && !d.is_nan() => Some(d)
    _ => None
  }
  {
    max_width: num(get(Some(j), "maxWidth")).unwrap_or(0.0),
    max_height: num(get(Some(j), "maxHeight")).unwrap_or(0.0),
    codecs: arr(get(Some(j), "codecs")).unwrap_or([]).filter_map(c => text(Some(c)).bind(codec_of)),
    peek: get(Some(j), "peek") is Some(Bool(true)),
    bitrate: truthy("bitrate"),
    fps: truthy("fps"),
    fit,
    audio: get(Some(j), "audio") is Some(Bool(true)),
    opus: get(Some(j), "opus") is Some(Bool(true)),
    gamut: text(get(Some(j), "gamut")),
  }
}

///|
/// The codec a source that makes `own` (best first) sends a view: the first of them the view takes; for a preview,
/// JPEG where both have it. None: nothing in common.
pub fn codec_for(options : ViewOptions, own : Array[Codec]) -> Codec? {
  if options.peek && own.contains(Jpeg) && options.codecs.contains(Jpeg) {
    return Some(Jpeg)
  }
  for c in own {
    if options.codecs.contains(c) {
      return Some(c)
    }
  }
  None
}

///|
/// The least part of the screen a look shows, of its width or height (a 50th: zoomed in 50 times).
pub const LOOK_LEAST : Double = 0.02

///|
/// A part this much of the screen or more, both ways, is the whole of it.
const LOOK_WHOLE : Double = 0.98

///|
fn js_min(a : Double, b : Double) -> Double {
  if a.is_nan() || b.is_nan() {
    @double.not_a_number
  } else if a < b {
    a
  } else {
    b
  }
}

///|
fn js_max(a : Double, b : Double) -> Double {
  if a.is_nan() || b.is_nan() {
    @double.not_a_number
  } else if a > b {
    a
  } else {
    b
  }
}

///|
/// A part of the screen as a look or a source says it, checked: within the screen, at least LOOK_LEAST each way; none
/// when it is not one, or is (about) the whole screen.
pub fn region_of(v : J?) -> Region? {
  let n = (k : String) => match get(v, k) {
    Some(Num(d)) if d.is_finite() => Some(d)
    _ => None
  }
  guard (n("x"), n("y"), n("w"), n("h")) is (Some(vx), Some(vy), Some(vw), Some(vh)) else { return None }
  let w = js_min(1.0, js_max(LOOK_LEAST, vw))
  let h = js_min(1.0, js_max(LOOK_LEAST, vh))
  if w >= LOOK_WHOLE && h >= LOOK_WHOLE {
    return None
  }
  let x = js_min(1.0 - w, js_max(0.0, vx))
  let y = js_min(1.0 - h, js_max(0.0, vy))
  let r4 = (n : Double) => js_round(n * 10000.0) / 10000.0
  Some({ x: r4(x), y: r4(y), w: r4(w), h: r4(h) })
}

///|
/// What a screen's clipboard holds, as a view carries it: text, or a PNG picture.
pub(all) enum Clip {
  ClipText(String)
  ClipPng(Bytes)
}

///|
pub fn Clip::type_name(self : Clip) -> String {
  match self {
    ClipText(_) => "text"
    ClipPng(_) => "png"
  }
}

///|
pub fn Clip::to_j(self : Clip) -> J {
  match self {
    ClipText(t) => jo([("type", js("text")), ("text", js(t))])
    ClipPng(d) => jo([("type", js("png")), ("data", js(b64(d)))])
  }
}

///|
pub fn clip_of(j : J) -> Clip? {
  match text(get(Some(j), "type")) {
    Some("text") => Some(ClipText(text(get(Some(j), "text")).unwrap_or("")))
    Some("png") => Some(ClipPng(@base64.decode_lossy(text(get(Some(j), "data")).unwrap_or(""))))
    _ => None
  }
}

///|
/// The most a clipboard carries each way: text (its UTF-8 bytes), a picture.
pub const CLIP_TEXT_MAX : Int = 1048576

///|
pub const CLIP_PNG_MAX : Int = 8388608

///|
/// Whether a clip is within its bounds.
pub fn clip_fits(clip : Clip) -> Bool {
  match clip {
    ClipText(t) => t != "" && @utf8.encode(t).length() <= CLIP_TEXT_MAX
    ClipPng(d) => d.length() > 0 && d.length() <= CLIP_PNG_MAX
  }
}

///|
/// A login field in focus: the site's host, which field ("username", "password"), and whether it already holds a value.
pub(all) struct LoginField {
  host : String
  field : String
  filled : Bool
}

///|
/// A login form filled from a person's app.
pub(all) struct LoginFill {
  host : String
  username : String?
  password : String?
}

///|
/// A page's ask to sign in with a passkey.
pub(all) struct PasskeyAsk {
  id : String
  host : String
  rp_id : String
  client_data : String
  allow : Array[String]
  user_verification : String
}

///|
/// What a person's app answers an ask with (as it came: base64url fields, or `error`).
pub(all) struct PasskeyAnswer {
  id : String
  fields : J
}

///|
/// How a view's pictures are made, as its statistics show it: what captures them, the encoder's name as it says it,
/// and whether it is the hardware's.
#derive(Eq)
pub(all) struct ScreenVideo {
  capture : String
  encoder : String?
  hardware : Bool?
}

///|
pub fn ScreenVideo::to_j(self : ScreenVideo) -> J {
  jsome([("capture", Some(js(self.capture))), ("encoder", self.encoder.map(js)), ("hardware", self.hardware.map(jb))])
}

/// Where a screen's pointer is, 0..1 of the screen, and its shape as CSS names it.
#derive(Eq)
pub(all) struct ScreenCursor {
  x : Double
  y : Double
  shape : String
}

///|
pub fn ScreenCursor::to_j(self : ScreenCursor) -> J {
  jo([("x", jn(self.x)), ("y", jn(self.y)), ("shape", js(self.shape))])
}

/// An app's window on a desktop, as a view may show it alone: its id (the system's), its app's name and its title.
#derive(Eq)
pub(all) struct ScreenWindow {
  id : Double
  app : String
  title : String
}

/// A desktop's windows as its view says them, and the one it shows alone (none: the whole display).
#derive(Eq)
pub(all) struct ScreenWindows {
  windows : Array[ScreenWindow]
  window : Double?
}

///|
pub fn ScreenWindows::to_j(self : ScreenWindows) -> J {
  jo([
    ("windows", ja(self.windows.map(w => jo([("id", jn(w.id)), ("app", js(w.app)), ("title", js(w.title))])))),
    (
      "window",
      match self.window {
        Some(w) => jn(w)
        None => Null
      },
    ),
  ])
}

///|
/// The most windows said (the rest left out), and the longest app's name or title (cut there).
pub const WINDOWS_MOST : Int = 60

///|
pub const WINDOW_WORDS_MOST : Int = 200

///|
/// A desktop's windows as a helper said them, checked: at most WINDOWS_MOST, each with a whole id, words cut.
pub fn windows_of(v : J?) -> Array[ScreenWindow] {
  guard v is Some(Arr(xs)) else { return [] }
  let out = []
  for w in xs {
    if out.length() >= WINDOWS_MOST {
      break
    }
    guard w is Obj(_) else { continue }
    guard get(Some(w), "id") is Some(Num(id)) && is_integer(id) && id > 0.0 else { continue }
    let cut = (k : String) => match get(Some(w), k) {
      Some(Str(_) as s) => slice_units(text(Some(s)).unwrap_or(""), 0, WINDOW_WORDS_MOST)
      _ => ""
    }
    out.push({ id, app: cut("app"), title: cut("title") })
  }
  out
}

/// steps it takes, in percent.
#derive(Eq)
pub(all) struct ScreenScale {
  percent : Double
  recommended : Double
  steps : Array[Double]
}

///|
pub fn ScreenScale::to_j(self : ScreenScale) -> J {
  jo([("percent", jn(self.percent)), ("recommended", jn(self.recommended)), ("steps", ja(self.steps.map(jn)))])
}

/// A display's resolution as its system has it: now, and the modes it takes, in pixels.
#derive(Eq)
pub(all) struct ScreenResolution {
  width : Double
  height : Double
  modes : Array[(Double, Double)]
}

///|
pub fn ScreenResolution::to_j(self : ScreenResolution) -> J {
  jo([
    ("width", jn(self.width)),
    ("height", jn(self.height)),
    ("modes", ja(self.modes.map(m => jo([("width", jn(m.0)), ("height", jn(m.1))])))),
  ])
}

/// Settings for it; `asking`, a window on the machine asks for it now.
#derive(Eq)
pub(all) struct ScreenAccess {
  capture : Bool
  control : Bool
  unsupported : String?
  reason : String?
  app : String?
  path : String?
  asking : Bool
}

///|
pub fn ScreenAccess::new(
  capture : Bool,
  control : Bool,
  unsupported? : String? = None,
  reason? : String? = None,
  app? : String? = None,
  path? : String? = None,
  asking? : Bool = false,
) -> ScreenAccess {
  { capture, control, unsupported, reason, app, path, asking }
}

///|
pub fn ScreenAccess::to_j(self : ScreenAccess) -> J {
  jsome([
    ("capture", Some(jb(self.capture))),
    ("control", Some(jb(self.control))),
    ("unsupported", self.unsupported.map(js)),
    ("reason", self.reason.map(js)),
    ("app", self.app.map(js)),
    ("path", self.path.map(js)),
    ("asking", if self.asking { Some(jb(true)) } else { None }),
  ])
}

/// One view of a source (source.ts `ScreenView`): what every view has, and what some have (none where it has not).
pub(all) struct ScreenView {
  /// The next frame once there is a new one, or none when the view ended (the source went away).
  next : async () -> Frame?
  /// Negotiated system output, one bounded packet; none when unavailable.
  next_audio : (async () -> AudioFrame?)?
  /// Starts the next frame as a key frame (a client's decoder lost its state).
  keyframe : () -> Unit
  input : async (ScreenInput) -> Unit
  /// Encodes from the next frame at about this many bits a second.
  rate : ((Double) -> Unit)?
  /// Its pictures from now on fitted into these bounds (of `region` of the screen where it frames parts).
  bounds : ((Double, Double, Region?) -> Unit)?
  /// It frames a part of the screen when `bounds` says one.
  regions : (() -> Bool)?
  /// How its pictures are made (once it opened).
  video : (() -> ScreenVideo)?
  /// Why it ended by itself while its source stays (its capture's own words, once `next` gave none).
  why : (() -> String?)?
  /// Stops capturing; a pending `next` resolves none.
  close : () -> Unit
  set_clipboard : (async (Clip, Bool) -> Unit)?
  watch_clipboard : (((Clip) -> Unit) -> (() -> Unit))?
  watch_cursor : (((ScreenCursor) -> Unit) -> (() -> Unit))?
  watch_turn : (((Int) -> Unit) -> (() -> Unit))?
  watch_windows : (((ScreenWindows) -> Unit) -> (() -> Unit))?
  window : ((Double?) -> Unit)?
  reveal : (async (String) -> Unit)?
  watch_login : (((LoginField?) -> Unit) -> (() -> Unit))?
  fill : (async (LoginFill) -> Unit)?
  watch_passkey : (((PasskeyAsk?) -> Unit) -> (() -> Unit))?
  passkey : (async (PasskeyAnswer) -> Unit)?
  watch_child : (((String) -> Unit) -> (() -> Unit))?
}

///|
/// A view with what every view has, and none of the rest.
pub fn ScreenView::bare(
  next : async () -> Frame?,
  keyframe : () -> Unit,
  input : async (ScreenInput) -> Unit,
  close : () -> Unit,
) -> ScreenView {
  {
    next,
    next_audio: None,
    keyframe,
    input,
    rate: None,
    bounds: None,
    regions: None,
    video: None,
    why: None,
    close,
    set_clipboard: None,
    watch_clipboard: None,
    watch_cursor: None,
    watch_turn: None,
    watch_windows: None,
    window: None,
    reveal: None,
    watch_login: None,
    fill: None,
    watch_passkey: None,
    passkey: None,
    watch_child: None,
  }
}

///|
#derive(Eq)
pub(all) enum ScreenKind {
  DesktopKind
  BrowserKind
  SimulatorKind
}

///|
pub fn ScreenKind::name(self : ScreenKind) -> String {
  match self {
    DesktopKind => "desktop"
    BrowserKind => "browser"
    SimulatorKind => "simulator"
  }
}

///|
/// The key an app makes for a person's tab of the station's browser it opens (`browser:<key>`): `u_` and 12 hex digits.
pub fn is_user_tab_id(s : String) -> Bool {
  guard s.has_prefix("u_") && s.length() == 14 else { return false }
  for i in 2..<14 {
    let c = s.unsafe_get(i).to_int()
    if !((c >= '0'.to_int() && c <= '9'.to_int()) || (c >= 'a'.to_int() && c <= 'f'.to_int())) {
      return false
    }
  }
  true
}

///|
/// A source of screens (source.ts `ScreenSource`): what every one has, and what some have (none where it has not).
pub(all) struct ScreenSource {
  /// Stable while the source lasts: `desktop`, `browser:<targetId>`, `simulator:<udid>`, `android:<id>`.
  id : String
  kind : ScreenKind
  title : () -> String
  /// Its size now, in the source's pixels.
  size : () -> (Double, Double)
  /// Fails (with a message for the person) when it cannot be seen now.
  open : async (ViewOptions) -> ScreenView
  access : (() -> ScreenAccess)?
  clipboard : (() -> Array[String])?
  reveal : Bool
  peek : Bool
  farview : Bool
  opened_by : (() -> String?)?
  user_tab : Bool
  sleeping : (() -> Bool)?
  site : (() -> String?)?
  address : (() -> String)?
  open_url : (async (String) -> Unit)?
  reload : (async () -> Unit)?
  back : (async () -> Unit)?
  forward : (async () -> Unit)?
  sleep : (async () -> Unit)?
  discard : (async () -> Unit)?
  since : (() -> Double?)?
  scale : (async () -> ScreenScale?)?
  set_scale : (async (Double) -> ScreenScale)?
  resolution : (async () -> ScreenResolution?)?
  set_resolution : (async (Double, Double) -> ScreenResolution)?
  ui : (async (Array[String]) -> J)?
  debug : SimDebug?
  poses : Bool
  chrome : Array[ChromeSource]?
  panels : Array[Panel]?
}

///|
/// A source with what every one has, and none of the rest.
pub fn ScreenSource::bare(
  id : String,
  kind : ScreenKind,
  title : () -> String,
  size : () -> (Double, Double),
  open : async (ViewOptions) -> ScreenView,
) -> ScreenSource {
  {
    id,
    kind,
    title,
    size,
    open,
    access: None,
    clipboard: None,
    reveal: false,
    peek: false,
    farview: false,
    opened_by: None,
    user_tab: false,
    sleeping: None,
    site: None,
    address: None,
    open_url: None,
    reload: None,
    back: None,
    forward: None,
    sleep: None,
    discard: None,
    since: None,
    scale: None,
    set_scale: None,
    resolution: None,
    set_resolution: None,
    ui: None,
    debug: None,
    poses: false,
    chrome: None,
    panels: None,
  }
}

///|
/// The station's browser as `ScreenHub` reaches it.
pub(all) struct ScreenBrowser {
  available : () -> Bool
  open_user_tab : async (String, String?) -> String
}

///|
/// The station's sources (source.ts `makeScreens`): parts add theirs and take them away; told to who watches, with the
/// list each time a source comes or goes (or its title changes).
pub struct Screens {
  priv sources : Map[String, ScreenSource]
  priv listeners : Array[(Int, (Array[ScreenSource]) -> Unit)]
  priv mut next : Int
}

///|
pub fn Screens::new() -> Screens {
  { sources: {}, listeners: [], next: 0 }
}

///|
pub fn Screens::changed(self : Screens) -> Unit {
  let all = self.sources.values().collect()
  for l in self.listeners.copy() {
    (l.1)(all)
  }
}

///|
pub fn Screens::add(self : Screens, source : ScreenSource) -> () -> Unit {
  self.sources[source.id] = source
  self.changed()
  () => match self.sources.get(source.id) {
    Some(s) if physical_equal(s, source) => {
      self.sources.remove(source.id)
      self.changed()
    }
    _ => ()
  }
}

///|
pub fn Screens::list(self : Screens) -> Array[ScreenSource] {
  self.sources.values().collect()
}

///|
pub fn Screens::get(self : Screens, id : String) -> ScreenSource? {
  self.sources.get(id)
}

///|
pub fn Screens::watch(self : Screens, listener : (Array[ScreenSource]) -> Unit) -> () -> Unit {
  self.next += 1
  let id = self.next
  self.listeners.push((id, listener))
  () => match self.listeners.search_by(l => l.0 == id) {
    Some(i) => ignore(self.listeners.remove(i))
    None => ()
  }
}
