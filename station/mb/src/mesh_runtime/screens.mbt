// A view of one of the station's screens over a member's link (station/src/mesh/screens.ts), its wire: a stream whose
// head line has a `screen` object, answered 200 `application/x-stillfail-screen`, then frames both ways, each a kind
// byte, its payload's length (4 bytes, big-endian) and the payload. Here: the frames written and read, what a view's
// ask says, and each frame a client sends checked (its input, its clipboard, its look); the pace is screen_pace.mbt's.

///|
pub let screen_type : String = "application/x-stillfail-screen"

///|
pub let kind_config : Int = 1

///|
pub let kind_video : Int = 2

///|
pub let kind_state : Int = 3

///|
pub let kind_clipboard : Int = 4

///|
pub let kind_audio_config : Int = 5

///|
pub let kind_audio : Int = 6

///|
pub let kind_input : Int = 16

///|
pub let kind_ack : Int = 17

///|
pub let kind_keyframe : Int = 18

///|
pub let kind_set_clipboard : Int = 19

///|
pub let kind_look : Int = 20

///|
pub let kind_sound : Int = 21

///|
/// A client's frame is an input event at most: one larger ends the view.
pub let max_in : Int = 64 * 1024

///|
pub let clip_text_max : Int = 1024 * 1024

///|
pub let clip_png_max : Int = 8 * 1024 * 1024

///|
/// A client's `clipboard` frame is its flags, its type and a picture at most.
pub let max_clip_in : Int = 2 + clip_png_max

///|
/// How large a client's frame of a kind may be.
pub fn limit_in(kind : Int) -> Int {
  if kind == kind_set_clipboard {
    max_clip_in
  } else {
    max_in
  }
}

///|
pub let look_least : Double = 0.02

///|
pub let look_whole : Double = 0.98

///|
let codecs : Array[String] = ["h265", "h264", "jpeg"]

///|
/// A frame: its kind, its payload's length (big-endian) and the payload.
pub fn frame(kind : Int, payload : Bytes) -> Bytes {
  let b = @buffer.Buffer(size_hint=5 + payload.length())
  b.write_byte(kind.to_byte())
  b.write_uint_be(payload.length().reinterpret_as_uint())
  b.write_bytes(payload)
  b.to_bytes()
}

///|
/// A part of the screen (`Region`), each in 0..1.
#derive(Eq, Debug)
pub(all) struct Region {
  x : Double
  y : Double
  w : Double
  h : Double
}

///|
pub fn Region::to_json(self : Region) -> Json {
  jobj([("x", jnum(self.x)), ("y", jnum(self.y)), ("w", jnum(self.w)), ("h", jnum(self.h))])
}

///|
/// A part of the screen as a look or a source says it, checked (screens/source.ts `regionOf`): within the screen, at
/// least LOOK_LEAST each way; None for the whole.
pub fn region_of(v : Json?) -> Region? {
  guard v is Some(Object(m)) else { return None }
  guard finite(m.get("x")) is Some(vx) &&
    finite(m.get("y")) is Some(vy) &&
    finite(m.get("w")) is Some(vw) &&
    finite(m.get("h")) is Some(vh) else {
    return None
  }
  let w = dmin(1.0, dmax(look_least, vw))
  let h = dmin(1.0, dmax(look_least, vh))
  if w >= look_whole && h >= look_whole {
    return None
  }
  let x = dmin(1.0 - w, dmax(0.0, vx))
  let y = dmin(1.0 - h, dmax(0.0, vy))
  let r4 = (n : Double) => js_round(n * 10_000.0) / 10_000.0
  Some({ x: r4(x), y: r4(y), w: r4(w), h: r4(h) })
}

///|
/// A `config` frame's payload: `{codec, width, height, description?, region?}`.
pub fn config_payload(codec : String, width : Double, height : Double, description : Bytes?, region : Region?) -> Bytes {
  let fields = [("codec", jstr(codec)), ("width", jnum(width)), ("height", jnum(height))]
  // (an empty description is one: `c.description` of no bytes is still an object)
  if description is Some(d) {
    fields.push(("description", jstr(@base64.encode(d[:]))))
  }
  if region is Some(r) {
    fields.push(("region", r.to_json()))
  }
  @utf8.encode(js_stringify(jobj(fields)))
}

///|
/// A `video` frame's payload: whether it is a key frame, its timestamp (big-endian, 8 bytes) and its data.
pub fn video_payload(key : Bool, ts : Double, data : Bytes) -> Bytes {
  let b = @buffer.Buffer(size_hint=9 + data.length())
  b.write_byte(if key { b'\x01' } else { b'\x00' })
  let t = dmax(0.0, ts.floor())
  b.write_uint64_be(t.to_uint64())
  b.write_bytes(data)
  b.to_bytes()
}

///|
/// A clip of the clipboard: words, or a PNG picture.
#derive(Eq, Debug)
pub(all) enum Clip {
  Text(String)
  Png(Bytes)
}

///|
/// Whether a clip is within its bounds (screens/source.ts `clipFits`).
pub fn clip_fits(clip : Clip) -> Bool {
  match clip {
    Text(t) => t != "" && @utf8.encode(t).length() <= clip_text_max
    Png(d) => d.length() > 0 && d.length() <= clip_png_max
  }
}

///|
/// A clip as a `clipboard` frame's payload has it after its flags (station → client: none): its type byte, its bytes.
pub fn clip_payload(clip : Clip, flags? : Int? = None) -> Bytes {
  let (kind, body) = match clip {
    Text(t) => (1, @utf8.encode(t))
    Png(d) => (2, d)
  }
  let b = @buffer.Buffer(size_hint=2 + body.length())
  if flags is Some(f) {
    b.write_byte(f.to_byte())
  }
  b.write_byte(kind.to_byte())
  b.write_bytes(body)
  b.to_bytes()
}

///|
/// A client's `clipboard` frame: the clip (within its bounds) and whether to paste it; None when it is none.
pub fn parse_clip(payload : Bytes) -> (Clip, Bool)? {
  if payload.length() < 3 {
    return None
  }
  let paste = (payload[0].to_int() & 1) == 1
  let body = @door.own(payload[2:])
  let clip = match payload[1].to_int() {
    1 => Text(@utf8.decode_lossy(body[:], ignore_bom=false))
    2 => Png(body)
    _ => return None
  }
  if clip_fits(clip) {
    Some((clip, paste))
  } else {
    None
  }
}

///|
fn int_field(m : Map[String, Json], k : String) -> Double? {
  match m.get(k) {
    Some(Number(n, ..)) if js_is_integer(n) => Some(n)
    _ => None
  }
}

///|
fn input_of(v : Json, t : String) -> Map[String, Json]? {
  match v {
    Object(m) if m.get("t") is Some(String(s)) && s == t => Some(m)
    _ => None
  }
}

///|
/// What a client's input frame asks of the display's scale (`{t: "scale", percent}`).
pub fn parse_scale(v : Json) -> Double? {
  guard input_of(v, "scale") is Some(m) && int_field(m, "percent") is Some(p) && p >= 100.0 && p <= 500.0 else {
    return None
  }
  Some(p)
}

///|
/// What a client's input frame asks of the display's resolution (`{t: "resolution", width, height}`).
pub fn parse_resolution(v : Json) -> (Double, Double)? {
  guard input_of(v, "resolution") is Some(m) else { return None }
  let side = (k : String) => match int_field(m, k) {
    Some(n) if n >= 640.0 && n <= 16384.0 => Some(n)
    _ => None
  }
  guard side("width") is Some(w) && side("height") is Some(h) else { return None }
  Some((w, h))
}

///|
/// What a client's input frame asks of the file manager (`{t: "reveal", path}`).
pub fn parse_reveal(v : Json) -> String? {
  guard input_of(v, "reveal") is Some(m) && m.get("path") is Some(String(p)) && p != "" && p.length() <= 4096 else {
    return None
  }
  Some(p)
}

///|
/// What a client's input frame fills a login form with (`{t: "fill", host, username?, password?}`), as JSON.
pub fn parse_fill(v : Json) -> Json? {
  guard input_of(v, "fill") is Some(m) &&
    m.get("host") is Some(String(host)) &&
    host != "" &&
    host.length() <= 253 else {
    return None
  }
  let word = (x : Json?) => match x {
    None => true
    Some(String(s)) => s.length() <= 1024
    _ => false
  }
  let username = m.get("username")
  let password = m.get("password")
  if !word(username) || !word(password) || (username is None && password is None) {
    return None
  }
  let out = [("host", jstr(host))]
  if username is Some(u) {
    out.push(("username", u))
  }
  if password is Some(p) {
    out.push(("password", p))
  }
  Some(jobj(out))
}

///|
fn letters(s : String, most : Int) -> Bool {
  s.length() >= 1 && s.length() <= most && s.iter().all(c => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
}

///|
fn b64url(x : Json?, most? : Int = 8192) -> Bool {
  match x {
    Some(String(s)) =>
      s != "" &&
      s.length() <= most &&
      s.iter().all(c => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-')
    _ => false
  }
}

///|
/// What a client's input frame answers a page's passkey sign-in with, as JSON.
pub fn parse_passkey(v : Json) -> Json? {
  guard input_of(v, "passkey") is Some(m) && m.get("id") is Some(String(id)) && id != "" && id.length() <= 32 else {
    return None
  }
  if m.get("error") is Some(e) {
    return match e {
      String(s) if letters(s, 40) => Some(jobj([("id", jstr(id)), ("error", jstr(s))]))
      _ => None
    }
  }
  let opt = (k : String, most : Int) => m.get(k) is None || b64url(m.get(k), most~)
  if !b64url(m.get("credential")) ||
    !b64url(m.get("authenticatorData")) ||
    !b64url(m.get("signature")) ||
    !opt("userHandle", 8192) ||
    !opt("clientData", 49152) {
    return None
  }
  let out = [("id", jstr(id))]
  for k in ["credential", "authenticatorData", "signature", "userHandle", "clientData"] {
    if m.get(k) is Some(x) {
      out.push((k, x))
    }
  }
  Some(jobj(out))
}

///|
/// The JSON a payload's UTF-8 says, as `JSON.parse(payload.toString("utf8"))` reads it; None where it is none.
fn payload_json(payload : Bytes) -> Json? {
  let text = @utf8.decode_lossy(payload[:], ignore_bom=false)
  let v = @jsjson.parse(text) catch { _ => return None }
  Some(json_of(v))
}

///|
/// A value as JavaScript read it, as JSON here.
pub fn json_of(v : @jsjson.JValue) -> Json {
  match v {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => jnum(n)
    Str(s) => jstr(@jsjson.text(s))
    Arr(xs) => Json::array(xs.map(json_of))
    Obj(kvs) => {
      let m : Map[String, Json] = Map([])
      for kv in kvs {
        m[@jsjson.text(kv.0)] = json_of(kv.1)
      }
      Json::object(m)
    }
  }
}

///|
/// A client's `look` frame (`{region, maxWidth, maxHeight}`): the part of the screen it shows (None: the whole) and the
/// bounds its pictures are to fit in; None when it is none.
pub fn parse_look(payload : Bytes, own : Bounds) -> (Region?, Bounds)? {
  guard payload_json(payload) is Some(v) else { return None }
  let m = match v {
    Object(m) => m
    Array(_) => Map([])
    _ => return None
  }
  guard region_of(m.get("region")) is Some(region) else { return Some((None, own)) }
  let bound = (n : Json?, otherwise : Double) => match finite(n) {
    Some(x) => dmin(8192.0, dmax(16.0, js_round(x)))
    None => otherwise
  }
  Some(
    (
      Some(region),
      { max_width: bound(m.get("maxWidth"), own.max_width), max_height: bound(m.get("maxHeight"), own.max_height) },
    ),
  )
}

///|
/// Frames from a stream, after what came with its head line (`FrameIn`).
pub struct FrameIn {
  mut carry : Bytes
  read : async () -> Bytes?
  limit : (Int) -> Int
}

///|
/// `limit`: the largest frame taken by its kind (a client's input frames and its clipboard, by default).
pub fn FrameIn::new(read : async () -> Bytes?, carry? : Bytes = b"", limit? : (Int) -> Int = limit_in) -> FrameIn {
  { carry, read, limit }
}

///|
/// The next frame, or None where the stream finished between frames; raises where it ended inside one, or one is
/// larger than its limit.
pub async fn FrameIn::next(self : FrameIn) -> (Int, Bytes)? {
  while true {
    if self.carry.length() >= 5 {
      let c = self.carry
      let length = (c[1].to_int() << 24) | (c[2].to_int() << 16) | (c[3].to_int() << 8) | c[4].to_int()
      let length = length.reinterpret_as_uint().to_uint64().to_double()
      if length > (self.limit)(c[0].to_int()).to_double() {
        raise Failure("screen frame too large")
      }
      let n = length.to_int()
      if c.length() >= 5 + n {
        let kind = c[0].to_int()
        let payload = @door.own(c[5:5 + n])
        self.carry = @door.own(c[5 + n:])
        return Some((kind, payload))
      }
    }
    match (self.read)() {
      None => {
        if self.carry.length() == 0 {
          return None
        }
        raise Failure("stream ended inside a screen frame")
      }
      Some(more) => self.carry = if self.carry.length() == 0 { more } else { @door.concat([self.carry, more]) }
    }
  }
  None
}

///|
/// A view's pick of one of a desktop's windows (`{t: "window", id}`).
#derive(Eq, Debug)
pub(all) enum WindowPick {
  /// It is no pick (`undefined`).
  NotOne
  /// The whole display (`null`).
  Whole
  Window(Double)
}

///|
pub fn parse_window_pick(v : Json) -> WindowPick {
  guard input_of(v, "window") is Some(m) else { return NotOne }
  match m.get("id") {
    None | Some(Null) => Whole
    Some(Number(n, ..)) if js_is_integer(n) && n > 0.0 && n < 4294967296.0 => Window(n)
    _ => NotOne
  }
}

///|
fn unit(v : Double) -> Double {
  dmin(1.0, dmax(0.0, v))
}

///|
fn str_within(v : Json?, most : Int) -> String? {
  match v {
    Some(String(s)) if s.length() <= most => Some(s)
    _ => None
  }
}

///|
/// `n & mask` of a finite number as JavaScript takes it.
fn masked(n : Double, mask : Int) -> Double {
  (to_int32(n).to_int() & mask).to_double()
}

///|
/// A client's input event, checked, as JSON (`ScreenInput`): None when it is not one.
pub fn parse_input(v : Json) -> Json? {
  guard v is Object(m) else { return None }
  let t = match m.get("t") {
    Some(String(t)) => t
    _ => return None
  }
  match t {
    "pointer" => {
      guard m.get("kind") is Some(String(kind)) && (kind == "down" || kind == "up" || kind == "move") else {
        return None
      }
      guard finite(m.get("x")) is Some(x) && finite(m.get("y")) is Some(y) else { return None }
      let buttons = match finite(m.get("buttons")) {
        Some(b) => masked(b, 7)
        None => 0.0
      }
      Some(jobj([("t", jstr("pointer")), ("kind", jstr(kind)), ("x", jnum(unit(x))), ("y", jnum(unit(y))), ("buttons", jnum(buttons))]))
    }
    "wheel" => {
      guard finite(m.get("x")) is Some(x) &&
        finite(m.get("y")) is Some(y) &&
        finite(m.get("dx")) is Some(dx) &&
        finite(m.get("dy")) is Some(dy) else {
        return None
      }
      let clamp = (d : Double) => dmax(-10_000.0, dmin(10_000.0, d))
      Some(jobj([("t", jstr("wheel")), ("x", jnum(unit(x))), ("y", jnum(unit(y))), ("dx", jnum(clamp(dx))), ("dy", jnum(clamp(dy)))]))
    }
    "key" => {
      guard m.get("kind") is Some(String(kind)) && (kind == "down" || kind == "up") else { return None }
      guard str_within(m.get("key"), 64) is Some(key) && str_within(m.get("code"), 64) is Some(code) else {
        return None
      }
      let mods = match finite(m.get("mods")) {
        Some(b) => masked(b, 15)
        None => 0.0
      }
      Some(jobj([("t", jstr("key")), ("kind", jstr(kind)), ("key", jstr(key)), ("code", jstr(code)), ("mods", jnum(mods))]))
    }
    "text" =>
      match m.get("text") {
        Some(String(s)) if s.length() > 0 && s.length() <= 4096 => Some(jobj([("t", jstr("text")), ("text", jstr(s))]))
        _ => None
      }
    "pose" =>
      match m.get("name") {
        Some(String("closed" | "book" | "open" as name)) => Some(jobj([("t", jstr("pose")), ("name", jstr(name))]))
        _ => None
      }
    "device" =>
      match m.get("name") {
        Some(String("volume_up" | "volume_down" | "memory_warning" | "rotate" as name)) =>
          Some(jobj([("t", jstr("device")), ("name", jstr(name))]))
        _ => None
      }
    "button" => {
      guard int_field(m, "page") is Some(page) &&
        int_field(m, "usage") is Some(usage) &&
        page > 0.0 &&
        page < 65536.0 &&
        usage > 0.0 &&
        usage < 65536.0 else {
        return None
      }
      match m.get("down") {
        Some(True) => Some(jobj([("t", jstr("button")), ("page", jnum(page)), ("usage", jnum(usage)), ("down", Json::boolean(true))]))
        Some(False) => Some(jobj([("t", jstr("button")), ("page", jnum(page)), ("usage", jnum(usage)), ("down", Json::boolean(false))]))
        _ => None
      }
    }
    _ => None
  }
}

///|
/// Whether a code point is a control or a format character (`/[\p{Cc}\p{Cf}]/u`).
pub fn control_or_format(c : Int) -> Bool {
  (c >= 0 && c <= 0x1f) ||
  (c >= 0x7f && c <= 0x9f) ||
  c == 0xad ||
  (c >= 0x600 && c <= 0x605) ||
  c == 0x61c ||
  c == 0x6dd ||
  c == 0x70f ||
  (c >= 0x890 && c <= 0x891) ||
  c == 0x8e2 ||
  c == 0x180e ||
  (c >= 0x200b && c <= 0x200f) ||
  (c >= 0x202a && c <= 0x202e) ||
  (c >= 0x2060 && c <= 0x2064) ||
  (c >= 0x2066 && c <= 0x206f) ||
  c == 0xfeff ||
  (c >= 0xfff9 && c <= 0xfffb) ||
  c == 0x110bd ||
  c == 0x110cd ||
  (c >= 0x13430 && c <= 0x1343f) ||
  (c >= 0x1bca0 && c <= 0x1bca3) ||
  (c >= 0x1d173 && c <= 0x1d17a) ||
  c == 0xe0001 ||
  (c >= 0xe0020 && c <= 0xe007f)
}

///|
/// A word a client says of itself, as far as it is shown (`said`): controls and formats taken out, trimmed, `most` code
/// units at most; None when it said none.
pub fn said_word(v : Json?, most : Int) -> String? {
  guard v is Some(String(s)) else { return None }
  let units : Array[Int] = []
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s.code_unit_at(i).to_int()
    if c >= 0xd800 && c <= 0xdbff && i + 1 < n {
      let d = s.code_unit_at(i + 1).to_int()
      if d >= 0xdc00 && d <= 0xdfff {
        let point = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00)
        if !control_or_format(point) {
          units.push(c)
          units.push(d)
        }
        i += 2
        continue
      }
    }
    if !control_or_format(c) {
      units.push(c)
    }
    i += 1
  }
  let word = js_trim(@jsjson.text(units))
  let cut = if word.length() > most { word.clamped_view(end=most).to_owned() } else { word }
  if cut == "" {
    None
  } else {
    Some(cut)
  }
}

///|
/// What a view's ask says (`asked`), as JSON in the TypeScript's order.
pub fn asked(screen : Json) -> Json {
  let m = match screen {
    Object(m) => m
    _ => Map([])
  }
  let bound = (v : Json?, otherwise : Double) => match finite(v) {
    Some(x) => dmin(8192.0, dmax(16.0, js_round(x)))
    None => otherwise
  }
  let took = match m.get("codecs") {
    Some(Array(xs)) => codecs.filter(c => xs.iter().any(x => x is String(s) && s == c))
    _ => []
  }
  let peek = m.get("peek") is Some(True)
  let control = m.get("control") is Some(True) && !peek
  let side = (v : Json?) => match finite(v) {
    Some(x) => x >= 200.0 && x <= 2000.0
    None => false
  }
  let fit = match m.get("fit") {
    Some(Object(f)) if control &&
      side(f.get("width")) &&
      side(f.get("height")) &&
      (finite(f.get("scale")) is Some(s) && s >= 1.0 && s <= 4.0) =>
      Some(
        jobj([
          ("width", jnum(js_round(finite(f.get("width")).unwrap()))),
          ("height", jnum(js_round(finite(f.get("height")).unwrap()))),
          ("scale", jnum(finite(f.get("scale")).unwrap())),
        ]),
      )
    // (any other truthy `fit` is no object with those: none)
    _ => None
  }
  let quality = match m.get("quality") {
    Some(String("smooth" | "hd" | "original" as q)) if !peek => Some(q)
    _ => None
  }
  let fps = if is_fps(m.get("fps")) && !peek { num_of(m.get("fps")) } else { None }
  let out = [
    ("maxWidth", jnum(bound(m.get("maxWidth"), 1920.0))),
    ("maxHeight", jnum(bound(m.get("maxHeight"), 1080.0))),
    ("codecs", Json::array(took.map(jstr))),
    ("control", Json::boolean(control)),
    ("peek", Json::boolean(peek)),
  ]
  if m.get("audio") is Some(String("pcm_s16le")) && !peek {
    out.push(("audio", Json::boolean(true)))
    if m.get("opus") is Some(True) {
      out.push(("opus", Json::boolean(true)))
    }
  }
  if quality is Some(q) {
    out.push(("quality", jstr(q)))
  }
  if fps is Some(f) {
    out.push(("fps", jnum(f)))
  }
  if fit is Some(f) {
    out.push(("fit", f))
  }
  if m.get("gamut") is Some(String("p3")) {
    out.push(("gamut", jstr("p3")))
  }
  match m.get("passkeys") {
    Some(True) if !peek => out.push(("passkeys", Json::boolean(true)))
    Some(False) if !peek => out.push(("passkeys", Json::boolean(false)))
    _ => ()
  }
  for kv in [("client", 80), ("app", 16), ("self", 64)] {
    if said_word(m.get(kv.0), kv.1) is Some(w) {
      out.push((kv.0, jstr(w)))
    }
  }
  if m.get("taken") is Some(True) {
    out.push(("taken", Json::boolean(true)))
  }
  jobj(out)
}
