// Android emulators and phones on this machine's adb as screen sources (`android:<id>`; src/screens/android.ts): a
// touchscreen as an iOS Simulator is (kind `simulator`), its pictures and input through scrcpy's program on the device
// (./scrcpy-server, its version pinned: its protocol is its own and changes between releases). A phone lent to a chat
// is in that grant's adb server, not here.

///|
/// The version of ./scrcpy-server: it refuses to run under any other name.
pub const SERVER_VERSION : String = "5.0.1"

///|
/// scrcpy's server: beside this module in src, and beside main.js in a release.
pub fn server_file(io : Io) -> String {
  pj([io.os.code_dir, "scrcpy-server"])
}

///|
/// How long a view's program has to start listening on the device.
const CONNECT_TIMEOUT : Double = 15000

///|
/// How long a look at a device is given.
const ADB_TIMEOUT : Double = 15000

///|
/// How long after `adb track-devices` ended it is started again.
const FOLLOW_AGAIN : Double = 5000

///|
/// How long after a device could not be looked at it is looked at again.
const LOOK_AGAIN : Double = 3000

///|
/// How long adb's devices are followed after the screens were last asked for, none of them there.
const FOLLOWED_FOR : Double = 600000

///|
/// Encoded frames kept for a view that asks slowly: past this they are dropped up to a new key frame.
const QUEUE_MOST : Int = 30

///|
/// What a view is encoded at, by the side scrcpy is asked for.
pub fn bitrate_of(side : Int) -> Int {
  if side <= 480 {
    2000000
  } else if side <= 720 {
    3000000
  } else if side <= 1080 {
    5000000
  } else if side <= 1440 {
    7000000
  } else {
    8000000
  }
}

///|
/// A preview (a link's card): about two pictures a second, small and cheap.
pub const PEEK_FPS : Int = 2

///|
pub const PEEK_BITRATE : Int = 300000

///|
/// The most previews of this machine's devices running at once, besides the views.
pub const PEEKS_MOST : Int = 2

///|
/// What a view opened to drive shows at least, however small the window it opened in.
const LEAST_SIDE : Double = 1280

///|
const MOST_SIDE : Double = 2560

///|
/// How far apart two width-to-height ratios are the one shape.
const SAME_SHAPE : Double = 0.02

///|
const SCROLL_MOST : Double = 16

///|
/// A page's wheel pixels in one notch of Android's AXIS_SCROLL.
const WHEEL_NOTCH : Double = 100

///|
const CONTROL_KEY : Int = 0

///|
const CONTROL_TEXT : Int = 1

///|
const CONTROL_TOUCH : Int = 2

///|
const CONTROL_SCROLL : Int = 3

///|
const CONTROL_CLIPBOARD : Int = 9

///|
const CONTROL_RESET : Int = 17

///|
const TOUCH_DOWN : Int = 0

///|
const TOUCH_UP : Int = 1

///|
const TOUCH_MOVE : Int = 2

///|
const TEXT_MOST : Int = 300

///|
/// The display turned a quarter (out of following the sensor, as a person's own lock does).
const ROTATE : String = "case \"$(wm user-rotation)\" in \"lock 1\") n=2;; \"lock 2\") n=3;; \"lock 3\") n=0;; *) n=1;; esac; wm user-rotation lock $n"

///|
const KEY_HOME : Int = 3

///|
const KEY_BACK : Int = 4

///|
const KEY_VOLUME_UP : Int = 24

///|
const KEY_VOLUME_DOWN : Int = 25

///|
const KEY_POWER : Int = 26

///|
const KEY_APP_SWITCH : Int = 187

///|
/// A page's KeyboardEvent.code → Android's KeyEvent keycode. Escape is the device's back, as the emulator's has it.
pub let android_keycodes : Map[String, Int] = {
  let m : Map[String, Int] = Map::new()
  for i, c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".to_array() {
    m["Key\{c}"] = 29 + i
  }
  for i, c in "0123456789".to_array() {
    m["Digit\{c}"] = 7 + i
  }
  for i in 0..<12 {
    m["F\{i + 1}"] = 131 + i
  }
  let rest : Array[(String, Int)] = [
    ("Enter", 66), ("NumpadEnter", 66), ("Escape", KEY_BACK), ("Backspace", 67), ("Tab", 61), ("Space", 62),
    ("Minus", 69), ("Equal", 70), ("BracketLeft", 71), ("BracketRight", 72), ("Backslash", 73), ("Semicolon", 74),
    ("Quote", 75), ("Backquote", 68), ("Comma", 55), ("Period", 56), ("Slash", 76), ("CapsLock", 115), ("Insert", 124),
    ("Home", 122), ("PageUp", 92), ("Delete", 112), ("End", 123), ("PageDown", 93), ("ArrowRight", 22),
    ("ArrowLeft", 21), ("ArrowDown", 20), ("ArrowUp", 19), ("ShiftLeft", 59), ("ShiftRight", 60), ("ControlLeft", 113),
    ("ControlRight", 114), ("AltLeft", 57), ("AltRight", 58), ("MetaLeft", 117), ("MetaRight", 118),
  ]
  for p in rest {
    m[p.0] = p.1
  }
  m
}

///|
/// A ScreenInput's `mods` as Android's meta state, each with its left key's bit.
pub fn meta_of(mods : Int) -> Int {
  (if (mods & 1) != 0 { 0x12 } else { 0 }) |
  (if (mods & 2) != 0 { 0x3000 } else { 0 }) |
  (if (mods & 4) != 0 { 0x30000 } else { 0 }) |
  (if (mods & 8) != 0 { 0x41 } else { 0 })
}

///|
/// A person's input as scrcpy's control messages (android.ts `AndroidInput`): the left button held is a finger, a
/// wheel the device's scroll, a key its keycode. Text goes as keys while they are ASCII, else pasted.
pub struct AndroidInput {
  priv mut finger : Bool
}

///|
pub fn AndroidInput::new() -> AndroidInput {
  { finger: false }
}

///|
pub fn AndroidInput::messages(self : AndroidInput, e : ScreenInput, size : (Double, Double)) -> Array[Bytes] {
  match e {
    Pointer(kind~, x~, y~, buttons~, ..) => {
      let left = (buttons & 1) == 1
      if !self.finger {
        if kind != "down" || !left {
          return []
        }
        self.finger = true
        return [touch(TOUCH_DOWN, x, y, size)]
      }
      if left && kind != "up" {
        return [touch(TOUCH_MOVE, x, y, size)]
      }
      self.finger = false
      [touch(TOUCH_UP, x, y, size)]
    }
    Wheel(x~, y~, dx~, dy~) => if dx == 0.0 && dy == 0.0 { [] } else { [scroll(x, y, dx, dy, size)] }
    Key(kind~, code~, mods~, ..) => self.key(kind == "down", code, mods)
    Text(t) => text_messages(t)
    Device(name) =>
      if name == "volume_up" {
        press(KEY_VOLUME_UP)
      } else if name == "volume_down" {
        press(KEY_VOLUME_DOWN)
      } else {
        []
      }
    Pose(_) | Button(..) | Gamepad(_) => []
  }
}

///|
fn AndroidInput::key(self : AndroidInput, down : Bool, code : String, mods : Int) -> Array[Bytes] {
  ignore(self)
  let meta = (mods & 4) != 0
  let shift = (mods & 8) != 0
  let ctrl = (mods & 2) != 0
  let alt = (mods & 1) != 0
  if meta && !alt {
    let button = if ctrl {
      if shift && code == "KeyH" {
        Some(KEY_APP_SWITCH)
      } else {
        None
      }
    } else if shift && code == "KeyH" {
      Some(KEY_HOME)
    } else if !shift && code == "KeyL" {
      Some(KEY_POWER)
    } else {
      None
    }
    match button {
      Some(b) => return if down { press(b) } else { [] }
      None => ()
    }
    // (its software keyboard shows by itself as a field takes the focus)
    if !ctrl && !shift && code == "KeyK" {
      return []
    }
  }
  match android_keycodes.get(code) {
    Some(k) => [key_message(down, k, meta_of(mods))]
    None => []
  }
}

///|
fn key_message(down : Bool, keycode : Int, meta : Int) -> Bytes {
  let b = FixedArray::make(14, b'\x00')
  b[0] = CONTROL_KEY.to_byte()
  b[1] = (if down { 0 } else { 1 }).to_byte()
  put_i32be(b, 2, keycode)
  put_i32be(b, 6, 0)
  put_i32be(b, 10, meta)
  Bytes::from_array(b)
}

///|
fn press(keycode : Int) -> Array[Bytes] {
  [key_message(true, keycode, 0), key_message(false, keycode, 0)]
}

///|
fn position(b : FixedArray[Byte], at : Int, x : Double, y : Double, size : (Double, Double)) -> Unit {
  let (w, h) = size
  put_i32be(b, at, js_min(w - 1.0, js_round(clamp01(x) * w)).to_int())
  put_i32be(b, at + 4, js_min(h - 1.0, js_round(clamp01(y) * h)).to_int())
  put_u16be(b, at + 8, w.to_int())
  put_u16be(b, at + 10, h.to_int())
}

///|
fn touch(action : Int, x : Double, y : Double, size : (Double, Double)) -> Bytes {
  let b = FixedArray::make(32, b'\x00')
  b[0] = CONTROL_TOUCH.to_byte()
  b[1] = action.to_byte()
  // scrcpy's POINTER_ID_GENERIC_FINGER: a finger, not its mouse.
  put_i64be(b, 2, -2L)
  position(b, 10, x, y, size)
  put_u16be(b, 22, if action == TOUCH_UP { 0 } else { 0xffff })
  Bytes::from_array(b)
}

///|
/// A notch's share of [-16, 16] as scrcpy's 16-bit fixed point.
fn scroll_axis(pixels : Double) -> Int {
  let notches = js_max(-SCROLL_MOST, js_min(SCROLL_MOST, pixels / WHEEL_NOTCH))
  js_max(-32768.0, js_min(32767.0, js_round(notches / SCROLL_MOST * 32768.0))).to_int()
}

///|
fn scroll(x : Double, y : Double, dx : Double, dy : Double, size : (Double, Double)) -> Bytes {
  let b = FixedArray::make(21, b'\x00')
  b[0] = CONTROL_SCROLL.to_byte()
  position(b, 1, x, y, size)
  put_u16be(b, 13, scroll_axis(dx) & 0xffff)
  put_u16be(b, 15, scroll_axis(-dy) & 0xffff)
  Bytes::from_array(b)
}

///|
fn text_messages(t : String) -> Array[Bytes] {
  if t == "" {
    return []
  }
  let utf8 = @utf8.encode(t)
  let ascii = t.iter().all(c => c.to_int() >= 0x20 && c.to_int() <= 0x7e)
  if utf8.length() <= TEXT_MOST && ascii {
    let head = FixedArray::make(5, b'\x00')
    head[0] = CONTROL_TEXT.to_byte()
    put_u32be(head, 1, utf8.length().to_int64())
    return [concat([Bytes::from_array(head), utf8])]
  }
  let head = FixedArray::make(14, b'\x00')
  head[0] = CONTROL_CLIPBOARD.to_byte()
  // paste, after a sequence of 0 (no answer asked)
  head[9] = b'\x01'
  put_u32be(head, 10, utf8.length().to_int64())
  [concat([Bytes::from_array(head), utf8])]
}

///|
/// The NAL units of an Annex B stream, without their start codes.
pub fn nals_of(data : BytesView) -> Array[BytesView] {
  let out = []
  let mut start = -1
  let mut i = 0
  while i + 2 < data.length() {
    if data[i] != b'\x00' || data[i + 1] != b'\x00' || data[i + 2] != b'\x01' {
      i += 1
      continue
    }
    if start >= 0 {
      let end = if i >= 1 && data[i - 1] == b'\x00' { i - 1 } else { i }
      out.push(if end > start { data[start:end] } else { data[start:start] })
    }
    start = i + 3
    i += 3
  }
  if start >= 0 {
    out.push(data[start:])
  }
  out
}

///|
fn nal_type(n : BytesView) -> Int {
  if n.length() == 0 {
    0
  } else {
    n[0].to_int() & 0x1f
  }
}

///|
/// The avcC of an H.264 stream's SPS and PPS; none without both.
pub fn avcc_config_of(nals : Array[BytesView]) -> Bytes? {
  let sps = match nals.search_by(n => nal_type(n) == 7) {
    Some(i) => nals[i]
    None => return None
  }
  let pps = match nals.search_by(n => nal_type(n) == 8) {
    Some(i) => nals[i]
    None => return None
  }
  if sps.length() < 4 {
    return None
  }
  let out = FixedArray::make(11 + sps.length() + pps.length(), b'\x00')
  out[0] = b'\x01'
  out[1] = sps[1]
  out[2] = sps[2]
  out[3] = sps[3]
  // lengths in 4 bytes, one SPS
  out[4] = b'\xff'
  out[5] = b'\xe1'
  put_u16be(out, 6, sps.length())
  for i in 0..<sps.length() {
    out[8 + i] = sps[i]
  }
  // one PPS
  out[8 + sps.length()] = b'\x01'
  put_u16be(out, 9 + sps.length(), pps.length())
  for i in 0..<pps.length() {
    out[11 + sps.length() + i] = pps[i]
  }
  Some(Bytes::from_array(out))
}

///|
/// A frame's NAL units as AVCC, what its config says of itself left out.
pub fn avcc_of(nals : Array[BytesView]) -> Bytes {
  let buf = Buffer()
  for n in nals {
    let t = nal_type(n)
    if t == 7 || t == 8 {
      continue
    }
    let head = FixedArray::make(4, b'\x00')
    put_u32be(head, 0, n.length().to_int64())
    buf.write_bytes(Bytes::from_array(head))
    buf.write_bytesview(n)
  }
  buf.to_bytes()
}

///|
/// A media packet of scrcpy's video socket.
pub(all) struct ScrcpyPacket {
  config : Bool
  key : Bool
  pts : UInt64
  data : Bytes
}

///|
/// What the video socket says (android.ts `ScrcpyStream`): a byte, the device's name, the codec, then for each capture
/// a session packet and media packets.
pub struct ScrcpyStream {
  priv carry : Carry
  priv mut stage : Int
  priv session : ((Double, Double)) -> Unit
  priv packet : (ScrcpyPacket) -> Unit
}

///|
pub fn ScrcpyStream::new(session : ((Double, Double)) -> Unit, packet : (ScrcpyPacket) -> Unit) -> ScrcpyStream {
  { carry: Carry::new(), stage: 0, session, packet }
}

///|
pub fn ScrcpyStream::heard(self : ScrcpyStream, chunk : BytesView) -> Unit {
  self.carry.push(Bytes::from_array(chunk.to_array()))
  while true {
    let need = [1, 64, 4, 12][self.stage]
    if self.carry.length < need {
      return
    }
    if self.stage < 3 {
      ignore(self.carry.take(need))
      self.stage += 1
      continue
    }
    let flags = self.carry.byte_at(0).to_int()
    if (flags & 0x80) != 0 {
      let head = self.carry.take(12)
      (self.session)((u32be(head, 4).to_double(), u32be(head, 8).to_double()))
      continue
    }
    let length = self.carry.u32_at(8).to_int()
    if self.carry.length < 12 + length {
      return
    }
    let head = self.carry.take(12)
    let data = self.carry.take(length)
    (self.packet)({
      config: (flags & 0x40) != 0,
      key: (flags & 0x20) != 0,
      pts: u64be(head, 0) & 0x1fffffffffffffffUL,
      data,
    })
  }
}

///|
/// How adb is run here: a server this starts does not connect by itself to every phone paired with this machine's key
/// it finds on the network.
pub fn adb_env(io : Io) -> Env {
  let env = (io.os.env)().copy()
  env.set("ADB_MDNS_AUTO_CONNECT", "0")
  env
}

///|
/// adb started: through what runs it on the platform (`r`: looked for off the main thread by a caller that can wait),
/// no window on Windows.
fn adb_spawn(io : Io, path : String, args : Array[String], events : ChildEvents, env? : Env? = None, r? : Runnable? = None) -> Child {
  let env = env.unwrap_or(adb_env(io))
  let r = r.unwrap_or((io.os.runnable)(path, args, env))
  (io.procs.spawn)(r.file, r.args, { env: Some(env), group: false, verbatim: r.verbatim, stdio: ("pipe", "pipe", "pipe") }, events)
}

///|
/// `adb` of one device.
pub(all) struct Adb {
  run : async (Array[String]) -> String
  shell : (String, ChildEvents) -> Child
}

///|
fn adb_of(io : Io, path : String, serial : String) -> Adb {
  {
    run: async fn(args) { adb_run(io, path, ["-s", serial] + args) },
    shell: (command, events) => adb_spawn(io, path, ["-s", serial, "shell", command], events),
  }
}

///|
async fn adb_run(io : Io, path : String, args : Array[String]) -> String {
  let env = adb_env(io)
  let r = (io.os.runnable_soon)(path, args, env)
  let d : @effect.Deferred[String] = @effect.Deferred::new()
  let out = Buffer()
  let err = Buffer()
  let stop : Ref[() -> Unit] = Ref(() => ())
  let child = adb_spawn(
    io,
    path,
    args,
    {
      out: b => out.write_bytes(b),
      err: b => err.write_bytes(b),
      error: e => {
        (stop.val)()
        ignore(d.fail(fail(e)))
      },
      close: (code, _) => {
        (stop.val)()
        if code == Some(0) {
          ignore(d.succeed(@utf8.decode_lossy(out.to_bytes())))
        } else {
          let said = trim_js(@utf8.decode_lossy(err.to_bytes()))
          let code_text = match code {
            Some(c) => c.to_string()
            None => "null"
          }
          ignore(d.fail(fail(if said != "" { said } else { "adb ended with \{code_text}" })))
        }
      },
    },
    env=Some(env),
    r=Some(r),
  )
  stop.val = (io.clock.after)(ADB_TIMEOUT, () => (child.kill)("SIGTERM"))
  d.wait()
}

///|
/// What a socket says first, the socket paused after it; none when it ends without a word.
async fn first_of(s : Sock) -> Bytes? {
  let d : @effect.Deferred[Bytes?] = @effect.Deferred::new()
  let ids : Array[Int] = []
  let settled = (first : Bytes?) => {
    s.pause()
    for id in ids {
      s.off(id)
    }
    ignore(d.succeed(first))
  }
  ids.push(s.on_data(b => settled(Some(b))))
  ids.push(s.on_close(() => settled(None)))
  ids.push(s.on_error(_ => settled(None)))
  d.wait()
}

///|
/// What scrcpy is run with for a view.
pub(all) struct ViewArgs {
  max_side : Int
  bitrate : Int
  fps : Double?
  wake : Bool
}

///|
/// The side a view asks scrcpy for: what it asked, or for one to drive at least what stays sharp as its window grows.
pub fn side_of(options : ViewOptions) -> Int {
  let asked = js_max(options.max_width, options.max_height)
  // (a multiple of 8, as encoders take)
  to_int32(js_min(MOST_SIDE, if options.peek { asked } else { js_max(LEAST_SIDE, asked) })) & -8
}

///|
/// What scrcpy is run with for a view: its side, its rate by that side, its frames a second as asked (none: 60), its
/// screen turned on to drive. A preview: PEEK_FPS and PEEK_BITRATE at the card's size, the screen left as it is.
pub fn view_args(options : ViewOptions) -> ViewArgs {
  let max_side = side_of(options)
  if options.peek {
    return { max_side, bitrate: PEEK_BITRATE, fps: Some(PEEK_FPS.to_double()), wake: false }
  }
  { max_side, bitrate: bitrate_of(max_side), fps: options.fps, wake: true }
}

///|
/// One view: a run of scrcpy's program on the device, with its tunnel (android.ts `AndroidView`). A still screen sends
/// nothing.
pub struct AndroidView {
  priv io : Io
  priv adb : Adb
  priv gone : () -> Unit
  priv sized : ((Double, Double)) -> Unit
  priv input_ : AndroidInput
  priv mut server : Child?
  priv mut video_ : Sock?
  priv mut control : Sock?
  priv mut port : Int
  priv mut ended : Bool
  priv mut size : (Double, Double)
  priv mut config : FrameConfig?
  priv mut dropping : Bool
  priv mut last_ts : Double
  priv queue : Array[Frame]
  priv waiting : Array[(Frame?) -> Unit]
}

///|
pub fn AndroidView::new(io : Io, adb : Adb, gone : () -> Unit, sized : ((Double, Double)) -> Unit) -> AndroidView {
  {
    io,
    adb,
    gone,
    sized,
    input_: AndroidInput::new(),
    server: None,
    video_: None,
    control: None,
    port: 0,
    ended: false,
    size: (0.0, 0.0),
    config: None,
    dropping: false,
    last_ts: 0.0,
    queue: [],
    waiting: [],
  }
}

///|
/// Puts the program on the device, runs it and connects (its file taken off again once it runs).
pub async fn AndroidView::start(self : AndroidView, file : String, options : ViewArgs) -> Unit {
  let hex = (self.io.random_int)(1, 0x7fffffff).to_string(radix=16)
  let pad = StringBuilder()
  for _ in hex.length()..<8 {
    pad.write_char('0')
  }
  let scid = pad.to_string() + hex
  let jar = "/data/local/tmp/stillfail-scrcpy-\{scid}.jar"
  let name = "localabstract:scrcpy_\{scid}"
  ignore((self.adb.run)(["push", file, jar]))
  let port = js_number(trim_js((self.adb.run)(["forward", "tcp:0", name])))
  if !is_integer(port) || port <= 0.0 {
    raise fail("adb gave no port for the view")
  }
  self.port = port.to_int()
  let args = [
    "scid=\{scid}",
    "log_level=warn",
    "audio=false",
    "control=true",
    "tunnel_forward=true",
    "cleanup=false",
    "video_codec=h264",
    "max_size=\{options.max_side}",
    "video_bit_rate=\{options.bitrate}",
    "max_fps=\{num_text(options.fps.unwrap_or(60.0))}",
    "power_on=\{options.wake}",
  ]
  let said = Buffer()
  let server = (self.adb.shell)(
    "CLASSPATH=\{jar} app_process / com.genymobile.scrcpy.Server \{SERVER_VERSION} \{args.join(" ")}",
    {
      out: b => said.write_bytes(b),
      err: b => said.write_bytes(b),
      error: _ => (),
      close: (_, _) => {
        if !self.ended {
          self.io.log.warn(
            "screens",
            "an Android view's program ended",
            fields=jo([("said", js(slice_units(@utf8.decode_lossy(said.to_bytes()), 0, 500)))]),
          )
        }
        self.close()
      },
    },
  )
  self.server = Some(server)
  let said_text = () => trim_js(@utf8.decode_lossy(said.to_bytes()))
  // (a forward tunnel takes a connection before anything listens: the byte the program sends first says it does)
  let until = self.io.clock.ms() + CONNECT_TIMEOUT
  while self.video_ is None {
    if self.ended {
      raise fail(if said_text() != "" { said_text() } else { "the view's program ended" })
    }
    if self.io.clock.ms() > until {
      raise fail(if said_text() != "" { said_text() } else { "the view's program did not start" })
    }
    let socket = Some(dial(self.io, Tcp(self.port))) catch { _ => None }
    let first = match socket {
      Some(s) => first_of(s)
      None => None
    }
    match (socket, first) {
      (Some(socket), Some(first)) => {
        self.video_ = Some(socket)
        let stream = ScrcpyStream::new(size => self.session(size), p => self.packet(p))
        ignore(socket.on_data(d => stream.heard(d)))
        ignore(socket.on_error(_ => self.close()))
        ignore(socket.on_close(() => self.close()))
        stream.heard(first)
        socket.flow_again()
      }
      _ => {
        match socket {
          Some(s) => s.destroy()
          None => ()
        }
        self.io.clock.sleep(100.0)
      }
    }
  }
  let control = dial(self.io, Tcp(self.port))
  // (what it answers, a clipboard's change, nobody here asks)
  ignore(control.on_data(_ => ()))
  ignore(control.on_error(_ => self.close()))
  self.control = Some(control)
  self.io.go(async fn() { ignore((self.adb.run)(["shell", "rm -f \{jar}"])) })
}

///|
fn AndroidView::session(self : AndroidView, size : (Double, Double)) -> Unit {
  self.size = size
  (self.sized)(size)
}

///|
fn AndroidView::packet(self : AndroidView, p : ScrcpyPacket) -> Unit {
  let nals = nals_of(p.data)
  if p.config {
    match avcc_config_of(nals) {
      Some(description) =>
        self.config = Some({ codec: H264, width: self.size.0, height: self.size.1, description: Some(description), region: None })
      None => ()
    }
    return
  }
  if self.dropping && !p.key {
    return
  }
  self.dropping = false
  // Rising, whatever a new capture's clock starts from.
  let ts = js_max(self.last_ts + 1.0, p.pts.to_double())
  self.last_ts = ts
  let frame = { config: if p.key { self.config } else { None }, key: p.key, ts, data: avcc_of(nals) }
  if p.key {
    self.config = None
  }
  if self.waiting.length() > 0 {
    (self.waiting.remove(0))(Some(frame))
    return
  }
  self.queue.push(frame)
  if self.queue.length() > QUEUE_MOST {
    // (the new capture says its config again)
    self.queue.clear()
    self.dropping = true
    self.keyframe()
  }
}

///|
pub async fn AndroidView::next(self : AndroidView) -> Frame? {
  if self.ended {
    return None
  }
  if self.queue.length() > 0 {
    return Some(self.queue.remove(0))
  }
  let d : @effect.Deferred[Frame?] = @effect.Deferred::new()
  self.waiting.push(f => ignore(d.succeed(f)))
  d.wait()
}

///|
pub fn AndroidView::keyframe(self : AndroidView) -> Unit {
  match self.control {
    Some(c) => c.write(Bytes::from_array([CONTROL_RESET.to_byte()]))
    None => ()
  }
}

///|
pub async fn AndroidView::input(self : AndroidView, event : ScreenInput) -> Unit {
  // Turned by the window manager, the picture's new shape following from scrcpy.
  if event is Device("rotate") {
    ignore((self.adb.run)(["shell", ROTATE])) catch {
      _ => ()
    }
    return
  }
  if self.size.0 == 0.0 {
    return
  }
  for m in self.input_.messages(event, self.size) {
    match self.control {
      Some(c) => c.write(m)
      None => ()
    }
  }
}

///|
pub fn AndroidView::video(self : AndroidView) -> ScreenVideo {
  ignore(self)
  { capture: "scrcpy", encoder: None, hardware: None }
}

///|
pub fn AndroidView::close(self : AndroidView) -> Unit {
  if self.ended {
    return
  }
  self.ended = true
  match self.video_ {
    Some(s) => s.destroy()
    None => ()
  }
  match self.control {
    Some(s) => s.destroy()
    None => ()
  }
  match self.server {
    Some(s) => (s.kill)("SIGTERM")
    None => ()
  }
  if self.port > 0 {
    let port = self.port
    self.io.go(async fn() { ignore((self.adb.run)(["forward", "--remove", "tcp:\{port}"])) })
  }
  for w in self.waiting.copy() {
    w(None)
  }
  self.waiting.clear()
  (self.gone)()
}

///|
pub fn AndroidView::view(self : AndroidView) -> ScreenView {
  {
    ..ScreenView::bare(async fn() { self.next() }, () => self.keyframe(), async fn(e) { self.input(e) }, () => self.close()),
    video: Some(() => self.video()),
  }
}

///|
/// The previews running of a machine's devices, PEEKS_MOST at most.
pub struct PeekCount {
  priv mut running : Int
  priv most : Int
}

///|
pub fn PeekCount::new(most? : Int = PEEKS_MOST) -> PeekCount {
  { running: 0, most }
}

///|
/// One more starts, unless as many as can run already do.
pub fn PeekCount::take(self : PeekCount) -> Bool {
  if self.running >= self.most {
    return false
  }
  self.running += 1
  true
}

///|
pub fn PeekCount::free(self : PeekCount) -> Unit {
  self.running = if self.running - 1 < 0 { 0 } else { self.running - 1 }
}

///|
pub fn PeekCount::running(self : PeekCount) -> Int {
  self.running
}

///|
/// One device on adb (android.ts `AndroidScreen`).
pub struct AndroidScreen {
  id : String
  panels : Array[Panel]
  priv io : Io
  priv title_ : String
  priv adb : Adb
  priv file : String
  priv changed : () -> Unit
  priv views : Array[AndroidView]
  priv peeks : PeekCount
  /// An emulator's start (ms); none: a phone.
  priv since_ : Double?
  priv mut size_ : (Double, Double)
  priv emulator : Bool
}

///|
pub fn AndroidScreen::new(
  io : Io,
  id : String,
  title : String,
  size : (Double, Double),
  panels : Array[Panel],
  adb : Adb,
  file : String,
  changed : () -> Unit,
  peeks? : PeekCount? = None,
  emulator_since? : Double? = None,
) -> AndroidScreen {
  {
    id,
    panels,
    io,
    title_: title,
    adb,
    file,
    changed,
    views: [],
    peeks: peeks.unwrap_or(PeekCount::new()),
    since_: emulator_since,
    size_: size,
    emulator: emulator_since is Some(_),
  }
}

///|
pub fn AndroidScreen::title(self : AndroidScreen) -> String {
  self.title_
}

///|
pub fn AndroidScreen::since(self : AndroidScreen) -> Double? {
  self.since_
}

///|
pub fn AndroidScreen::size(self : AndroidScreen) -> (Double, Double) {
  self.size_
}

///|
/// An emulator closed from a person's app: it leaves adb, and the list.
pub async fn AndroidScreen::discard(self : AndroidScreen) -> Unit {
  ignore((self.adb.run)(["emu", "kill"]))
}

///|
pub async fn AndroidScreen::open(self : AndroidScreen, options : ViewOptions) -> AndroidView {
  if !options.codecs.contains(H264) {
    raise self.io.refused(415, "station.screen.codec", args=jo([("codec", js("H.264"))]))
  }
  let peek = options.peek
  if peek && !self.peeks.take() {
    raise self.io.refused(503, "station.screen.failed", args=jo([("said", js("at most \{PEEKS_MOST} Android screens are previewed at once"))]))
  }
  let view_ref : Ref[AndroidView?] = Ref(None)
  let view = AndroidView::new(
    self.io,
    self.adb,
    () => {
      match view_ref.val {
        Some(v) =>
          match self.views.search_by(x => physical_equal(x, v)) {
            Some(i) => ignore(self.views.remove(i))
            None => ()
          }
        None => ()
      }
      if peek {
        self.peeks.free()
      }
    },
    size => {
      // Turned or unfolded: its shape as the listing has it.
      if abs_d(size.0 / size.1 - self.size_.0 / self.size_.1) < SAME_SHAPE {
        return
      }
      self.size_ = size
      (self.changed)()
    },
  )
  view_ref.val = Some(view)
  self.views.push(view)
  try {
    view.start(self.file, view_args(options))
    view
  } catch {
    error => {
      view.close()
      self.io.log.warn("screens", "an Android view did not open", fields=jo([("id", js(self.id)), ("error", js(message_of(error)))]))
      raise self.io.refused(503, "station.screen.failed", args=jo([("said", js(message_of(error)))]))
    }
  }
}

///|
/// It left adb (or the station stops): its views end.
pub fn AndroidScreen::gone(self : AndroidScreen) -> Unit {
  for v in self.views.copy() {
    v.close()
  }
}

///|
pub fn AndroidScreen::source(self : AndroidScreen) -> ScreenSource {
  {
    ..ScreenSource::bare(self.id, SimulatorKind, () => self.title(), () => self.size(), async fn(o) { self.open(o).view() }),
    peek: true,
    panels: Some(self.panels),
    since: Some(() => self.since()),
    discard: if self.emulator { Some(async fn() { self.discard() }) } else { None },
  }
}

///|
/// When the emulator of `serial` (`emulator-<port>`) started (ms): its qemu's start, where `ps` says it.
pub async fn emulator_start(io : Io, serial : String, ps? : (async () -> String)? = None) -> Double? {
  guard serial.has_prefix("emulator-") else { return None }
  let port = serial.unsafe_substring(start=9, end=serial.length())
  if port == "" || !port.iter().all(c => c >= '0' && c <= '9') || io.os.os == "windows" {
    return None
  }
  let ps = ps.unwrap_or(async fn() { ps_starts(io) })
  let lines = ps() catch { _ => "" }
  start_of(io, lines, port)
}

///|
/// The start of the qemu run with `-port <port>` in `ps -Ao lstart=,args=`'s lines (its start the first five words, a
/// local time: `Fri Nov  6 16:34:52 2026`).
pub fn start_of(io : Io, lines : String, port : String) -> Double? {
  for line in lines.split("\n") {
    let words = split_space(trim_js(line.to_string()))
    let args = if words.length() > 5 { words[5:].to_array() } else { [] }
    guard args.search("-port") is Some(at) else { continue }
    if at + 1 >= args.length() || args[at + 1] != port {
      continue
    }
    let first = if args.length() > 0 { args[0] } else { "" }
    if !(first.contains("qemu-system") || first.contains("emulator")) {
      continue
    }
    let t = (io.os.date_parse)(words[0:if words.length() < 5 { words.length() } else { 5 }].to_array().join(" "))
    if t.is_finite() {
      return Some(t)
    }
  }
  None
}

///|
async fn ps_starts(io : Io) -> String {
  (io.procs.exec)("ps", ["-Ao", "lstart=,args="], ExecOptions::new(timeout=Some(10000.0), max_buffer=Some((16 << 20).to_double())))
}

///|
/// Whether a device on adb is a screen: an emulator, a phone on USB or one someone connected to by its address. Not one
/// adb found on the network by itself, nor one lent through a member link.
pub fn shown_device(serial : String) -> Bool {
  !serial.contains("._adb") && !serial.has_prefix("127.0.0.1:")
}

///|
/// What `adb track-devices -l` says each time: the devices ready to use.
pub fn devices_of(lines : String) -> Array[String] {
  let out = []
  for line in lines.split("\n") {
    let words = split_space(trim_js(line.to_string()))
    let serial = words[0]
    if serial != "" && words.length() > 1 && words[1] == "device" {
      out.push(serial)
    }
  }
  out
}

///|
/// `\b<word> (\d+) x (\d+)` and the like: the numbers after `word` at a word's start.
fn after_word(line : String, word : String) -> Int? {
  let mut from = 0
  while true {
    let i = match line.unsafe_substring(start=from, end=line.length()).find(word) {
      Some(i) => from + i
      None => return None
    }
    from = i + 1
    if i > 0 {
      let c = line.unsafe_get(i - 1).to_int()
      let wordy = (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
        (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
        (c >= '0'.to_int() && c <= '9'.to_int()) ||
        c == '_'.to_int()
      if wordy {
        continue
      }
    }
    return Some(i + word.length())
  }
  None
}

///|
/// The panels of `dumpsys display`: each display's size and its corners' radii as shares of its width, top left and
/// then round it; one with no rounded corners is left out.
pub fn panels_of(dumpsys : String) -> Array[Panel] {
  let out : Map[String, Panel] = Map::new()
  for l in dumpsys.split("\n") {
    let line = l.to_string()
    if !line.contains("mBaseDisplayInfo=") {
      continue
    }
    // /\breal (\d+) x (\d+)/
    let mut real = None
    let mut from = 0
    while real is None {
      let rest = line.unsafe_substring(start=from, end=line.length())
      guard after_word(rest, "real ") is Some(at) else { break }
      let r = Reader::new(rest, at)
      from = from + at - 4
      match r.digits() {
        Some(w) if r.eat(' ') && r.eat('x') && r.eat(' ') =>
          match r.digits() {
            Some(h) => real = Some((w, h))
            None => ()
          }
        _ => ()
      }
    }
    // /roundedCorners RoundedCorners\{\[(.*?)\]\}/
    let rounded = match line.find("roundedCorners RoundedCorners{[") {
      Some(i) => {
        let start = i + "roundedCorners RoundedCorners{[".length()
        match line.unsafe_substring(start~, end=line.length()).find("]}") {
          Some(j) => Some(line.unsafe_substring(start~, end=start + j))
          None => None
        }
      }
      None => None
    }
    guard real is Some((ws, hs)) && rounded is Some(rounded) else { continue }
    let width = js_number(ws)
    let height = js_number(hs)
    let radius = (position : String) => {
      let marker = "position=\{position}, radius="
      match rounded.find(marker) {
        Some(i) => {
          let r = Reader::new(rounded, i + marker.length())
          match r.digits() {
            Some(d) => js_number(d) / width
            None => 0.0 / width
          }
        }
        None => 0.0 / width
      }
    }
    let corners = [radius("TopLeft"), radius("TopRight"), radius("BottomRight"), radius("BottomLeft")]
    if width > 0.0 && corners.iter().any(c => c > 0.0) {
      out["\{num_text(width)}x\{num_text(height)}"] = { width, height, corners }
    }
  }
  out.values().collect()
}

///|
/// `wm size`'s answer: the size overriding the physical one where there is one.
pub fn size_of(wm : String) -> (Double, Double) {
  let of = (word : String) => {
    let marker = "\{word} size: "
    let mut from = 0
    while true {
      let i = match wm.unsafe_substring(start=from, end=wm.length()).find(marker) {
        Some(i) => from + i
        None => return None
      }
      from = i + 1
      let r = Reader::new(wm, i + marker.length())
      match r.digits() {
        Some(w) if r.eat('x') =>
          match r.digits() {
            Some(h) => return Some((js_number(w), js_number(h)))
            None => ()
          }
        _ => ()
      }
    }
    None
  }
  match of("Override") {
    Some(s) => s
    None => of("Physical").unwrap_or((0.0, 0.0))
  }
}

///|
/// `parseInt(s, 16)`: the hex digits it starts with (after white space, a sign, `0x`); NaN where there are none.
fn parse_int_hex(s : String) -> Double {
  let cs = s.to_array()
  let mut i = 0
  while i < cs.length() && is_js_space(cs[i]) {
    i += 1
  }
  let mut sign = 1.0
  if i < cs.length() && (cs[i] == '-' || cs[i] == '+') {
    if cs[i] == '-' {
      sign = -1.0
    }
    i += 1
  }
  if i + 1 < cs.length() && cs[i] == '0' && (cs[i + 1] == 'x' || cs[i + 1] == 'X') {
    i += 2
  }
  let mut v = 0.0
  let mut any = false
  while i < cs.length() {
    let c = cs[i]
    let d = if c >= '0' && c <= '9' {
      c.to_int() - '0'.to_int()
    } else if c >= 'a' && c <= 'f' {
      c.to_int() - 'a'.to_int() + 10
    } else if c >= 'A' && c <= 'F' {
      c.to_int() - 'A'.to_int() + 10
    } else {
      break
    }
    v = v * 16.0 + d.to_double()
    any = true
    i += 1
  }
  if any {
    sign * v
  } else {
    @double.not_a_number
  }
}

///|
/// The devices on this machine's adb, each a screen while it is on it (android.ts `AndroidScreens`). A machine without
/// adb lists none.
pub struct AndroidScreens {
  priv io : Io
  priv add : (ScreenSource) -> (() -> Unit)
  priv changed : () -> Unit
  priv adb : () -> String?
  priv file : String
  priv listed : Map[String, (String, AndroidScreen, () -> Unit)]
  priv peeks : PeekCount
  priv mut follow : Child?
  priv mut again : (() -> Unit)?
  priv mut closed : Bool
  priv mut serials : Array[String]
  priv looking : Chain
  priv mut look_again : (() -> Unit)?
  priv again_ms : Double
  priv mut rest : (() -> Unit)?
  priv mut resting : Bool
}

///|
pub fn AndroidScreens::new(
  io : Io,
  add : (ScreenSource) -> (() -> Unit),
  changed : () -> Unit,
  adb : () -> String?,
  file? : String? = None,
  look_again? : Double? = None,
) -> AndroidScreens {
  {
    io,
    add,
    changed,
    adb,
    file: file.unwrap_or(server_file(io)),
    listed: {},
    peeks: PeekCount::new(),
    follow: None,
    again: None,
    closed: false,
    serials: [],
    looking: Chain::new(),
    look_again: None,
    again_ms: look_again.unwrap_or(LOOK_AGAIN),
    rest: None,
    resting: false,
  }
}

///|
pub fn AndroidScreens::start(self : AndroidScreens) -> Unit {
  self.resting = false
  if self.closed || self.follow is Some(_) {
    return
  }
  guard (self.adb)() is Some(path) else { return }
  let carry = Ref("")
  let child = adb_spawn(self.io, path, ["track-devices", "-l"], {
    out: d => {
      carry.val = carry.val + @utf8.decode_lossy(d)
      while true {
        let length = parse_int_hex(slice_units(carry.val, 0, 4))
        if !is_integer(length) || units_len(carry.val).to_double() < 4.0 + length {
          return
        }
        let n = length.to_int()
        self.heard(path, devices_of(slice_units(carry.val, 4, 4 + n)))
        carry.val = slice_units(carry.val, 4 + n, units_len(carry.val))
      }
    },
    err: _ => (),
    error: _ => (),
    close: (_, _) => {
      self.follow = None
      if self.closed || self.resting {
        return
      }
      match self.again {
        Some(f) => f()
        None => ()
      }
      self.again = Some((self.io.clock.after)(FOLLOW_AGAIN, () => self.start()))
    },
  })
  self.follow = Some(child)
}

///|
/// As the screens are asked for: adb may have come since.
pub async fn AndroidScreens::refresh(self : AndroidScreens) -> Unit {
  self.start()
  match self.rest {
    Some(f) => f()
    None => ()
  }
  self.rest = Some((self.io.clock.after)(FOLLOWED_FOR, () => self.stop_following()))
  self.looking.idle()
}

///|
/// Not asked for in a while: adb's devices let go of while none is listed.
fn AndroidScreens::stop_following(self : AndroidScreens) -> Unit {
  self.rest = None
  if self.closed {
    return
  }
  if self.listed.length() > 0 {
    self.rest = Some((self.io.clock.after)(FOLLOWED_FOR, () => self.stop_following()))
    return
  }
  self.resting = true
  match self.again {
    Some(f) => f()
    None => ()
  }
  self.again = None
  match self.follow {
    Some(c) => (c.kill)("SIGTERM")
    None => ()
  }
}

///|
fn AndroidScreens::heard(self : AndroidScreens, path : String, serials : Array[String]) -> Unit {
  self.serials = serials
  self.looking.after(self.io, async fn() {
    self.look(path) catch {
      e => self.io.log.warn("screens", "looking at adb's devices failed", fields=jo([("error", js(message_of(e)))]))
    }
  })
}

///|
async fn AndroidScreens::look(self : AndroidScreens, path : String) -> Unit {
  let serials = self.serials.filter(shown_device)
  for serial in self.listed.keys().collect() {
    if serials.contains(serial) {
      continue
    }
    let (_, source, remove) = self.listed.get(serial).unwrap()
    self.listed.remove(serial)
    remove()
    source.gone()
  }
  let mut unseen = false
  for serial in serials {
    if self.closed || self.listed.contains(serial) {
      continue
    }
    // (a phone both on USB and over Wi-Fi: the one screen)
    let source = Some(self.screen(path, serial)) catch {
      e => {
        unseen = true
        self.io.log.info("screens", "an Android device could not be looked at yet", fields=jo([("serial", js(serial)), ("error", js(message_of(e)))]))
        None
      }
    }
    guard source is Some(source) else { continue }
    if self.listed.values().any(l => l.0 == source.id) {
      continue
    }
    if self.closed || !self.serials.contains(serial) {
      continue
    }
    self.listed[serial] = (source.id, source, (self.add)(source.source()))
  }
  match self.look_again {
    Some(f) => f()
    None => ()
  }
  self.look_again = if unseen && !self.closed {
    let serials = self.serials
    Some((self.io.clock.after)(self.again_ms, () => self.heard(path, serials)))
  } else {
    None
  }
}

///|
async fn AndroidScreens::screen(self : AndroidScreens, path : String, serial : String) -> AndroidScreen {
  let adb = adb_of(self.io, path, serial)
  // (what is asked below is not there until it has booted)
  if trim_js((adb.run)(["shell", "getprop sys.boot_completed"])) != "1" {
    raise fail("still booting")
  }
  let emulator = serial.has_prefix("emulator-")
  let props = (adb.run)(["shell", "getprop ro.serialno; getprop ro.product.model; getprop ro.build.version.release; settings get global device_name"])
  let lines = props.split("\n").map(l => trim_js(l.to_string())).collect()
  let line = (i : Int) => if i < lines.length() { Some(lines[i]) } else { None }
  let serialno = line(0)
  let model = line(1)
  let release = line(2)
  let named = line(3)
  let avd = if emulator {
    let said = (adb.run)(["emu", "avd", "name"]) catch { _ => "" }
    trim_js(said.split("\n").map(v => v.to_string()).collect()[0])
  } else {
    ""
  }
  let name = if avd != "" {
    avd
  } else {
    let chosen = match named {
      Some(n) if n != "" && n != "null" => Some(n)
      _ => model
    }
    match chosen {
      Some(c) if c != "" => c
      _ => serial
    }
  }
  // (emulators all have one ro.serialno, a phone keeps its own however it is connected)
  let id = "android:\{if emulator || serialno.unwrap_or("") == "" { serial } else { serialno.unwrap() }}"
  let size = size_of((adb.run)(["shell", "wm size"]))
  let panels = panels_of((adb.run)(["shell", "dumpsys display"]) catch { _ => "" })
  let since = if emulator {
    match emulator_start(self.io, serial) {
      Some(t) => Some(t)
      None => Some(self.io.clock.ms())
    }
  } else {
    None
  }
  AndroidScreen::new(
    self.io,
    id,
    "\{name} · Android \{release.unwrap_or("undefined")}",
    size,
    panels,
    adb,
    self.file,
    () => (self.changed)(),
    peeks=Some(self.peeks),
    emulator_since=since,
  )
}

///|
/// The station stopping: nothing followed, every source gone.
pub fn AndroidScreens::close(self : AndroidScreens) -> Unit {
  self.closed = true
  for f in [self.rest, self.again, self.look_again] {
    match f {
      Some(f) => f()
      None => ()
    }
  }
  match self.follow {
    Some(c) => (c.kill)("SIGTERM")
    None => ()
  }
  for l in self.listed.values() {
    (l.2)()
    l.1.gone()
  }
  self.listed.clear()
}
