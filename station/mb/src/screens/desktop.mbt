// This machine's display as a screen source (`desktop`; src/screens/desktop.ts): on macOS, still.fail Helper
// captures the main display with ScreenCaptureKit, encodes H.264 with VideoToolbox (or a JPEG a picture, for a view
// that takes no H.264) and posts input with CGEvent, a view a connection to it. Windows' is win_desktop.mbt (its views
// are this file's HelperView too); Linux's are x11_desktop.mbt and linux_portal.mbt.
//
// macOS grants Screen Recording and Accessibility to the helper app. Opening the desktop while one is missing puts the
// helper's window up on this Mac (once an attempt): a row per grant, Allow opens System Settings with the app to drag
// into its list. The helper starts itself again once a grant is taken; the station's process is never restarted for
// it. What is missing, and whether the window is up, is told with the screens (`access`).
//
// A view a person drives carries the Mac's clipboard both ways (text, PNG): the helper sets NSPasteboard and pastes
// with ⌘V, and, while the view watches it, says what was copied.
//
// A person who drives it sets the display's resolution (the helper's `resolution`: Resolution.swift, its sizes in
// points, HiDPI kept on a Retina display), for this login session alone; once the last view ends, or the station
// stops, the mode it was in before the first change is put back. A helper from before it has no resolution to give:
// none is told, and nothing is set.

///|
/// The helper's window's words, in `lang` (Permissions.swift; PermissionFlow's panel under `panel`).
pub fn window_words(io : Io, lang : String) -> J {
  let w = (key : String, args : J) => js(io.tr(lang, "station.helper.window.\{key}", args~))
  let none = jo([])
  jo([
    ("title", w("title", none)),
    ("subtitle", w("subtitle", none)),
    ("capture", w("capture", none)),
    ("captureWhy", w("captureWhy", none)),
    ("control", w("control", none)),
    ("controlWhy", w("controlWhy", none)),
    ("allow", w("allow", none)),
    ("done", w("done", none)),
    (
      "panel",
      jo([
        // String(format:) positions: the app, then the grant.
        ("permission_flow.panel.title", w("drag", jo([("app", js("%1$@")), ("grant", js("%2$@"))]))),
        ("permission_flow.panel.step", w("step", jo([("n", js("%d"))]))),
        ("permission_flow.drag.label", w("dragLabel", none)),
        ("permission_flow.pane.screen_recording", w("capture", none)),
        ("permission_flow.pane.accessibility", w("control", none)),
        ("permission_flow.pane.permission", w("grant", none)),
        ("permission_flow.app.this_app", js("still.fail Helper")),
      ]),
    ),
  ])
}

///|
/// The helper's messages' kinds, to it (native/helper's ScreenView.swift): 1 next, 2 keyframe, 3 input, 4 clipboard
/// (flags: bit 0 paste; type: 1 text, 2 PNG; the bytes), 5 watch the clipboard (1 on, 0 off), 6 reveal (the path), 7
/// rate (bits a second, 4 bytes), 8 bounds (JSON {maxWidth, maxHeight, region?}), 9 audio (the next 20 ms packet), 10
/// window (JSON {window}). From it: 1 info, 2 config, 3 frame, 4 event, 5 clipboard (type, bytes), 6 cursor (JSON
/// {x, y, shape}), 7 region (JSON {region}), 8 audio config (JSON {codec, sampleRate, channels}, or {error}), 9 audio
/// (8 bytes timestamp µs, then the packet), 10 turn (JSON {turn}), 11 cursor image (a pointer of an app's own, before
/// the first 6 that names it "custom:<id>": source.mbt `cursor_image_shape`).
pub const TO_NEXT : Int = 1

///|
pub const TO_KEYFRAME : Int = 2

///|
pub const TO_INPUT : Int = 3

///|
pub const TO_CLIPBOARD : Int = 4

///|
pub const TO_WATCH : Int = 5

///|
pub const TO_REVEAL : Int = 6

///|
pub const TO_RATE : Int = 7

///|
pub const TO_BOUNDS : Int = 8

///|
pub const TO_AUDIO : Int = 9

///|
pub const TO_WINDOW : Int = 10

///|
/// Watch the virtual microphone (1 on, 0 off), and a packet for it (flags, the recording's epoch, 48 kHz mono s16le).
pub const TO_WATCH_MIC : Int = 11

///|
pub const TO_MIC : Int = 12

///|
fn clip_byte(clip : Clip) -> Byte {
  match clip {
    ClipText(_) => b'\x01'
    ClipPng(_) => b'\x02'
  }
}

///|
/// A clip as the helper's `clipboard` message has it: from the helper (`flags` none) or to it.
pub fn helper_clip(clip : Clip, flags? : Int? = None) -> Bytes {
  let body = match clip {
    ClipText(t) => @utf8.encode(t)
    ClipPng(d) => d
  }
  let head = match flags {
    None => Bytes::from_array([clip_byte(clip)])
    Some(f) => Bytes::from_array([f.to_byte(), clip_byte(clip)])
  }
  concat([head, body])
}

///|
/// A message to the helper: a kind byte, the payload's length (4 bytes), the payload.
pub fn helper_message(kind : Int, payload? : BytesView = b"") -> Bytes {
  let head = FixedArray::make(5, b'\x00')
  head[0] = kind.to_byte()
  put_u32be(head, 1, payload.length().to_int64())
  concat([Bytes::from_array(head), payload])
}

///|
/// What carries a view's messages to and from the helper: its socket (macOS), or a process's pipes (Windows'
/// stillfail-screen, win_desktop.mbt `child_pipe`).
pub(all) struct HelperPipe {
  write : (Bytes) -> Unit
  destroy : () -> Unit
  on_data : ((Bytes) -> Unit) -> Unit
  on_error : (() -> Unit) -> Unit
  on_close : (() -> Unit) -> Unit
}

///|
/// A connection to the helper as a view's pipe.
pub fn sock_pipe(s : Sock) -> HelperPipe {
  {
    write: b => s.write(b),
    destroy: () => s.destroy(),
    on_data: f => ignore(s.on_data(f)),
    on_error: f => ignore(s.on_error(_ => f())),
    on_close: f => ignore(s.on_close(f)),
  }
}

///|
/// One view: a connection to the helper, asked for each frame (desktop.ts `HelperView`).
pub struct HelperView {
  priv io : Io
  /// Its info had (the size it opens at), or why not.
  ready : @effect.Deferred[J]
  priv socket : HelperPipe
  priv input_ops : InputOps
  priv carry : Carry
  priv waiting : Array[(Frame?) -> Unit]
  priv mut config : FrameConfig?
  priv mut audio : Bool
  priv mut audio_codec : String
  priv mut audio_wait : ((AudioFrame?) -> Unit)?
  priv mut last_config : FrameConfig?
  priv mut region : Region?
  priv mut sent_region : Region?
  priv mut regions_ : Bool
  priv mut ended : Bool
  /// Its connection ended or broke: nothing more reaches the helper.
  priv mut cut : Bool
  priv gone : () -> Unit
  /// Who hears the clipboard, with the mark the helper said (message 12; 0 none).
  priv mut clipboard : (Int, (Clip, Int) -> Unit)?
  /// Who hears whether an app holds the pointer, and the last it said (message 4 `{pointerLock}`).
  priv mut pointer_lock : (Int, (Bool) -> Unit)?
  priv mut last_pointer_lock : Bool
  /// Who hears the virtual microphone while it is watched, the last the helper said of it, and whether its helper has
  /// one to watch (a desktop's, not a simulator's).
  priv mut mic_heard : (Int, (ScreenMic) -> Unit)?
  priv mut last_mic : ScreenMic?
  priv mic : Bool
  priv mut cursor : (Int, (ScreenCursor) -> Unit)?
  priv mut last_cursor : ScreenCursor?
  /// The pictures of the pointers of apps' own it said (message 11), by shape.
  priv cursor_images : Map[String, Bytes]
  priv mut turn : (Int, (Int) -> Unit)?
  priv mut last_turn : Int?
  priv mut windows : ScreenWindows?
  priv mut heard_windows : (Int, (ScreenWindows) -> Unit)?
  priv mut codec : Codec
  priv capture : String
  priv mut encoder : String
  priv mut next_id : Int
}

///|
pub fn HelperView::new(
  io : Io,
  codec : Codec,
  socket : HelperPipe,
  gone : () -> Unit,
  input? : InputOps? = None,
  capture? : String = "ScreenCaptureKit",
  audio? : Bool = false,
  mic? : Bool = false,
) -> HelperView {
  let v = {
    io,
    ready: @effect.Deferred::new(),
    socket,
    input_ops: input.unwrap_or(MacInput::new().input_ops()),
    carry: Carry::new(),
    waiting: [],
    config: None,
    audio,
    audio_codec: "pcm_s16le",
    audio_wait: None,
    last_config: None,
    region: None,
    sent_region: None,
    regions_: false,
    ended: false,
    cut: false,
    gone,
    clipboard: None,
    pointer_lock: None,
    last_pointer_lock: false,
    mic_heard: None,
    last_mic: None,
    mic,
    cursor: None,
    last_cursor: None,
    cursor_images: {},
    turn: None,
    last_turn: None,
    windows: None,
    heard_windows: None,
    codec,
    capture,
    encoder: "",
    next_id: 0,
  }
  (socket.on_data)(chunk => v.heard(chunk))
  (socket.on_error)(() => {
    v.cut = true
    v.close()
  })
  (socket.on_close)(() => {
    v.cut = true
    ignore(v.ready.fail(fail("the screen's helper ended the view")))
    v.close()
  })
  v
}

///|
fn HelperView::heard(self : HelperView, chunk : Bytes) -> Unit {
  self.carry.push(chunk)
  while self.carry.length >= 5 {
    let length = self.carry.u32_at(1)
    if self.carry.length.to_int64() < 5L + length {
      return
    }
    let kind = self.carry.byte_at(0).to_int()
    ignore(self.carry.take(5))
    let payload = self.carry.take(length.to_int())
    self.message(kind, payload)
  }
}

///|
fn HelperView::message(self : HelperView, kind : Int, payload : Bytes) -> Unit {
  match kind {
    1 => {
      let info = parse_or_null(payload)
      match get(Some(info), "error") {
        Some(Str(_) as e) =>
          ignore(self.ready.fail(Failed(text(Some(e)).unwrap_or(""), jsome([("code", get(Some(info), "code"))]))))
        _ => {
          // What it encodes: as it says (H.264 where H.265 was asked and this Mac has no encoder of it; a helper from
          // before H.265 says nothing and makes H.264 of anything but JPEG).
          self.codec = match text(get(Some(info), "codec")).bind(codec_of) {
            Some(c) => c
            None => if self.codec == Jpeg { Jpeg } else { H264 }
          }
          self.io.log.info(
            "screens",
            "a view opened",
            fields=jsome([
              ("capture", Some(js(self.capture))),
              ("width", get(Some(info), "width")),
              ("height", get(Some(info), "height")),
              ("encoder", get(Some(info), "encoder")),
            ]),
          )
          match text(get(Some(info), "encoder")) {
            Some(e) => self.encoder = slice_units(e, 0, 200)
            None => ()
          }
          self.regions_ = get(Some(info), "regions") is Some(Bool(true))
          match get(Some(info), "windows") {
            Some(Arr(_) as ws) =>
              self.windows = Some({
                windows: windows_of(Some(ws)),
                window: num(get(Some(info), "window")),
              })
            _ => ()
          }
          self.audio = self.audio && get(Some(info), "audio") is Some(Bool(true))
          ignore(
            self.ready.succeed(
              jsome([("width", get(Some(info), "width")), ("height", get(Some(info), "height"))]),
            ),
          )
        }
      }
    }
    8 => {
      let config = parse_or_null(payload)
      let codec = text(get(Some(config), "codec"))
      if (codec == Some("pcm_s16le") || codec == Some("opus")) &&
        num(get(Some(config), "sampleRate")) == Some(48000.0) &&
        num(get(Some(config), "channels")) == Some(2.0) {
        self.audio_codec = codec.unwrap()
      } else {
        self.audio = false
        let resolve = self.audio_wait
        self.audio_wait = None
        match resolve {
          Some(r) => r(None)
          None => ()
        }
      }
    }
    9 => {
      let resolve = self.audio_wait
      self.audio_wait = None
      guard resolve is Some(resolve) else { return }
      let size = payload.length() - 8
      let bad = if self.audio_codec == "pcm_s16le" { size != 3840 } else { size < 1 || size > OPUS_MAX }
      if bad {
        self.audio = false
        resolve(None)
        return
      }
      resolve(Some({ ts: u64be(payload, 0).to_double(), data: Bytes::from_array(payload[8:].to_array()), codec: self.audio_codec }))
    }
    2 =>
      self.config = Some({
        codec: self.codec,
        width: u32be(payload, 0).to_double(),
        height: u32be(payload, 4).to_double(),
        description: if self.codec != Jpeg { Some(Bytes::from_array(payload[8:].to_array())) } else { None },
        region: None,
      })
    7 => {
      let said = parse_or_null(payload)
      self.region = region_of(get(Some(said), "region"))
    }
    3 => {
      let config = {
        if self.config is None && self.last_config is Some(_) && self.region != self.sent_region {
          // Another part of the display than the last frame's: a config again, saying it (the same codec and size).
          self.config = self.last_config
        }
        match self.config {
          Some(c) => {
            let config = { ..c, region: None }
            self.last_config = Some(config)
            self.sent_region = self.region
            self.config = None
            Some({ ..config, region: self.region })
          }
          None => None
        }
      }
      let frame = {
        config,
        key: (payload[0].to_int() & 1) == 1,
        ts: u64be(payload, 1).to_double(),
        data: Bytes::from_array(payload[9:].to_array()),
      }
      if self.waiting.length() > 0 {
        (self.waiting.remove(0))(Some(frame))
      }
    }
    4 => {
      let said = parse_or_null(payload)
      // Whether an app holds the pointer, as it changes.
      if get(Some(said), "pointerLock") is Some(Bool(locked)) {
        if locked != self.last_pointer_lock {
          self.last_pointer_lock = locked
          match self.pointer_lock {
            Some((_, f)) => f(locked)
            None => ()
          }
        }
        return
      }
      // The virtual microphone, while it is watched.
      if get(Some(said), "mic") is Some(Obj(_) as m) {
        let available = get(Some(m), "available") is Some(Bool(true))
        let epoch = match get(Some(m), "epoch") {
          Some(Num(n)) if n >= 0.0 && n < 18446744073709551616.0 && n == n.floor() => n.to_uint64().to_uint()
          _ => 0U
        }
        let mic = { available, active: available && get(Some(m), "active") is Some(Bool(true)), epoch }
        match self.mic_heard {
          Some((_, f)) => {
            self.last_mic = Some(mic)
            f(mic)
          }
          None => ()
        }
        return
      }
      // The windows changed, or the one shown alone (asked, or it closed): told; anything else is the helper's log.
      if said is Obj(_) {
        let ws = get(Some(said), "windows")
        let window = get(Some(said), "window")
        if ws is Some(Arr(_)) || window is Some(Null) || window is Some(Num(_)) {
          let was = self.windows.unwrap_or({ windows: [], window: None })
          let next = {
            windows: if ws is Some(Arr(_)) { windows_of(ws) } else { was.windows },
            window: match window {
              Some(Null) => None
              Some(Num(n)) => Some(n)
              _ => was.window
            },
          }
          self.windows = Some(next)
          match self.heard_windows {
            Some((_, f)) => f(next)
            None => ()
          }
          return
        }
      }
      self.io.log.info("screens", "still.fail Helper", fields=jo([("said", js(@utf8.decode_lossy(payload)))]))
    }
    6 => {
      let said = parse_or_null(payload)
      let unit = (v : J?) => match v {
        Some(Num(d)) => d.is_finite() && d >= 0.0 && d <= 1.0
        _ => false
      }
      if said is Null || !unit(get(Some(said), "x")) || !unit(get(Some(said), "y")) {
        return
      }
      // (one of an app's own whose picture it did not say: the default)
      let shape = match text(get(Some(said), "shape")) {
        Some(s) if cursor_shape(s) && (!s.has_prefix("custom:") || self.cursor_images.contains(s)) => s
        _ => "default"
      }
      let c = { x: num(get(Some(said), "x")).unwrap(), y: num(get(Some(said), "y")).unwrap(), shape }
      self.last_cursor = Some(c)
      match self.cursor {
        Some((_, f)) => f(c)
        None => ()
      }
    }
    11 =>
      match cursor_image_shape(payload[:]) {
        Some(shape) => {
          if self.cursor_images.length() >= CURSOR_IMAGES_MOST && !self.cursor_images.contains(shape) {
            self.cursor_images.clear()
          }
          self.cursor_images[shape] = payload
        }
        None => ()
      }
    10 => {
      let said = parse_or_null(payload)
      let turn = match get(Some(said), "turn") {
        Some(Num(0.0)) => 0
        Some(Num(1.0)) => 1
        Some(Num(2.0)) => 2
        Some(Num(3.0)) => 3
        _ => return
      }
      self.last_turn = Some(turn)
      match self.turn {
        Some((_, f)) => f(turn)
        None => ()
      }
    }
    5 => {
      if payload.length() == 0 {
        return
      }
      let body = Bytes::from_array(payload[1:].to_array())
      let clip = match payload[0] {
        b'\x01' => Some(ClipText(@utf8.decode_lossy(body)))
        b'\x02' => Some(ClipPng(body))
        _ => None
      }
      match clip {
        Some(c) if clip_fits(c) =>
          match self.clipboard {
            Some((_, f)) => f(c, 0)
            None => ()
          }
        _ => ()
      }
    }
    12 => {
      if payload.length() < 2 {
        return
      }
      let privacy = payload[0].to_int()
      let body = Bytes::from_array(payload[2:].to_array())
      let clip = match payload[1] {
        b'\x01' => Some(ClipText(@utf8.decode_lossy(body)))
        b'\x02' => Some(ClipPng(body))
        _ => None
      }
      match clip {
        Some(c) if clip_fits(c) =>
          match self.clipboard {
            Some((_, f)) => f(c, if privacy >= 1 && privacy <= 3 { privacy } else { 0 })
            None => ()
          }
        _ => ()
      }
    }
    _ => ()
  }
}

///|
fn HelperView::send(self : HelperView, kind : Int, payload? : BytesView = b"") -> Unit {
  if self.ended {
    return
  }
  (self.socket.write)(helper_message(kind, payload~))
}

///|
pub async fn HelperView::next(self : HelperView) -> Frame? {
  if self.ended {
    return None
  }
  let d : @effect.Deferred[Frame?] = @effect.Deferred::new()
  self.waiting.push(f => ignore(d.succeed(f)))
  self.send(TO_NEXT)
  d.wait()
}

///|
pub fn HelperView::has_audio(self : HelperView) -> Bool {
  self.audio
}

///|
pub async fn HelperView::next_audio(self : HelperView) -> AudioFrame? {
  if self.ended || !self.audio {
    return None
  }
  if self.audio_wait is Some(_) {
    raise fail("audio already pending")
  }
  let d : @effect.Deferred[AudioFrame?] = @effect.Deferred::new()
  self.audio_wait = Some(f => ignore(d.succeed(f)))
  self.send(TO_AUDIO)
  d.wait()
}

///|
pub fn HelperView::keyframe(self : HelperView) -> Unit {
  self.send(TO_KEYFRAME)
}

///|
pub fn HelperView::video(self : HelperView) -> ScreenVideo {
  // The helpers name a software encoder so ("software", "Microsoft H.264 (software)"); a JPEG is no encoder's.
  if self.codec == Jpeg || self.encoder == "" {
    return { capture: self.capture, encoder: if self.encoder != "" { Some(self.encoder) } else { None }, hardware: None }
  }
  { capture: self.capture, encoder: Some(self.encoder), hardware: Some(!has_software(self.encoder)) }
}

///|
/// `/software/i.test(s)`.
fn has_software(s : String) -> Bool {
  s.to_lower().contains("software")
}

///|
pub fn HelperView::rate(self : HelperView, bits_per_second : Double) -> Unit {
  if self.codec == Jpeg {
    return
  }
  let payload = FixedArray::make(4, b'\x00')
  let v = js_min(4294967295.0, js_max(0.0, js_round(bits_per_second)))
  put_u32be(payload, 0, if v.is_nan() { 0L } else { v.to_int64() })
  self.send(TO_RATE, payload=Bytes::from_array(payload))
}

///|
pub fn HelperView::bounds(self : HelperView, max_width : Double, max_height : Double, region : Region?) -> Unit {
  let part = match region {
    Some(r) if self.regions_ => [("region", r.to_j())]
    _ => []
  }
  let body = jo([("maxWidth", jn(js_round(max_width))), ("maxHeight", jn(js_round(max_height)))] + part)
  self.send(TO_BOUNDS, payload=@utf8.encode(stringify(body)))
}

///|
pub fn HelperView::regions(self : HelperView) -> Bool {
  self.regions_
}

///|
pub fn HelperView::input(self : HelperView, event : ScreenInput) -> Unit {
  for op in (self.input_ops.ops)(event, self.io.clock.ms()) {
    self.send(TO_INPUT, payload=@utf8.encode(stringify(op)))
  }
}

///|
pub fn HelperView::set_clipboard(self : HelperView, clip : Clip, paste : Bool, privacy? : Int = 0) -> Unit {
  // (flags: bit 0 paste, bits 1..2 the clip's mark)
  self.send(TO_CLIPBOARD, payload=helper_clip(clip, flags=Some((if paste { 1 } else { 0 }) | ((privacy & 3) << 1))))
}

///|
fn HelperView::id(self : HelperView) -> Int {
  self.next_id += 1
  self.next_id
}

///|
pub fn HelperView::watch_clipboard(self : HelperView, heard : (Clip) -> Unit) -> () -> Unit {
  self.watch_clipboard_marked((c, _) => heard(c))
}

///|
pub fn HelperView::watch_clipboard_marked(self : HelperView, heard : (Clip, Int) -> Unit) -> () -> Unit {
  let id = self.id()
  self.clipboard = Some((id, heard))
  self.send(TO_WATCH, payload=b"\x01")
  () => match self.clipboard {
    Some((i, _)) if i == id => {
      self.clipboard = None
      self.send(TO_WATCH, payload=b"\x00")
    }
    _ => ()
  }
}

///|
pub fn HelperView::watch_pointer_lock(self : HelperView, heard : (Bool) -> Unit) -> () -> Unit {
  let id = self.id()
  self.pointer_lock = Some((id, heard))
  if self.last_pointer_lock {
    heard(true)
  }
  () => match self.pointer_lock {
    Some((i, _)) if i == id => self.pointer_lock = None
    _ => ()
  }
}

///|
/// The machine's virtual microphone (Helper's Microphone.swift, stillfail-screen's mic.rs), watched by the helper.
pub fn HelperView::watch_mic(self : HelperView, heard : (ScreenMic) -> Unit) -> () -> Unit {
  let id = self.id()
  self.mic_heard = Some((id, heard))
  self.last_mic = None
  self.send(TO_WATCH_MIC, payload=b"\x01")
  () => match self.mic_heard {
    Some((i, _)) if i == id => {
      self.mic_heard = None
      self.last_mic = None
      self.send(TO_WATCH_MIC, payload=b"\x00")
    }
    _ => ()
  }
}

///|
/// A packet for the virtual microphone, sent only while something records it in that epoch.
pub fn HelperView::feed_mic(self : HelperView, pcm : Bytes, epoch : UInt) -> Unit {
  guard self.last_mic is Some(m) && m.active && m.epoch == epoch else { return }
  let n = pcm.length()
  if n < 2 || n > MIC_PCM_MAX || n % 2 != 0 {
    return
  }
  let head = FixedArray::make(5, b'\x00')
  put_u32be(head, 1, epoch.to_int64())
  self.send(TO_MIC, payload=concat([Bytes::from_array(head), pcm]))
}

///|
pub fn HelperView::reveal(self : HelperView, path : String) -> Unit {
  self.send(TO_REVEAL, payload=@utf8.encode(path))
}

///|
pub fn HelperView::watch_cursor(self : HelperView, heard : (ScreenCursor) -> Unit) -> () -> Unit {
  let id = self.id()
  self.cursor = Some((id, heard))
  match self.last_cursor {
    Some(c) => heard(c)
    None => ()
  }
  () => match self.cursor {
    Some((i, _)) if i == id => self.cursor = None
    _ => ()
  }
}

///|
pub fn HelperView::cursor_image(self : HelperView, shape : String) -> Bytes? {
  self.cursor_images.get(shape)
}

///|
pub fn HelperView::watch_windows(self : HelperView, heard : (ScreenWindows) -> Unit) -> () -> Unit {
  let id = self.id()
  self.heard_windows = Some((id, heard))
  match self.windows {
    Some(w) => heard(w)
    None => ()
  }
  () => match self.heard_windows {
    Some((i, _)) if i == id => self.heard_windows = None
    _ => ()
  }
}

///|
pub fn HelperView::window(self : HelperView, id : Double?) -> Unit {
  match id {
    Some(i) => {
      let known = match self.windows {
        Some(w) => w.windows.iter().any(x => x.id == i)
        None => false
      }
      if !known {
        return
      }
    }
    None => ()
  }
  let body = jo([
    (
      "window",
      match id {
        Some(i) => jn(i)
        None => Null
      },
    ),
  ])
  self.send(TO_WINDOW, payload=@utf8.encode(stringify(body)))
}

///|
pub fn HelperView::watch_turn(self : HelperView, heard : (Int) -> Unit) -> () -> Unit {
  let id = self.id()
  self.turn = Some((id, heard))
  match self.last_turn {
    Some(t) => heard(t)
    None => ()
  }
  () => match self.turn {
    Some((i, _)) if i == id => self.turn = None
    _ => ()
  }
}

///|
pub fn HelperView::close(self : HelperView) -> Unit {
  if self.ended {
    return
  }
  // What its person holds down is let go of on the machine, else it stays held after them.
  if !self.cut {
    match self.input_ops.release {
      Some(release) => for op in release() {
        self.send(TO_INPUT, payload=@utf8.encode(stringify(op)))
      }
      None => ()
    }
  }
  self.ended = true
  (self.socket.destroy)()
  for w in self.waiting.copy() {
    w(None)
  }
  self.waiting.clear()
  match self.audio_wait {
    Some(r) => r(None)
    None => ()
  }
  self.audio_wait = None
  (self.gone)()
}

///|
/// The view as a source's views are.
pub fn HelperView::view(self : HelperView) -> ScreenView {
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
    set_clipboard_marked: Some(async fn(c, p, m) { self.set_clipboard(c, p, privacy=m) }),
    watch_clipboard_marked: Some(f => self.watch_clipboard_marked(f)),
    watch_pointer_lock: Some(f => self.watch_pointer_lock(f)),
    watch_mic: if self.mic { Some(f => self.watch_mic(f)) } else { None },
    feed_mic: Some((p, e) => self.feed_mic(p, e)),
    reveal: Some(async fn(p) { self.reveal(p) }),
    watch_cursor: Some(f => self.watch_cursor(f)),
    cursor_image: Some(s => self.cursor_image(s)),
    watch_windows: Some(f => self.watch_windows(f)),
    window: Some(i => self.window(i)),
    watch_turn: Some(f => self.watch_turn(f)),
  }
}

///|
/// What the desktop is given (desktop.ts `DesktopOptions`): whether this machine's display can be seen at all, still.fail
/// Helper (none where the release has none), what is known of its grants (default its own, with `reach`), who is told
/// it changed, its title (default the machine's name), the language of the helper's window, and the side test's
/// made-up pictures.
pub(all) struct DesktopOptions {
  supported : Bool
  helper : HelperApp?
  grants : HelperGrants?
  reach : async () -> String?
  changed : () -> Unit
  title : (() -> String)?
  lang : (() -> String)?
  synthetic : String?
}

///|
/// The Mac's display (desktop.ts `Desktop`).
pub struct Desktop {
  priv io : Io
  priv o : DesktopOptions
  priv grants : HelperGrants?
  priv views : Array[HelperView]
  /// Its window was put up for grants not all taken yet: up again when the helper comes back still lacking one.
  priv mut wanted : Bool
  /// The display's mode before a view first changed it (its size, and its id where the helper said it), put back once
  /// the last view ends; none while unchanged.
  priv mut original_mode : (Double, Double, Double?)?
  /// Resolution changes, one after another.
  priv sizing : Chain
}

///|
pub fn Desktop::new(io : Io, o : DesktopOptions) -> Desktop {
  let grants = match o.helper {
    None => None
    Some(h) =>
      match o.grants {
        Some(g) => Some(g)
        None => Some(HelperGrants::new(io, h, o.reach))
      }
  }
  // Its grants or display changed: told with the screens.
  match grants {
    Some(g) => ignore(g.on_change(() => (o.changed)()))
    None => ()
  }
  { io, o, grants, views: [], wanted: false, original_mode: None, sizing: Chain::new() }
}

///|
fn Desktop::status(self : Desktop) -> J? {
  self.grants.bind(g => g.status())
}

///|
pub fn Desktop::title(self : Desktop) -> String {
  match self.o.title {
    Some(f) => f()
    None => {
      let h = (self.io.os.hostname)()
      if h.has_suffix(".local") {
        h.unsafe_substring(start=0, end=h.length() - 6)
      } else {
        h
      }
    }
  }
}

///|
fn display_size(s : J?, k : String) -> Double {
  match get(get(s, "display"), k) {
    Some(Num(d)) => d
    _ => 0.0
  }
}

///|
pub fn Desktop::size(self : Desktop) -> (Double, Double) {
  let s = self.status()
  (display_size(s, "width"), display_size(s, "height"))
}

///|
/// Text and pictures, wherever the helper is.
pub fn Desktop::clipboard(self : Desktop) -> Array[String] {
  if self.o.supported && self.o.helper is Some(_) {
    ["text", "png"]
  } else {
    []
  }
}

///|
pub fn Desktop::access(self : Desktop) -> ScreenAccess {
  if !self.o.supported {
    return ScreenAccess::new(false, false, unsupported=Some("platform"))
  }
  if self.o.helper is None {
    return ScreenAccess::new(false, false, unsupported=Some("helper"))
  }
  // Not looked at yet: nothing said.
  guard self.status() is Some(s) else { return ScreenAccess::new(true, true) }
  let responsible = get(Some(s), "responsible")
  let (app, path) = match text(get(responsible, "path")) {
    Some(p) if p != "" => (text(get(responsible, "name")), Some(p))
    _ => (None, None)
  }
  ScreenAccess::new(
    truthy(get(Some(s), "capture")),
    truthy(get(Some(s), "control")),
    app~,
    path~,
    asking=truthy(get(Some(s), "asking")),
  )
}

///|
/// The grants and the display as macOS has them now (at most a moment old, unless `force`).
pub async fn Desktop::refresh(self : Desktop, force? : Bool = false) -> Unit {
  if !self.o.supported {
    return
  }
  match self.grants {
    Some(g) => g.refresh(force~)
    None => ()
  }
}

///|
pub async fn Desktop::open(self : Desktop, options : ViewOptions) -> ScreenView {
  if !self.o.supported {
    raise self.io.refused(501, "station.screen.unsupported", access=Some(self.access()))
  }
  guard self.o.helper is Some(helper) else {
    raise self.io.refused(501, "station.screen.noHelper", access=Some(self.access()))
  }
  // H.265 where it is taken, H.264, else a JPEG a picture (an agent's view, a client without either).
  guard codec_for(options, [H265, H264, Jpeg]) is Some(codec) else {
    raise self.io.refused(415, "station.screen.codec", args=jo([("codec", js("H.264, JPEG"))]))
  }
  self.refresh(force=true)
  let synthetic = self.o.synthetic is Some(_)
  if !synthetic && self.status() is None {
    raise self.io.refused(503, "station.screen.failed", args=jo([("said", js("still.fail Helper did not answer"))]))
  }
  match self.status() {
    Some(s) if !synthetic && (!truthy(get(Some(s), "capture")) || !truthy(get(Some(s), "control"))) => self.ask(helper)
    _ => ()
  }
  if !synthetic && !(get(self.status(), "capture") is Some(Bool(true))) {
    raise self.refused_()
  }
  // The Mac's system output too, when the client asked for it (never a preview's).
  let audio = options.audio && !options.peek
  let mut attempt = 0
  while true {
    let op = jsome([
      ("op", Some(js("screen.view"))),
      ("codec", Some(js(codec.name()))),
      ("maxWidth", Some(jn(options.max_width))),
      ("maxHeight", Some(jn(options.max_height))),
      ("bitrate", options.bitrate.map(b => jn(js_round(b)))),
      ("fps", options.fps.map(jn)),
      ("gamut", options.gamut.filter(g => g != "").map(js)),
      ("chroma", options.chroma.filter(c => c != "").map(js)),
      (
        "display",
        match get(self.status(), "display") {
          Some(Obj(_) as d) => get(Some(d), "id")
          _ => None
        },
      ),
      ("audio", if audio { Some(jb(true)) } else { None }),
      ("audioCodec", if audio && options.opus { Some(js("opus")) } else { None }),
      ("synthetic", self.o.synthetic.map(js)),
    ])
    let socket = helper.connect(op)
    let view_ref : Ref[HelperView?] = Ref(None)
    let view = HelperView::new(
      self.io,
      codec,
      sock_pipe(socket),
      () => {
        match view_ref.val {
          Some(v) =>
            match self.views.search_by(x => physical_equal(x, v)) {
              Some(i) => ignore(self.views.remove(i))
              None => ()
            }
          None => ()
        }
        self.put_back()
      },
      input=Some(MacInput::new().input_ops()),
      capture="ScreenCaptureKit",
      mic=true,
      audio~,
    )
    view_ref.val = Some(view)
    self.views.push(view)
    try {
      ignore(view.ready.wait())
      return view.view()
    } catch {
      error => {
        view.close()
        let code = text(field_of(error, "code"))
        if code == Some("restart") && attempt == 0 {
          helper.back()
          attempt += 1
          continue
        }
        if code == Some("capture") || code == Some("restart") {
          self.refresh(force=true)
          raise self.refused_()
        }
        raise self.io.refused(503, "station.screen.failed", args=jo([("said", js(message_of(error)))]))
      }
    }
  }
  panic()
}

///|
fn Desktop::refused_(self : Desktop) -> ScreenRefused {
  let access = self.access()
  let app = match access.app {
    Some(a) if a != "" => a
    _ => "still.fail Helper"
  }
  self.io.refused(503, "station.screen.captureOff", args=jo([("app", js(app))]), access=Some(access))
}

///|
/// The helper came back after it ended by itself: its window again, with what is still missing, when it was asking.
pub async fn Desktop::helper_back(self : Desktop) -> Unit {
  self.refresh(force=true)
  guard self.status() is Some(s) else { return }
  if truthy(get(Some(s), "capture")) && truthy(get(Some(s), "control")) {
    self.wanted = false
  } else if self.wanted {
    match self.o.helper {
      Some(h) => self.ask(h)
      None => ()
    }
  }
}

///|
/// The helper's window asking for what is missing, on this Mac, in its language; what it says then.
async fn Desktop::ask(self : Desktop, helper : HelperApp) -> Unit {
  self.wanted = true
  try {
    let lang = match self.o.lang {
      Some(f) => f()
      None => (self.io.words.station_lang)()
    }
    ignore(
      helper.request(
        jo([
          ("op", js("permissions.show")),
          ("words", window_words(self.io, lang)),
          ("grants", jstrs(["capture", "control"])),
        ]),
      ),
    )
    self.refresh(force=true)
  } catch {
    e => self.io.log.warn("screens", "still.fail Helper's window did not show", fields=jo([("error", js(message_of(e)))]))
  }
}

///|
/// Its apps' accessibility trees: agent-desktop in still.fail Helper.
pub async fn Desktop::ui(self : Desktop, args : Array[String]) -> J {
  match self.o.helper {
    Some(h) if self.o.supported => helper_ui(h)(args)
    _ =>
      raise self.io.refused(
        501,
        if self.o.supported { "station.screen.noHelper" } else { "station.screen.unsupported" },
        access=Some(self.access()),
      )
  }
}

///|
/// The helper's `resolution` op for its display, with `more` (a size to set).
fn Desktop::resolution_op(self : Desktop, more : Array[(String, J?)]) -> J {
  let display = match get(self.status(), "display") {
    Some(Obj(_) as d) => get(Some(d), "id")
    _ => None
  }
  let pairs = [("op", Some(js("resolution")))]
  pairs.append(more)
  pairs.push(("display", display))
  jsome(pairs)
}

///|
/// A mode as it is put back: its size, and its id where the helper said it.
fn mode_fields(mode : (Double, Double, Double?)) -> Array[(String, J?)] {
  let (w, h, id) = mode
  [("width", Some(jn(w))), ("height", Some(jn(h))), ("modeID", id.map(jn))]
}

///|
/// As it is once the changes asked before are made; none where it is not had (no helper, one from before it).
pub async fn Desktop::resolution(self : Desktop) -> ScreenResolution? {
  guard self.o.supported && self.o.helper is Some(helper) else { return None }
  self.sizing.then(self.io, async fn() {
    let told = helper.request(self.resolution_op([])) catch {
      e => {
        self.io.log.info("screens", "the display's resolution was not had", fields=jo([("error", js(message_of(e)))]))
        return None
      }
    }
    resolution_of(Some(told))
  })
}

///|
pub async fn Desktop::set_resolution(self : Desktop, width : Double, height : Double) -> ScreenResolution {
  guard self.o.supported && self.o.helper is Some(helper) else { raise fail("the display's resolution was not had") }
  self.sizing.then(self.io, async fn() {
    if self.original_mode is None {
      let told = helper.request(self.resolution_op([]))
      guard resolution_of(Some(told)) is Some(before) else { raise fail("the display's resolution was not had") }
      self.original_mode = Some((before.width, before.height, num(get(Some(told), "modeID")).filter(is_integer)))
    }
    let asked = self.resolution_op([("width", Some(jn(js_round(width)))), ("height", Some(jn(js_round(height))))])
    guard resolution_of(Some(helper.request(asked))) is Some(now) else {
      raise fail("the display's resolution was not had")
    }
    self.io.log.info(
      "screens",
      "the display's resolution set",
      fields=jo([
        ("width", jn(now.width)),
        ("height", jn(now.height)),
        (
          "was",
          match self.original_mode {
            Some(m) => jsome(mode_fields(m))
            None => Null
          },
        ),
      ]),
    )
    // (its size in pixels another now: had again, and listed anew)
    self.refresh(force=true)
    (self.o.changed)()
    now
  })
}

///|
/// The last view ended: the display's mode as it was before a view changed it.
fn Desktop::put_back(self : Desktop) -> Unit {
  guard self.views.length() == 0 && self.original_mode is Some(mode) && self.o.helper is Some(helper) else { return }
  self.original_mode = None
  let fields = mode_fields(mode)
  self.sizing.after(self.io, async fn() {
    let _ = helper.request(self.resolution_op(fields)) catch {
      e => {
        self.io.log.warn(
          "screens",
          "the display's resolution was not put back",
          fields=spread(jsome(fields), jo([("error", js(message_of(e)))])),
        )
        return
      }
    }
    self.io.log.info("screens", "the display's resolution put back", fields=jsome(fields))
    self.refresh(force=true)
    (self.o.changed)()
  })
}

///|
/// The station stopping: every view ends, the display's resolution is put back, then the helper goes.
pub async fn Desktop::close(self : Desktop) -> Unit {
  for v in self.views.copy() {
    v.close()
  }
  // (put back before the helper quits: it is the helper that sets it)
  self.sizing.idle()
  match self.o.helper {
    Some(h) => h.quit() catch { _ => () }
    None => ()
  }
}

///|
pub fn Desktop::source(self : Desktop) -> ScreenSource {
  {
    ..ScreenSource::bare("desktop", DesktopKind, () => self.title(), () => self.size(), async fn(o) { self.open(o) }),
    reveal: true,
    access: Some(() => self.access()),
    clipboard: Some(() => self.clipboard()),
    resolution: Some(async fn() { self.resolution() }),
    set_resolution: Some(async fn(w, h) { self.set_resolution(w, h) }),
    ui: Some(async fn(args) { self.ui(args) }),
  }
}
