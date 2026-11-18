// A picture's or a film's size as it is shown, from the few bytes of it that say (station/src/sessions/image-size.ts
// `sizeOf`, the core's reading client/core-ts/src/mediaFacts.ts over bytes at hand): PNG, GIF and WebP in their first
// bytes; a JPEG in its frame's header, turned as its EXIF orientation says; an MP4 or QuickTime film in its picture
// track's header, turned as its matrix says, with its length and frames. Nothing is decoded; unknown bytes give None.
// (A file's facts, `shownFactsSoon`, are read by the station's files: the same reading over what it reads.)

///|
pub struct Facts {
  width : Double
  height : Double
  duration : Double?
  frames : Double?
} derive(Eq, Show)

///|
pub fn Facts::to_j(self : Facts) -> J {
  let fs = [("width", jn(self.width)), ("height", jn(self.height))]
  if self.duration is Some(d) {
    fs.push(("duration", jn(d)))
  }
  if self.frames is Some(f) {
    fs.push(("frames", jn(f)))
  }
  jo(fs)
}

///|
let chunk : Int = 64 * 1024

///|
let steps : Int = 256

///|
/// Where a picture's or film's bytes are read from: `size` of them, `read(at, n)` giving what there is of
/// [at, at + n) (fewer only at its end). Bytes at hand, or a file read a piece at a time (image-size.ts
/// `shownFactsSoon`: a film's moov box may be anywhere in 50 MB).
pub(all) struct Src {
  size : Double
  read : (Double, Int) -> Bytes
}

///|
pub fn Src::of_bytes(b : Bytes) -> Src {
  {
    size: b.length().to_double(),
    read: fn(at, n) {
      let a = at.to_int()
      b[a:@cmp.minimum(b.length(), a + n)].to_bytes()
    },
  }
}

///|
/// [at, at + n) of `b`, None where it is not all there (readSync's `get`).
fn get_(b : Src, at : Double, n : Int) -> BytesView? {
  if at < 0.0 || n < 0 {
    return None
  }
  if at > b.size {
    return if n == 0 { Some(b""[:]) } else { None }
  }
  if b.size - at >= n.to_double() {
    let got = (b.read)(at, n)
    if got.length() >= n { Some(got[0:n]) } else { None }
  } else {
    None
  }
}

///|
/// What there is from `at` on, up to a chunk (readSync's `rest`).
fn rest_(b : Src, at : Double) -> BytesView {
  if at < 0.0 || at >= b.size {
    return b""[:]
  }
  let n = @cmp.minimum(b.size - at, chunk.to_double()).to_int()
  (b.read)(at, n)[:]
}

///|
fn ascii(b : BytesView, at : Int, s : String) -> Bool {
  if b.length() < at + s.length() {
    return false
  }
  for i in 0..<s.length() {
    if b[at + i].to_int() != s.unsafe_charcode_at(i) {
      return false
    }
  }
  true
}

///|
fn ok_(width : Double, height : Double) -> Facts? {
  if width > 0.0 && height > 0.0 {
    Some({ width, height, duration: None, frames: None })
  } else {
    None
  }
}

///|
fn u8(b : BytesView, i : Int) -> UInt {
  b[i].to_uint()
}

///|
fn be16(b : BytesView, i : Int) -> UInt {
  (u8(b, i) << 8) | u8(b, i + 1)
}

///|
fn le16(b : BytesView, i : Int) -> UInt {
  (u8(b, i + 1) << 8) | u8(b, i)
}

///|
fn be32(b : BytesView, i : Int) -> UInt {
  (u8(b, i) << 24) | (u8(b, i + 1) << 16) | (u8(b, i + 2) << 8) | u8(b, i + 3)
}

///|
fn le32(b : BytesView, i : Int) -> UInt {
  (u8(b, i + 3) << 24) | (u8(b, i + 2) << 16) | (u8(b, i + 1) << 8) | u8(b, i)
}

///|
fn ud(u : UInt) -> Double {
  u.to_uint64().to_double()
}

///|
/// The size the picture's or film's bytes `b` say it is shown at, with what else a film says.
pub fn facts_of(b : Bytes) -> Facts? {
  facts_of_src(Src::of_bytes(b))
}

///|
/// The same, of bytes read where `b` says.
pub fn facts_of_src(b : Src) -> Facts? {
  let head = match get_(b, 0.0, 32) {
    Some(h) => h
    None => rest_(b, 0.0)
  }
  if head.length() >= 8 && ascii(head, 4, "ftyp") {
    return film_facts(b)
  }
  if head.length() >= 4 && head[0] == b'\xff' && head[1] == b'\xd8' {
    return jpeg_size(b)
  }
  header_size(head)
}

///|
/// image-size.ts `sizeOf`: [width, height].
pub fn size_of(b : Bytes) -> (Double, Double)? {
  match facts_of(b) {
    Some(f) => Some((f.width, f.height))
    None => None
  }
}

///|
/// A PNG's, GIF's or WebP's size, from its first bytes.
pub fn header_size(b : BytesView) -> Facts? {
  if b.length() >= 24 && b[0] == b'\x89' && ascii(b, 1, "PNG") && ascii(b, 12, "IHDR") {
    return ok_(ud(be32(b, 16)), ud(be32(b, 20)))
  }
  if b.length() >= 10 && (ascii(b, 0, "GIF87a") || ascii(b, 0, "GIF89a")) {
    return ok_(ud(le16(b, 6)), ud(le16(b, 8)))
  }
  if b.length() >= 30 && ascii(b, 0, "RIFF") && ascii(b, 8, "WEBP") {
    if ascii(b, 12, "VP8 ") && b[23] == b'\x9d' && b[24] == b'\x01' && b[25] == b'\x2a' {
      return ok_(ud(le16(b, 26) & 0x3fff), ud(le16(b, 28) & 0x3fff))
    }
    if ascii(b, 12, "VP8L") && b[20] == b'\x2f' {
      let bits = le32(b, 21)
      return ok_(ud(bits & 0x3fff) + 1.0, ud((bits >> 14) & 0x3fff) + 1.0)
    }
    if ascii(b, 12, "VP8X") {
      return ok_(
        ud(u8(b, 24) | (u8(b, 25) << 8) | (u8(b, 26) << 16)) + 1.0,
        ud(u8(b, 27) | (u8(b, 28) << 8) | (u8(b, 29) << 16)) + 1.0,
      )
    }
  }
  None
}

///|
fn jpeg_size(b : Src) -> Facts? {
  let mut at = 2.0
  let mut turned = false
  for _step in 0..<steps {
    guard get_(b, at, 4) is Some(m) else { return None }
    if m[0] != b'\xff' {
      return None
    }
    let kind = m[1].to_int()
    if kind == 0xff {
      at += 1.0
      continue
    }
    if kind == 0x01 || (kind >= 0xd0 && kind <= 0xd8) {
      at += 2.0
      continue
    }
    if kind == 0xd9 || kind == 0xda {
      return None
    }
    let len = (m[2].to_int() << 8) | m[3].to_int()
    if len < 2 {
      return None
    }
    if kind == 0xe1 {
      match get_(b, at + 4.0, len - 2) {
        Some(note) => turned = exif_turned(note).unwrap_or(turned)
        None => ()
      }
    } else if kind >= 0xc0 && kind <= 0xcf && kind != 0xc4 && kind != 0xc8 && kind != 0xcc {
      guard get_(b, at + 4.0, 5) is Some(f) else { return None }
      let height = ud(be16(f, 1))
      let width = ud(be16(f, 3))
      return if turned { ok_(height, width) } else { ok_(width, height) }
    }
    at += 2.0 + len.to_double()
  }
  None
}

///|
/// Whether an APP1 note says the picture is shown turned a quarter (orientation 5–8).
pub fn exif_turned(b : BytesView) -> Bool? {
  if b.length() < 14 || !ascii(b, 0, "Exif\u{0}\u{0}") {
    return None
  }
  let t = b[6:]
  let le = ascii(t, 0, "II")
  if !le && !ascii(t, 0, "MM") {
    return None
  }
  let u16 = (i : Int) => if i >= 0 && i + 2 <= t.length() {
    (if le { le16(t, i) } else { be16(t, i) }).reinterpret_as_int()
  } else {
    -1
  }
  let u32 = (i : Int) => if i >= 0 && i + 4 <= t.length() {
    ud(if le { le32(t, i) } else { be32(t, i) })
  } else {
    -1.0
  }
  if u16(2) != 42 {
    return None
  }
  // (the IFD's offset is always there: the note is 14 bytes or more; one past what an Int holds is past its end)
  let ifd = u32(4)
  if ifd > 2147483647.0 {
    return None
  }
  let ifd = ifd.to_int()
  let count = u16(ifd)
  if count < 0 {
    return None
  }
  for i in 0..<count {
    let e = ifd + 2 + i * 12
    if u16(e) == 0x0112 {
      let o = u16(e + 8)
      return if o < 0 { None } else { Some(o >= 5 && o <= 8) }
    }
  }
  None
}

///|
priv struct Box_ {
  kind : String
  start : Double
  end : Double
}

///|
fn box_at(b : Src, at : Double, end : Double) -> Box_? {
  let h = match get_(b, at, 16) {
    Some(h) => h
    None => rest_(b, at)
  }
  if h.length() < 8 {
    return None
  }
  let kind = String::from_array([
    h[4].to_int().unsafe_to_char(),
    h[5].to_int().unsafe_to_char(),
    h[6].to_int().unsafe_to_char(),
    h[7].to_int().unsafe_to_char(),
  ])
  let mut size = ud(be32(h, 0))
  let mut start = at + 8.0
  if size == 1.0 {
    if h.length() < 16 {
      return None
    }
    size = ud(be32(h, 8)) * 4294967296.0 + ud(be32(h, 12))
    start = at + 16.0
  } else if size == 0.0 {
    size = end - at
  }
  if size < start - at || at + size > end {
    return None
  }
  Some({ kind, start, end: at + size })
}

///|
fn child(b : Src, start : Double, end : Double, kind : String) -> Box_? {
  let mut at = start
  for _step in 0..<steps {
    if !(at < end) {
      break
    }
    guard box_at(b, at, end) is Some(x) else { return None }
    if x.kind == kind {
      return Some(x)
    }
    at = x.end
  }
  None
}

///|
fn film_facts(b : Src) -> Facts? {
  guard child(b, 0.0, 9007199254740991.0, "moov") is Some(moov) else { return None }
  let mut at = moov.start
  for _step in 0..<steps {
    if !(at < moov.end) {
      break
    }
    guard box_at(b, at, moov.end) is Some(x) else { return None }
    if x.kind == "trak" {
      let size = match child(b, x.start, x.end, "tkhd") {
        Some(tkhd) => track_size(b, tkhd)
        None => None
      }
      if size is Some(s) {
        let (duration, frames) = film_time(b, moov, x)
        return Some({ ..s, duration, frames })
      }
    }
    at = x.end
  }
  None
}

///|
fn film_time(b : Src, moov : Box_, trak : Box_) -> (Double?, Double?) {
  let mdia = child(b, trak.start, trak.end, "mdia")
  let mdhd = match mdia {
    Some(m) => child(b, m.start, m.end, "mdhd")
    None => None
  }
  let mvhd = child(b, moov.start, moov.end, "mvhd")
  let from_mdhd = match mdhd {
    Some(h) => time_of(b, h)
    None => None
  }
  let ms = match from_mdhd {
    Some(v) => Some(v)
    None =>
      match mvhd {
        Some(h) => time_of(b, h)
        None => None
      }
  }
  let duration = match ms {
    Some(v) => if v != 0.0 { Some(v) } else { None }
    None => None
  }
  let minf = match mdia {
    Some(m) => child(b, m.start, m.end, "minf")
    None => None
  }
  let stbl = match minf {
    Some(m) => child(b, m.start, m.end, "stbl")
    None => None
  }
  let mut frames = None
  if stbl is Some(s) {
    let sizes = match child(b, s.start, s.end, "stsz") {
      Some(x) => Some(x)
      None => child(b, s.start, s.end, "stz2")
    }
    let count = match sizes {
      Some(x) => get_(b, x.start + 8.0, 4)
      None => None
    }
    let n = match count {
      Some(c) => ud(be32(c, 0))
      None => 0.0
    }
    if n > 0.0 {
      frames = Some(n)
    }
  }
  (duration, frames)
}

///|
fn time_of(b : Src, header : Box_) -> Double? {
  guard get_(b, header.start, 1) is Some(version) else { return None }
  let wide = version[0] == b'\x01'
  guard get_(b, header.start + (if wide { 20.0 } else { 12.0 }), if wide { 12 } else { 8 }) is Some(v) else {
    return None
  }
  let scale = ud(be32(v, 0))
  let length = if wide { ud(be32(v, 4)) * 4294967296.0 + ud(be32(v, 8)) } else { ud(be32(v, 4)) }
  let unknown = if wide {
    be32(v, 4) == 0xffffffff && be32(v, 8) == 0xffffffff
  } else {
    length == 4294967295.0
  }
  if scale == 0.0 || length == 0.0 || unknown {
    return None
  }
  let ms = js_round(length * 1000.0 / scale)
  if ms > 0.0 && ms <= 9007199254740991.0 {
    Some(ms)
  } else {
    None
  }
}

///|
/// `Math.round`.
pub fn js_round(x : Double) -> Double {
  if x.is_nan() || x.is_inf() {
    return x
  }
  (x + 0.5).floor()
}

///|
fn track_size(b : Src, tkhd : Box_) -> Facts? {
  guard get_(b, tkhd.start, 1) is Some(version) else { return None }
  let matrix = tkhd.start + (if version[0] == b'\x01' { 52.0 } else { 40.0 })
  guard get_(b, matrix, 44) is Some(v) else { return None }
  if matrix + 44.0 > tkhd.end {
    return None
  }
  let width = js_round(ud(be32(v, 36)) / 65536.0)
  let height = js_round(ud(be32(v, 40)) / 65536.0)
  let i32 = (i : Int) => be32(v, i).reinterpret_as_int()
  let turned = i32(0) == 0 && i32(16) == 0 && i32(4) != 0
  if turned {
    ok_(height, width)
  } else {
    ok_(width, height)
  }
}
