// A simulator's screen as Apple draws it (src/screens/sim-mask.ts): its device type's framebuffer masks (a PDF for each
// of its panels, an iPhone Duo's two), read for what the app's device body goes round. Each corner is the circle that
// comes as near its corner as the shape does, as a share of the panel's width.

///|
/// How many straight pieces each curve of a mask is taken as.
const CURVE_STEPS : Int = 16

/// A panel: its size, and its corners top left and then round it.
#derive(Eq)
pub(all) struct Panel {
  width : Double
  height : Double
  corners : Array[Double]
}

///|
pub fn Panel::to_j(self : Panel) -> J {
  jo([("width", jn(self.width)), ("height", jn(self.height)), ("corners", ja(self.corners.map(jn)))])
}

///|
/// Node's zlib `inflate`: a zlib stream (its header, the deflated data, its Adler-32), what follows it let go.
pub fn inflate(b : BytesView) -> Bytes raise Failed {
  match @flate.zlib_decompress(b) {
    Some(d) => d
    None => raise fail("invalid zlib data")
  }
}

///|
/// Node's zlib `deflate`: a zlib stream of `b`.
pub fn deflate(b : BytesView) -> Bytes {
  @flate.zlib_compress(b)
}

///|
/// `Math.hypot(a, b)` as V8 works it out (scaled by the larger, summed with compensation).
fn hypot(a : Double, b : Double) -> Double {
  let x = abs_d(a)
  let y = abs_d(b)
  if x.is_inf() || y.is_inf() {
    return @double.infinity
  }
  if x.is_nan() || y.is_nan() {
    return @double.not_a_number
  }
  let max = if x > y { x } else { y }
  if max == 0.0 {
    return 0.0
  }
  let mut sum = 0.0
  let mut compensation = 0.0
  for v in [x, y] {
    let n = v / max
    let summand = n * n - compensation
    let preliminary = sum + summand
    compensation = preliminary - sum - summand
    sum = preliminary
  }
  sum.sqrt() * max
}

///|
/// `text.split(/\s+/)`.
fn split_space(s : String) -> Array[String] {
  let out = []
  let cur = StringBuilder()
  let mut in_space = false
  for c in s {
    if is_js_space(c) {
      if !in_space {
        out.push(cur.to_string())
        cur.reset()
        in_space = true
      }
    } else {
      in_space = false
      cur.write_char(c)
    }
  }
  out.push(cur.to_string())
  out
}

///|
/// The panel a mask's PDF says, its corners top left and then round it; none when it is not such a mask.
pub fn panel_of(pdf : Bytes) -> Panel? {
  let text = latin1_text(pdf)
  guard media_box_zero(text) is Some((width, height)) else { return None }
  // (a page's drawing may not be the file's first stream, nor at all where another tool made it: the first that has
  // the shape)
  let mut from = 0
  while true {
    guard stream_at(text, from) is Some((index, len)) else { break }
    from = index + len
    let before = if index - 3 < 0 { 0 } else { index - 3 }
    if text.unsafe_substring(start=before, end=text.length()).has_prefix("end") {
      continue
    }
    let start = index + len
    let end = match text.unsafe_substring(start~, end=text.length()).find("endstream") {
      Some(i) => start + i
      None => break
    }
    let body = pdf[start:end]
    let path = latin1_text(inflate(body)) catch { _ => latin1_text(body) }
    let outline = outline_of(path)
    if outline.length() == 0 {
      continue
    }
    let corner = (x : Double, y : Double) => {
      let mut nearest = @double.infinity
      for p in outline {
        let h = hypot(p.0 - x, p.1 - y)
        if h < nearest || h.is_nan() {
          nearest = h
        }
      }
      js_round(nearest / (2.0.sqrt() - 1.0) / width * 10000.0) / 10000.0
    }
    let corners = [corner(0.0, height), corner(width, height), corner(width, 0.0), corner(0.0, 0.0)]
    return if corners.iter().all(c => c <= 0.5) { Some({ width, height, corners }) } else { None }
  }
  None
}

///|
/// The next `stream\r?\n` at or after `from`: where it is and how long.
fn stream_at(text : String, from : Int) -> (Int, Int)? {
  let mut at = from
  while true {
    let i = match text.unsafe_substring(start=at, end=text.length()).find("stream") {
      Some(i) => at + i
      None => return None
    }
    let after = i + 6
    if after < text.length() && text.unsafe_get(after).to_int() == 10 {
      return Some((i, 7))
    }
    if after + 1 < text.length() && text.unsafe_get(after).to_int() == 13 && text.unsafe_get(after + 1).to_int() == 10 {
      return Some((i, 8))
    }
    at = i + 1
  }
  None
}

///|
/// `/\/MediaBox\s*\[\s*0(?:\.0+)?\s+0(?:\.0+)?\s+([\d.]+)\s+([\d.]+)\s*\]/`: the width and height of a page whose box
/// starts at 0 0.
fn media_box_zero(text : String) -> (Double, Double)? {
  let mut from = 0
  while true {
    let i = match text.unsafe_substring(start=from, end=text.length()).find("/MediaBox") {
      Some(i) => from + i
      None => return None
    }
    from = i + 1
    let r = Reader::new(text, i + 9)
    r.spaces()
    if !r.eat('[') {
      continue
    }
    r.spaces()
    if !r.zero() || !r.spaces1() || !r.zero() || !r.spaces1() {
      continue
    }
    guard r.digits_dots() is Some(w) else { continue }
    if !r.spaces1() {
      continue
    }
    guard r.digits_dots() is Some(h) else { continue }
    r.spaces()
    if !r.eat(']') {
      continue
    }
    return Some((js_number(w), js_number(h)))
  }
  None
}

///|
/// A cursor over a string's characters, for what a regular expression of the TypeScript reads.
priv struct Reader {
  s : Array[Char]
  mut at : Int
}

///|
fn Reader::new(s : String, at : Int) -> Reader {
  { s: s.to_array(), at }
}

///|
fn Reader::peek(self : Reader) -> Char? {
  if self.at < self.s.length() {
    Some(self.s[self.at])
  } else {
    None
  }
}

///|
fn Reader::eat(self : Reader, c : Char) -> Bool {
  if self.peek() == Some(c) {
    self.at += 1
    true
  } else {
    false
  }
}

///|
/// `\s*`.
fn Reader::spaces(self : Reader) -> Unit {
  while self.peek() is Some(c) && is_js_space(c) {
    self.at += 1
  }
}

///|
/// `\s+`.
fn Reader::spaces1(self : Reader) -> Bool {
  let was = self.at
  self.spaces()
  self.at > was
}

///|
/// `0(?:\.0+)?`.
fn Reader::zero(self : Reader) -> Bool {
  if !self.eat('0') {
    return false
  }
  if self.peek() == Some('.') && self.at + 1 < self.s.length() && self.s[self.at + 1] == '0' {
    self.at += 1
    while self.peek() == Some('0') {
      self.at += 1
    }
  }
  true
}

///|
/// `[\d.]+`.
fn Reader::digits_dots(self : Reader) -> String? {
  let was = self.at
  while self.peek() is Some(c) && ((c >= '0' && c <= '9') || c == '.') {
    self.at += 1
  }
  if self.at > was {
    Some(String::from_array(self.s[was:self.at]))
  } else {
    None
  }
}

///|
/// `-?[\d.]+`.
fn Reader::signed_digits(self : Reader) -> String? {
  let was = self.at
  ignore(self.eat('-'))
  match self.digits_dots() {
    Some(_) => Some(String::from_array(self.s[was:self.at]))
    None => {
      self.at = was
      None
    }
  }
}

///|
/// `\d+`.
fn Reader::digits(self : Reader) -> String? {
  let was = self.at
  while self.peek() is Some(c) && c >= '0' && c <= '9' {
    self.at += 1
  }
  if self.at > was {
    Some(String::from_array(self.s[was:self.at]))
  } else {
    None
  }
}

///|
/// The points along a mask's drawing's shape, on its page: its first subpath with curves, each curve in small steps.
/// Empty when it has no such shape.
fn outline_of(path : String) -> Array[(Double, Double)] {
  let mut points : Array[(Double, Double)] = []
  let mut curved = false
  let mut a = 1.0
  let mut b = 0.0
  let mut c = 0.0
  let mut d = 1.0
  let mut e = 0.0
  let mut f = 0.0
  let said : Array[Double] = []
  let mut at = (0.0, 0.0)
  for word in split_space(path) {
    let n = js_number(word)
    if word != "" && !n.is_nan() {
      said.push(n)
      continue
    }
    let k = said.length()
    let on_page = (x : Double, y : Double) => (a * x + c * y + e, b * x + d * y + f)
    let curve = (x1 : Double, y1 : Double, x2 : Double, y2 : Double, x3 : Double, y3 : Double) => {
      let (x0, y0) = at
      for i in 1..=CURVE_STEPS {
        let t = i.to_double() / CURVE_STEPS.to_double()
        let u = 1.0 - t
        points.push(
          on_page(
            u * u * u * x0 + 3.0 * u * u * t * x1 + 3.0 * u * t * t * x2 + t * t * t * x3,
            u * u * u * y0 + 3.0 * u * u * t * y1 + 3.0 * u * t * t * y2 + t * t * t * y3,
          ),
        )
      }
      at = (x3, y3)
      curved = true
    }
    let last = (i : Int) => if k - 6 + i >= 0 { said[k - 6 + i] } else { @double.not_a_number }
    let last4 = (i : Int) => if k - 4 + i >= 0 { said[k - 4 + i] } else { @double.not_a_number }
    if word == "cm" && k >= 6 {
      let (a2, b2, c2, d2, e2, f2) = (last(0), last(1), last(2), last(3), last(4), last(5))
      let (na, nb, nc, nd, ne, nf) = (
        a2 * a + b2 * c,
        a2 * b + b2 * d,
        c2 * a + d2 * c,
        c2 * b + d2 * d,
        e2 * a + f2 * c + e,
        e2 * b + f2 * d + f,
      )
      a = na
      b = nb
      c = nc
      d = nd
      e = ne
      f = nf
    } else if word == "m" {
      if curved {
        break
      }
      points = []
    }
    if (word == "m" || word == "l") && k >= 2 {
      at = (said[k - 2], said[k - 1])
      points.push(on_page(at.0, at.1))
    } else if word == "c" && k >= 6 {
      curve(last(0), last(1), last(2), last(3), last(4), last(5))
    } else if word == "v" && k >= 4 {
      curve(at.0, at.1, last4(0), last4(1), last4(2), last4(3))
    } else if word == "y" && k >= 4 {
      curve(last4(0), last4(1), last4(2), last4(3), last4(2), last4(3))
    }
    said.clear()
  }
  if curved {
    points
  } else {
    []
  }
}
