// A simulator's device as Apple draws it (src/screens/sim-chrome.ts): the case and buttons Xcode has for its device
// type (DeviceKit's .devicechrome: chrome.json, PDFs), read on this Mac and never kept anywhere but this Mac's temporary
// files: they are Apple's. Each panel is told clients as geometry in the case's own points; its pictures, turned as the
// device stands, are made as a client asks. The case is one picture with the panel's shape cut out of it (the device
// type's framebuffer mask) and the sensor bar over that, so the device's picture shows through it however a client
// draws that.
//
// Where it all lies and how it is laid out is serve-sim's (EvanBacon/serve-sim, Apache-2.0: vendor/README.md), changed
// so a client has one picture to draw.

///|
const CHROME_ROOT : String = "/Library/Developer/DeviceKit/Chrome"

///|
const CHROME_PREFIX : String = "com.apple.dt.devicekit.chrome."

///|
/// Pictures made by an older way of making them are not used: said in their names.
const CACHE_WAY : Int = 1

/// a test's own. `draw` draws a PDF's page as a PNG at `out`, its longest side `longest` pixels (none: as the page says).
pub(all) struct Drawing {
  cache : String
  draw : async (String, String, Double?) -> Unit
}

///|
pub fn sips(io : Io) -> Drawing {
  {
    cache: pj([(io.os.tmpdir)(), "stillfail-device-chrome"]),
    draw: async fn(from, out, longest) {
      let args = ["-s", "format", "png"]
      match longest {
        Some(l) => {
          args.push("-Z")
          args.push(num_text(l))
        }
        None => ()
      }
      args.push(from)
      args.push("--out")
      args.push(out)
      ignore((io.procs.exec)("sips", args, ExecOptions::new(timeout=Some(20000.0))))
    },
  }
}

///|
/// Each temporary file's own number in this process: two pictures made at once never write the same one.
let written : Ref[Int] = Ref(0)

///|
fn tmp_of(io : Io, path : String, ext : String) -> String {
  written.val += 1
  "\{path}.\{io.os.pid}.\{written.val}.\{ext}"
}

///|
#derive(Eq)
pub(all) struct Rect {
  x : Double
  y : Double
  width : Double
  height : Double
}

///|
fn size_obj(w : Double, h : Double) -> J {
  jo([("width", jn(w)), ("height", jn(h))])
}

///|
fn rect_obj(r : Rect) -> J {
  jo([("x", jn(r.x)), ("y", jn(r.y)), ("width", jn(r.width)), ("height", jn(r.height))])
}

///|
pub(all) struct Insets {
  left : Double
  top : Double
  right : Double
  bottom : Double
}

///|
/// A button of the device, in its panel's frame: where it rests, the way it goes in as it is pressed, its HID usage
/// (none: it is only drawn); `front`: on the case (a home button), not behind it.
pub(all) struct ChromeButton {
  name : String
  x : Double
  y : Double
  width : Double
  height : Double
  dx : Double
  dy : Double
  front : Bool
  page : Double?
  usage : Double?
}

///|
pub fn ChromeButton::to_j(self : ChromeButton) -> J {
  jsome([
    ("name", Some(js(self.name))),
    ("x", Some(jn(self.x))),
    ("y", Some(jn(self.y))),
    ("width", Some(jn(self.width))),
    ("height", Some(jn(self.height))),
    ("dx", Some(jn(self.dx))),
    ("dy", Some(jn(self.dy))),
    ("front", if self.front { Some(jb(true)) } else { None }),
    ("page", self.page.map(jn)),
    ("usage", self.usage.map(jn)),
  ])
}

///|
/// A panel's case as clients are told it, upright as its framebuffer is, in the case's own points.
pub(all) struct ChromePanel {
  key : String
  width : Double
  height : Double
  frame : (Double, Double)
  screen : Rect
  corners : Array[Double]
  buttons : Array[ChromeButton]
}

///|
pub fn ChromePanel::to_j(self : ChromePanel) -> J {
  jo([
    ("key", js(self.key)),
    ("width", jn(self.width)),
    ("height", jn(self.height)),
    ("frame", size_obj(self.frame.0, self.frame.1)),
    ("screen", rect_obj(self.screen)),
    ("corners", ja(self.corners.map(jn))),
    ("buttons", ja(self.buttons.map(b => b.to_j()))),
  ])
}

///|
pub(all) struct Slice {
  top_left : String
  top : String
  top_right : String
  right : String
  bottom_right : String
  bottom : String
  bottom_left : String
  left : String
}

///|
pub(all) struct ChromeImage {
  name : String
  image : String
  down : String?
  under : Bool
}

///|
/// What makes a panel's pictures, kept beside what clients are told.
pub(all) struct ChromeSource {
  panel : ChromePanel
  dir : String
  body : Rect
  composite : String?
  slice : Slice?
  sizing : Insets
  mask : String?
  sensor : String?
  images : Array[ChromeImage]
}

///|
/// What clients are told of a panel.
pub fn ChromeSource::told(self : ChromeSource) -> ChromePanel {
  self.panel
}

///|
pub fn ChromeSource::to_j(self : ChromeSource) -> J {
  let s = match self.slice {
    Some(s) =>
      jo([
        ("topLeft", js(s.top_left)),
        ("top", js(s.top)),
        ("topRight", js(s.top_right)),
        ("right", js(s.right)),
        ("bottomRight", js(s.bottom_right)),
        ("bottom", js(s.bottom)),
        ("bottomLeft", js(s.bottom_left)),
        ("left", js(s.left)),
      ])
    None => Null
  }
  spread(
    self.panel.to_j(),
    jo([
      ("dir", js(self.dir)),
      ("body", rect_obj(self.body)),
      ("composite", jopt_s(self.composite)),
      ("slice", s),
      (
        "sizing",
        jo([("left", jn(self.sizing.left)), ("top", jn(self.sizing.top)), ("right", jn(self.sizing.right)), ("bottom", jn(self.sizing.bottom))]),
      ),
      ("mask", jopt_s(self.mask)),
      ("sensor", jopt_s(self.sensor)),
      (
        "images",
        ja(self.images.map(i => jo([("name", js(i.name)), ("image", js(i.image)), ("down", jopt_s(i.down)), ("under", jb(i.under))]))),
      ),
    ]),
  )
}

///|
/// A device type's displays with a digitizer, each as much as its capabilities.plist says of it.
pub(all) struct ChromeDisplay {
  chrome : String
  mask : String?
  width : Double
  height : Double
  scale : Double
}

///|
fn record(v : J?) -> J {
  match v {
    Some(Obj(_) as o) => o
    _ => Obj([])
  }
}

///|
fn numv(v : J?) -> Double {
  match v {
    Some(Num(d)) if d.is_finite() => d
    _ => 0.0
  }
}

///|
fn string_of(v : J?) -> String? {
  match text(v) {
    Some(s) if s != "" => Some(s)
    _ => None
  }
}

///|
fn point_of(r : J) -> (Double, Double)? {
  match (get(Some(r), "x"), get(Some(r), "y")) {
    (Some(Num(x)), Some(Num(y))) => Some((x, y))
    _ => None
  }
}

///|
fn insets_of(r : J, left : String, top : String, right : String, bottom : String) -> Insets {
  { left: numv(get(Some(r), left)), top: numv(get(Some(r), top)), right: numv(get(Some(r), right)), bottom: numv(get(Some(r), bottom)) }
}

///|
/// `x || 1`.
fn or_one(d : Double) -> Double {
  if d == 0.0 || d.is_nan() {
    1.0
  } else {
    d
  }
}

///|
/// A device type's panels: its capabilities' displays, else (an older profile) the one its profile.plist says.
pub fn displays_of(capabilities : J, profile : J) -> Array[ChromeDisplay] {
  let inner = get(Some(record(Some(capabilities))), "capabilities")
  let caps = record(
    match inner {
      None | Some(Null) => Some(capabilities)
      x => x
    },
  )
  let out = []
  for entry in arr(get(Some(caps), "displays")).unwrap_or([]) {
    let d = record(Some(entry))
    if text(get(Some(d), "displayType")) != Some("integrated") ||
      !(get(Some(d), "hasDigitizer") is Some(Bool(true))) ||
      text(get(Some(d), "chromeIdentifier")) is None {
      continue
    }
    let width = numv(get(Some(d), "width"))
    let height = numv(get(Some(d), "height"))
    let scale = or_one(numv(get(Some(d), "scale")))
    if width > 0.0 && height > 0.0 {
      out.push({
        chrome: text(get(Some(d), "chromeIdentifier")).unwrap(),
        mask: string_of(get(Some(d), "framebufferMaskIdentifier")),
        width,
        height,
        scale,
      })
    }
  }
  if out.length() > 0 {
    return out
  }
  let p = record(Some(profile))
  let dims = record(get(Some(caps), "ScreenDimensionsCapability"))
  let width = numv(get(Some(dims), "main-screen-width"))
  let height = numv(get(Some(dims), "main-screen-height"))
  let scale = or_one(numv(get(Some(dims), "main-screen-scale")))
  match text(get(Some(p), "chromeIdentifier")) {
    Some(chrome) if width > 0.0 && height > 0.0 =>
      [{ chrome, mask: string_of(get(Some(p), "framebufferMask")), width, height, scale }]
    _ => []
  }
}

///|
async fn exists(io : Io, path : String) -> Bool {
  (io.fs.access)(path, 0)
}

///|
fn sha1_hex(s : String) -> String {
  @hash.sha1_utf8_hex(s)
}

///|
/// `/^[A-Za-z0-9_-]+$/`.
fn bare_name(s : String) -> Bool {
  if s == "" {
    return false
  }
  for c in s {
    if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
      return false
    }
  }
  true
}

///|
/// A display's case laid out, from its device type's bundle (`bundle`: its Contents/Resources); none where Xcode has
/// none for it or what it has cannot be read: the app draws what it did before.
pub async fn chrome_of(
  io : Io,
  display : ChromeDisplay,
  bundle : String,
  sensor : String?,
  root? : String = CHROME_ROOT,
  how? : Drawing? = None,
) -> ChromeSource? {
  let how = how.unwrap_or(sips(io))
  let bare = if display.chrome.has_prefix(CHROME_PREFIX) {
    display.chrome.unsafe_substring(start=CHROME_PREFIX.length(), end=display.chrome.length())
  } else {
    display.chrome
  }
  if !bare_name(bare) {
    return None
  }
  let dir = pj([root, "\{bare}.devicechrome", "Contents", "Resources"])
  let json = (try Some(parse(@utf8.decode_lossy((io.fs.read)(pj([dir, "chrome.json"]))))) catch { _ => None })
  guard json is Some(json) else { return None }
  let images = record(get(Some(json), "images"))
  let sizing = insets_of(record(get(Some(images), "sizing")), "leftWidth", "topHeight", "rightWidth", "bottomHeight")
  let padding = insets_of(record(get(Some(images), "devicePadding")), "left", "top", "right", "bottom")
  let pdf = async fn(name : J?) -> String? {
    match text(name) {
      Some(n) if exists(io, pj([dir, "\{n}.pdf"])) => Some(n)
      _ => None
    }
  }
  let composite = pdf(get(Some(images), "composite"))
  let slice = slice_of(images, pdf)
  let mask = match display.mask {
    Some(m) if exists(io, pj([bundle, "\{m}.pdf"])) => Some(pj([bundle, "\{m}.pdf"]))
    _ => None
  }
  let mask_bytes = match mask {
    Some(m) => Some((io.fs.read)(m))
    None => None
  }
  let mask_size = mask_bytes.bind(page_size)
  let mut body_size : (Double, Double)? = None
  let mut screen = (display.width / display.scale, display.height / display.scale)
  let mut centre : (Double, Double)? = None
  match composite {
    Some(c) => {
      let file = pj([dir, "\{c}.pdf"])
      body_size = page_size((io.fs.read)(file))
      match opening_of(io, file, how) {
        Some(opening) => {
          // (Apple's mask is the panel's shape in units that differ from one device to another: the composite's own
          // opening says which)
          match mask_size {
            Some((mw, mh)) => {
              let scale = js_max(1.0, js_round(mw / opening.width))
              screen = (mw / scale, mh / scale)
            }
            None => ()
          }
          centre = Some((opening.x + opening.width / 2.0, opening.y + opening.height / 2.0))
        }
        None => ()
      }
    }
    None => ()
  }
  if body_size is None && slice is None {
    return None
  }
  let (bw, bh) = match body_size {
    Some(s) => s
    None => (screen.0 + sizing.left + sizing.right, screen.1 + sizing.top + sizing.bottom)
  }
  let body = { x: padding.left, y: padding.top, width: bw, height: bh }
  let frame = (bw + padding.left + padding.right, bh + padding.top + padding.bottom)
  let at = match centre {
    Some(c) => c
    None =>
      (
        if composite is Some(_) { bw / 2.0 } else { sizing.left + screen.0 / 2.0 },
        if composite is Some(_) { bh / 2.0 } else { sizing.top + screen.1 / 2.0 },
      )
  }
  let placed = { x: body.x + at.0 - screen.0 / 2.0, y: body.y + at.1 - screen.1 / 2.0, width: screen.0, height: screen.1 }
  let buttons = []
  let pictured = []
  for entry in arr(get(Some(json), "inputs")).unwrap_or([]) {
    let b = record(Some(entry))
    let image = pdf(get(Some(b), "image"))
    guard image is Some(image) && text(get(Some(b), "name")) is Some(name) else { continue }
    guard page_size((io.fs.read)(pj([dir, "\{image}.pdf"]))) is Some(size) else { continue }
    let offsets = record(get(Some(b), "offsets"))
    let normal = point_of(record(get(Some(offsets), "normal")))
    let rollover = point_of(record(get(Some(offsets), "rollover")))
    let on_top = get(Some(b), "onTop") is Some(Bool(true))
    let out = match rollover {
      Some(r) => r
      None => normal.unwrap_or((0.0, 0.0))
    }
    let place = button_at(js_string_opt(get(Some(b), "anchor")), js_string_opt(get(Some(b), "align")), out, size, body, on_top)
    let page = numv(get(Some(b), "usagePage"))
    let usage = numv(get(Some(b), "usage"))
    let nx = match normal {
      Some(n) => n.0
      None => 0.0
    }
    let ny = match normal {
      Some(n) => n.1
      None => 0.0
    }
    let rx = match rollover {
      Some(r) => r.0
      None => match normal {
        Some(n) => n.0
        None => 0.0
      }
    }
    let ry = match rollover {
      Some(r) => r.1
      None => match normal {
        Some(n) => n.1
        None => 0.0
      }
    }
    buttons.push({
      name,
      x: place.0,
      y: place.1,
      width: size.0,
      height: size.1,
      dx: nx - rx,
      dy: ny - ry,
      front: on_top,
      page: if page > 0.0 && usage > 0.0 { Some(page) } else { None },
      usage: if page > 0.0 && usage > 0.0 { Some(usage) } else { None },
    })
    pictured.push({
      name,
      image,
      down: pdf(get(Some(b), "imageDown")),
      under: text(get(Some(b), "imageDownDrawMode")) == Some("compositeUnder"),
    })
  }
  // (a mask whose name is another device's would be the same case with another shape cut out of it)
  let key = slice_units(
    sha1_hex("\{bare}\u{0}\{display.mask.unwrap_or("")}\u{0}\{sensor.unwrap_or("")}\u{0}\{num_text(display.width)}x\{num_text(display.height)}"),
    0,
    16,
  )
  let corners = match mask_bytes {
    Some(m) =>
      match panel_of(m) {
        Some(p) => p.corners
        None => []
      }
    None => []
  }
  let sensor_path = match sensor {
    Some(s) if exists(io, pj([bundle, "\{s}.pdf"])) => Some(pj([bundle, "\{s}.pdf"]))
    _ => None
  }
  Some({
    panel: { key, width: display.width, height: display.height, frame, screen: placed, corners, buttons },
    dir,
    body,
    composite,
    slice,
    sizing,
    mask,
    sensor: sensor_path,
    images: pictured,
  })
}

///|
/// `String(v)`, undefined's too.
fn js_string_opt(v : J?) -> String {
  match v {
    None => "undefined"
    Some(x) => js_string(x)
  }
}

///|
/// How far a button stands out of the case at the least.
const SHOWS : Double = 3

///|
/// Where a button rests. In chrome.json's `offsets`, from the side it is anchored to, the middle of its picture is: at
/// `normal` its outer edge is that of the case, at `rollover` it stands out. Here it stands so always, by as much as
/// `SHOWS` at least, and its picture's top left is what `normal` says of a button on the case's face.
fn button_at(
  anchor : String,
  align : String,
  out : (Double, Double),
  size : (Double, Double),
  body : Rect,
  front : Bool,
) -> (Double, Double) {
  let (ox, oy) = out
  let (sw, sh) = size
  let along = if align == "trailing" {
    body.x + body.width + ox - sw
  } else if align == "center" {
    body.x + (body.width - sw) / 2.0 + ox
  } else {
    body.x + ox
  }
  match anchor {
    "right" => (js_max(body.x + body.width + ox - sw / 2.0, body.x + body.width + SHOWS - sw), body.y + oy)
    "top" => (along, js_min(body.y + oy - sh / 2.0, body.y - SHOWS))
    "bottom" =>
      (
        along,
        if front {
          body.y + body.height + oy
        } else {
          js_max(body.y + body.height + oy - sh / 2.0, body.y + body.height + SHOWS - sh)
        },
      )
    _ => (js_min(body.x + ox - sw / 2.0, body.x - SHOWS), body.y + oy)
  }
}

///|
/// How many pixels a case's point is drawn at.
fn pixels_of(c : ChromeSource) -> Double {
  if c.panel.frame.0 > 700.0 {
    2.0
  } else {
    3.0
  }
}

///|
/// A panel's pictures as base64 PNGs: the case, and each button up and pressed.
pub(all) struct ChromePictures {
  body : String
  buttons : Array[(String, String, String?)]
}

///|
pub fn ChromePictures::to_j(self : ChromePictures) -> J {
  jo([
    ("body", js(self.body)),
    ("buttons", jo(self.buttons.map(b => (b.0, jsome([("up", Some(js(b.1))), ("down", b.2.map(js))]))))),
  ])
}

///|
fn ChromePictures::of_j(j : J) -> ChromePictures {
  let buttons = match get(Some(j), "buttons") {
    Some(Obj(ps)) =>
      ps.map(p => (@jsjson.text(p.0), text(get(Some(p.1), "up")).unwrap_or(""), text(get(Some(p.1), "down"))))
    _ => []
  }
  { body: text(get(Some(j), "body")).unwrap_or(""), buttons }
}

///|
let making : Map[String, @effect.Deferred[ChromePictures]] = {}

///|
/// A panel's pictures, turned `turn` quarters clockwise, as base64 PNGs. Made once and kept in this Mac's temporary
/// files.
pub async fn pictures_of(io : Io, c : ChromeSource, turn : Int, how? : Drawing? = None) -> ChromePictures {
  let how = how.unwrap_or(sips(io))
  let id = "\{how.cache}\u{0}\{c.panel.key}/\{turn}"
  let made = match making.get(id) {
    Some(d) => d
    None => {
      let d : @effect.Deferred[ChromePictures] = @effect.Deferred::new()
      making[id] = d
      (io.spawn)(async fn() {
        // (called off meanwhile: not kept, so a later ask makes them anew)
        defer {
          if !d.is_done() {
            match making.get(id) {
              Some(x) if physical_equal(x, d) => making.remove(id)
              _ => ()
            }
            ignore(d.fail(fail("the pictures were called off")))
          }
        }
        match (try Ok(make_pictures(io, c, turn, how)) catch { e => Err(e) }) {
          Ok(p) => ignore(d.succeed(p))
          Err(e) => {
            match making.get(id) {
              Some(x) if physical_equal(x, d) => making.remove(id)
              _ => ()
            }
            ignore(d.fail(e))
          }
        }
      })
      d
    }
  }
  made.wait()
}

///|
async fn make_pictures(io : Io, c : ChromeSource, turn : Int, how : Drawing) -> ChromePictures {
  let stamp = (io.fs.stat)(pj([c.dir, "chrome.json"]))
  let stem = sha1_hex("\{CACHE_WAY}\u{0}\{c.panel.key}\u{0}\{num_text(stamp.mtime_ms)}\u{0}\{turn}")
  (io.fs.mkdir)(how.cache, true, None)
  let kept = pj([how.cache, "\{stem}.json"])
  match (try Some((io.fs.read)(kept)) catch { _ => None }) {
    Some(before) => return ChromePictures::of_j(parse(@utf8.decode_lossy(before)))
    None => ()
  }
  let scale = pixels_of(c)
  let body = b64(encode_png(turned(body_of(io, c, scale, how), turn)))
  let buttons = []
  for b in c.panel.buttons {
    guard c.images.search_by(i => i.name == b.name) is Some(at) else { continue }
    let names = c.images[at]
    let size = (js_round(b.width * scale), js_round(b.height * scale))
    let drawn = async fn(name : String) { rendered(io, pj([c.dir, "\{name}.pdf"]), size, how) }
    let up = drawn(names.image)
    let mut down = match names.down {
      Some(d) => Some(drawn(d))
      None => None
    }
    // (a home button's pressed picture is what is under the button itself)
    match down {
      Some(d) if names.under => {
        let copy = { width: d.width, height: d.height, data: d.data.copy() }
        paint(copy, up, 0, 0)
        down = Some(copy)
      }
      _ => ()
    }
    buttons.push((b.name, b64(encode_png(turned(up, turn))), down.map(d => b64(encode_png(turned(d, turn))))))
  }
  let pictures = { body, buttons }
  let tmp = tmp_of(io, kept, "tmp")
  (io.fs.write)(tmp, @utf8.encode(stringify(pictures.to_j())), None)
  (io.fs.rename)(tmp, kept)
  pictures
}

///|
/// The case over its frame: composite, or its pieces with the sides stretched; the panel's shape cut out; the sensor
/// bar over that.
async fn body_of(io : Io, c : ChromeSource, scale : Double, how : Drawing) -> Pixels {
  let frame = blank(js_round(c.panel.frame.0 * scale).to_int(), js_round(c.panel.frame.1 * scale).to_int())
  let x = js_round(c.body.x * scale).to_int()
  let y = js_round(c.body.y * scale).to_int()
  let w = js_round(c.body.width * scale).to_int()
  let h = js_round(c.body.height * scale).to_int()
  match (c.composite, c.slice) {
    (Some(composite), _) => paint(frame, rendered(io, pj([c.dir, "\{composite}.pdf"]), (w.to_double(), h.to_double()), how), x, y)
    (None, Some(s)) => {
      let pdf = (name : String) => pj([c.dir, "\{name}.pdf"])
      let sized = async fn(name : String) { page_size((io.fs.read)(pdf(name))).unwrap() }
      let corner = sized(s.top_left)
      let cw = js_round(corner.0 * scale).to_int()
      let ch = js_round(corner.1 * scale).to_int()
      let piece = async fn(name : String, width : Int, height : Int) {
        rendered(io, pdf(name), (width.to_double(), height.to_double()), how)
      }
      let top_w = js_round(sized(s.top).0 * scale).to_int()
      paint(frame, stretched(piece(s.top, top_w, ch), w - 2 * cw, ch), x + cw, y)
      let bottom_w = js_round(sized(s.bottom).0 * scale).to_int()
      paint(frame, stretched(piece(s.bottom, bottom_w, ch), w - 2 * cw, ch), x + cw, y + h - ch)
      let left_h = js_round(sized(s.left).1 * scale).to_int()
      paint(frame, stretched(piece(s.left, cw, left_h), cw, h - 2 * ch), x, y + ch)
      let right_h = js_round(sized(s.right).1 * scale).to_int()
      paint(frame, stretched(piece(s.right, cw, right_h), cw, h - 2 * ch), x + w - cw, y + ch)
      paint(frame, piece(s.top_left, cw, ch), x, y)
      paint(frame, piece(s.top_right, cw, ch), x + w - cw, y)
      paint(frame, piece(s.bottom_left, cw, ch), x, y + h - ch)
      paint(frame, piece(s.bottom_right, cw, ch), x + w - cw, y + h - ch)
      // (the pieces leave the middle empty: what is not the panel is black, as the composite has it)
      fill_rect(frame, x + cw, y + ch, w - 2 * cw, h - 2 * ch)
    }
    _ => ()
  }
  let sx = js_round(c.panel.screen.x * scale).to_int()
  let sy = js_round(c.panel.screen.y * scale).to_int()
  let sw = js_round(c.panel.screen.width * scale).to_int()
  let sh = js_round(c.panel.screen.height * scale).to_int()
  match c.mask {
    Some(m) => {
      // Inside the mask nothing of the case is left; at its edge as much as the mask leaves.
      let mask = rendered(io, m, (sw.to_double(), sh.to_double()), how)
      for j in 0..<sh {
        for i in 0..<sw {
          let p = ((sy + j) * frame.width + sx + i) * 4 + 3
          let alpha = px_get(frame.data, p).to_double()
          let m = px_get(mask.data, (j * sw + i) * 4 + 3).to_double()
          px_set(frame.data, p, js_round(alpha * (255.0 - m) / 255.0))
        }
      }
    }
    None =>
      for j in 0..<sh {
        let from = (sy + j) * frame.width * 4 + sx * 4
        let to = (sy + j) * frame.width * 4 + (sx + sw) * 4
        fill_zero(frame.data, from, to)
      }
  }
  match c.sensor {
    Some(sensor) =>
      // In the panel's points, at the middle of its top: a notch's.
      match page_size((io.fs.read)(sensor)) {
        Some((pw, ph)) => {
          let bar = rendered(io, sensor, (js_round(pw * scale), js_round(ph * scale)), how)
          paint(frame, bar, sx + js_round((sw - bar.width).to_double() / 2.0).to_int(), sy)
        }
        None => ()
      }
    None => ()
  }
  frame
}

///|
/// A typed array's element as JavaScript reads one (undefined, read as a number, NaN: here 0 where it is set from).
fn px_get(d : FixedArray[Byte], i : Int) -> Int {
  if i >= 0 && i < d.length() {
    d[i].to_int()
  } else {
    0
  }
}

///|
/// A Uint8Array's element set: out of its bounds nothing, a value as ToUint8 takes it.
fn px_set(d : FixedArray[Byte], i : Int, v : Double) -> Unit {
  if i >= 0 && i < d.length() {
    d[i] = (to_int32(v) & 0xff).to_byte()
  }
}

///|
/// `data.fill(0, from, to)`, its bounds as a typed array's fill takes them.
fn fill_zero(d : FixedArray[Byte], from : Int, to : Int) -> Unit {
  let n = d.length()
  let a = if from < 0 { js_max(0.0, (n + from).to_double()).to_int() } else if from > n { n } else { from }
  let b = if to < 0 { js_max(0.0, (n + to).to_double()).to_int() } else if to > n { n } else { to }
  for i = a; i < b; i = i + 1 {
    d[i] = b'\x00'
  }
}

///|
/// The quarter turns clockwise a PDF's page is shown at (`/Rotate`).
fn page_turn(text : String) -> Int {
  let mut from = 0
  while true {
    let i = match text.unsafe_substring(start=from, end=text.length()).find("/Rotate") {
      Some(i) => from + i
      None => return 0
    }
    from = i + 1
    let r = Reader::new(text, i + 7)
    if !r.spaces1() {
      continue
    }
    match r.digits() {
      Some(d) => {
        let n = js_number(d) / 90.0
        return if is_integer(n) { n.to_int() } else { n.to_int() }
      }
      None => continue
    }
  }
  0
}

///|
/// The size a PDF's page says it is.
pub fn page_size(pdf : Bytes) -> (Double, Double)? {
  let text = latin1_text(pdf)
  let found = match box_of(text, "/CropBox") {
    Some(b) => Some(b)
    None => box_of(text, "/MediaBox")
  }
  guard found is Some((a, b, c, d)) else { return None }
  let width = abs_d(js_number(c) - js_number(a))
  let height = abs_d(js_number(d) - js_number(b))
  if !(width > 0.0) || !(height > 0.0) {
    return None
  }
  if page_turn(text) % 2 == 1 {
    Some((height, width))
  } else {
    Some((width, height))
  }
}

///|
/// `/<name>\s*\[\s*(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*\]/`.
fn box_of(text : String, name : String) -> (String, String, String, String)? {
  let mut from = 0
  while true {
    let i = match text.unsafe_substring(start=from, end=text.length()).find(name) {
      Some(i) => from + i
      None => return None
    }
    from = i + 1
    let r = Reader::new(text, i + name.length())
    r.spaces()
    if !r.eat('[') {
      continue
    }
    r.spaces()
    guard r.signed_digits() is Some(a) else { continue }
    if !r.spaces1() {
      continue
    }
    guard r.signed_digits() is Some(b) else { continue }
    if !r.spaces1() {
      continue
    }
    guard r.signed_digits() is Some(c) else { continue }
    if !r.spaces1() {
      continue
    }
    guard r.signed_digits() is Some(d) else { continue }
    r.spaces()
    if !r.eat(']') {
      continue
    }
    return Some((a, b, c, d))
  }
  None
}

///|
/// A composite's opening, the opaque black it has for a screen: walked out from its middle along its middle row and
/// column. In its own points.
async fn opening_of(io : Io, pdf : String, how : Drawing) -> Rect? {
  guard page_size((io.fs.read)(pdf)) is Some((pw, ph)) else { return None }
  let p = rendered(io, pdf, (js_round(pw), js_round(ph)), how)
  let dark = (x : Int, y : Int) => {
    if x < 0 || y < 0 || x >= p.width || y >= p.height {
      return false
    }
    let i = (y * p.width + x) * 4
    px_get(p.data, i + 3) > 200 && px_get(p.data, i) < 30 && px_get(p.data, i + 1) < 30 && px_get(p.data, i + 2) < 30
  }
  let cx = p.width >> 1
  let cy = p.height >> 1
  if !dark(cx, cy) {
    return None
  }
  let mut x0 = cx
  let mut x1 = cx
  let mut y0 = cy
  let mut y1 = cy
  while dark(x0 - 1, cy) {
    x0 -= 1
  }
  while dark(x1 + 1, cy) {
    x1 += 1
  }
  while dark(cx, y0 - 1) {
    y0 -= 1
  }
  while dark(cx, y1 + 1) {
    y1 += 1
  }
  Some({ x: x0.to_double(), y: y0.to_double(), width: (x1 - x0 + 1).to_double(), height: (y1 - y0 + 1).to_double() })
}

///|
/// RGBA pixels.
pub(all) struct Pixels {
  width : Int
  height : Int
  data : FixedArray[Byte]
}

///|
fn blank(width : Int, height : Int) -> Pixels {
  let n = width * height * 4
  { width, height, data: FixedArray::make(if n > 0 { n } else { 0 }, b'\x00') }
}

///|
/// `over` painted on `under` at (x, y), each pixel over what is there.
fn paint(under : Pixels, over : Pixels, x : Int, y : Int) -> Unit {
  for j in 0..<over.height {
    let row = y + j
    if row < 0 || row >= under.height {
      continue
    }
    for i in 0..<over.width {
      let col = x + i
      if col < 0 || col >= under.width {
        continue
      }
      let s = (j * over.width + i) * 4
      let d = (row * under.width + col) * 4
      let a = px_get(over.data, s + 3).to_double()
      if a == 0.0 {
        continue
      }
      let b = px_get(under.data, d + 3).to_double()
      let out = a + b * (255.0 - a) / 255.0
      for k in 0..<3 {
        px_set(
          under.data,
          d + k,
          js_round((px_get(over.data, s + k).to_double() * a + px_get(under.data, d + k).to_double() * b * (255.0 - a) / 255.0) / out),
        )
      }
      px_set(under.data, d + 3, js_round(out))
    }
  }
}

///|
fn fill_rect(p : Pixels, x : Int, y : Int, w : Int, h : Int) -> Unit {
  for j = y; j < y + h; j = j + 1 {
    for i = x; i < x + w; i = i + 1 {
      let d = (j * p.width + i) * 4
      px_set(p.data, d, 0.0)
      px_set(p.data, d + 1, 0.0)
      px_set(p.data, d + 2, 0.0)
      px_set(p.data, d + 3, 255.0)
    }
  }
}

///|
/// A side piece stretched to `width`×`height`: only along its length, across which it is the same.
fn stretched(p : Pixels, width : Int, height : Int) -> Pixels {
  let out = blank(width, height)
  for j in 0..<height {
    let v = { let t = (j * p.height).to_double() / height.to_double(); let f = t.floor().to_int(); if p.height - 1 < f { p.height - 1 } else { f } }
    for i in 0..<width {
      let u = { let t = (i * p.width).to_double() / width.to_double(); let f = t.floor().to_int(); if p.width - 1 < f { p.width - 1 } else { f } }
      let from = (v * p.width + u) * 4
      for k in 0..<4 {
        px_set(out.data, (j * width + i) * 4 + k, px_get(p.data, from + k).to_double())
      }
    }
  }
  out
}

///|
/// `p` turned `turn` quarters clockwise.
pub fn turned(p : Pixels, turn : Int) -> Pixels {
  let t = (turn % 4 + 4) % 4
  if t == 0 {
    return p
  }
  let out = if t == 2 { blank(p.width, p.height) } else { blank(p.height, p.width) }
  for y in 0..<p.height {
    for x in 0..<p.width {
      let (nx, ny) = if t == 1 {
        (p.height - 1 - y, x)
      } else if t == 2 {
        (p.width - 1 - x, p.height - 1 - y)
      } else {
        (y, p.width - 1 - x)
      }
      let from = (y * p.width + x) * 4
      let to = (ny * out.width + nx) * 4
      for k in 0..<4 {
        out.data[to + k] = p.data[from + k]
      }
    }
  }
  out
}

///|
/// The pictures being drawn, by where each is kept: two asking for one at once are given the one drawing.
let drawing : Map[String, @effect.Deferred[Pixels]] = {}

///|
/// A PDF's page at `size`, drawn by `how`; a page with a /Rotate drawn as it lies, then turned here.
async fn rendered(io : Io, pdf : String, size : (Double, Double), how : Drawing) -> Pixels {
  let st = (io.fs.stat)(pdf)
  let stem = sha1_hex("\{pdf}\u{0}\{num_text(st.mtime_ms)}\u{0}\{num_text(size.0)}x\{num_text(size.1)}")
  let png = pj([how.cache, "\{stem}.png"])
  let made = match drawing.get(png) {
    Some(d) => d
    None => {
      let d : @effect.Deferred[Pixels] = @effect.Deferred::new()
      drawing[png] = d
      (io.spawn)(async fn() {
        // (called off meanwhile: let go of, so a later ask draws it anew)
        defer {
          match drawing.get(png) {
            Some(x) if physical_equal(x, d) => drawing.remove(png)
            _ => ()
          }
          if !d.is_done() {
            ignore(d.fail(fail("the drawing was called off")))
          }
        }
        let r = try Ok(drawn(io, pdf, png, size, how)) catch { e => Err(e) }
        match drawing.get(png) {
          Some(x) if physical_equal(x, d) => drawing.remove(png)
          _ => ()
        }
        match r {
          Ok(p) => ignore(d.succeed(p))
          Err(e) => ignore(d.fail(e))
        }
      })
      d
    }
  }
  made.wait()
}

///|
async fn drawn(io : Io, pdf : String, png : String, size : (Double, Double), how : Drawing) -> Pixels {
  (io.fs.mkdir)(how.cache, true, None)
  let bytes = (io.fs.read)(pdf)
  let text = latin1_text(bytes)
  let turn = page_turn(text)
  let lying = if turn % 2 == 1 { (size.1, size.0) } else { size }
  if !exists(io, png) {
    let page = page_size(bytes).unwrap()
    let longest = js_max(size.0, size.1)
    let tmp = tmp_of(io, png, "png")
    let mut from = pdf
    if turn != 0 {
      // (the same bytes, the turn said as none: nothing else in the file moves)
      from = tmp_of(io, png, "pdf")
      (io.fs.write)(from, latin1_bytes(unrotated(text)), None)
    }
    try {
      (how.draw)(from, tmp, if js_round(js_max(page.0, page.1)) != longest { Some(longest) } else { None })
      (io.fs.rename)(tmp, png)
    } catch {
      e => {
        (io.fs.rm)(tmp, false, true) catch { _ => () }
        if from != pdf {
          (io.fs.rm)(from, false, true)
        }
        raise e
      }
    }
    if from != pdf {
      (io.fs.rm)(from, false, true)
    }
  }
  let got = decode_png((io.fs.read)(png))
  // (rounding: a pixel off in a side, where what is asked is what is placed)
  let lw = lying.0.to_int()
  let lh = lying.1.to_int()
  turned(if got.width == lw && got.height == lh { got } else { stretched(got, lw, lh) }, turn)
}

///|
/// The first `/Rotate\s+\d+` said as none, as long as it was: `/Rotate 000`.
fn unrotated(text : String) -> String {
  let mut from = 0
  while true {
    let i = match text.unsafe_substring(start=from, end=text.length()).find("/Rotate") {
      Some(i) => from + i
      None => return text
    }
    from = i + 1
    let r = Reader::new(text, i + 7)
    if !r.spaces1() {
      continue
    }
    match r.digits() {
      Some(_) => {
        let said = r.at - i
        let zeros = StringBuilder()
        for _ in 0..<(said - 8) {
          zeros.write_char('0')
        }
        return text.unsafe_substring(start=0, end=i) +
          "/Rotate " +
          zeros.to_string() +
          text.unsafe_substring(start=r.at, end=text.length())
      }
      None => continue
    }
  }
  text
}

///|
/// An 8-bit PNG as RGBA.
pub fn decode_png(png : Bytes) -> Pixels raise Failed {
  if png.length() < 26 || latin1_text(png[1:4]) != "PNG" {
    raise fail("not a PNG")
  }
  let width = u32be(png, 16).to_int()
  let height = u32be(png, 20).to_int()
  if png[24] != b'\x08' {
    raise fail("a PNG of \{png[24].to_int()} bits")
  }
  let channels = match png[25].to_int() {
    0 => 1
    2 => 3
    4 => 2
    6 => 4
    t => raise fail("a PNG of colour type \{t}")
  }
  let parts = Buffer()
  let mut at = 8
  while at < png.length() {
    if at + 8 > png.length() {
      break
    }
    let n = u32be(png, at).to_int()
    if latin1_text(png[at + 4:at + 8]) == "IDAT" {
      let end = if at + 8 + n > png.length() { png.length() } else { at + 8 + n }
      parts.write_bytesview(png[at + 8:end])
    }
    at += 12 + n
  }
  let raw = inflate(parts.to_bytes())
  let out = FixedArray::make(width * height * 4, b'\x00')
  let stride = width * channels
  let mut prior = FixedArray::make(stride, 0)
  let mut row = FixedArray::make(stride, 0)
  let mut at = 0
  let rawv = (i : Int) => if i < raw.length() { Some(raw[i].to_int()) } else { None }
  for y in 0..<height {
    let filter = rawv(at)
    at += 1
    for i in 0..<stride {
      let a = if i >= channels { row[i - channels] } else { 0 }
      let b = prior[i]
      let c = if i >= channels { prior[i - channels] } else { 0 }
      let v = rawv(at)
      at += 1
      row[i] = match (v, filter) {
        (None, _) | (_, None) => 0
        (Some(v), Some(0)) => v
        (Some(v), Some(1)) => (v + a) & 0xff
        (Some(v), Some(2)) => (v + b) & 0xff
        (Some(v), Some(3)) => (v + ((a + b) >> 1)) & 0xff
        (Some(v), Some(_)) => (v + paeth(a, b, c)) & 0xff
      }
    }
    for x in 0..<width {
      let d = (y * width + x) * 4
      if channels >= 3 {
        out[d] = row[x * channels].to_byte()
        out[d + 1] = row[x * channels + 1].to_byte()
        out[d + 2] = row[x * channels + 2].to_byte()
      } else {
        out[d] = row[x * channels].to_byte()
        out[d + 1] = row[x * channels].to_byte()
        out[d + 2] = row[x * channels].to_byte()
      }
      out[d + 3] = (if channels == 4 { row[x * 4 + 3] } else if channels == 2 { row[x * 2 + 1] } else { 255 }).to_byte()
    }
    let t = prior
    prior = row
    row = t
  }
  { width, height, data: out }
}

///|
fn paeth(a : Int, b : Int, c : Int) -> Int {
  let p = a + b - c
  let pa = (p - a).abs()
  let pb = (p - b).abs()
  let pc = (p - c).abs()
  if pa <= pb && pa <= pc {
    a
  } else if pb <= pc {
    b
  } else {
    c
  }
}

///|
/// RGBA as a PNG (its pixels deflated as zlib makes them).
pub fn encode_png(p : Pixels) -> Bytes {
  let raw = FixedArray::make((p.width * 4 + 1) * p.height, b'\x00')
  for y in 0..<p.height {
    for i in 0..<(p.width * 4) {
      raw[y * (p.width * 4 + 1) + 1 + i] = p.data[y * p.width * 4 + i]
    }
  }
  let head = FixedArray::make(13, b'\x00')
  put_u32be(head, 0, p.width.to_int64())
  put_u32be(head, 4, p.height.to_int64())
  head[8] = b'\x08'
  head[9] = b'\x06'
  let chunk = (kind : String, body : Bytes) => {
    let out = FixedArray::make(12 + body.length(), b'\x00')
    put_u32be(out, 0, body.length().to_int64())
    let k = latin1_bytes(kind)
    for i in 0..<4 {
      out[4 + i] = k[i]
    }
    for i in 0..<body.length() {
      out[8 + i] = body[i]
    }
    let crc = crc32(Bytes::from_array(out)[4:8 + body.length()])
    put_u32be(out, 8 + body.length(), crc)
    Bytes::from_array(out)
  }
  concat([
    b"\x89PNG\r\n\x1a\n",
    chunk("IHDR", Bytes::from_array(head)),
    chunk("IDAT", deflate(Bytes::from_array(raw))),
    chunk("IEND", b""),
  ])
}

///|
fn crc32(b : BytesView) -> Int64 {
  @codec.crc32(b).to_uint64().reinterpret_as_int64()
}

///|
async fn slice_of(images : J, pdf : async (J?) -> String?) -> Slice? {
  let names = ["topLeft", "top", "topRight", "right", "bottomRight", "bottom", "bottomLeft", "left"]
  let got = @effect.all(names.map(k => async fn() { pdf(get(Some(images), k)) }))
  match got {
    [Some(top_left), Some(top), Some(top_right), Some(right), Some(bottom_right), Some(bottom), Some(bottom_left), Some(left)] =>
      Some({ top_left, top, top_right, right, bottom_right, bottom, bottom_left, left })
    _ => None
  }
}
