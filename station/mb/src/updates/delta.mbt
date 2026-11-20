// delta.ts: applying a delta (scripts/delta.ts makes them, and says the format at its head): what turns the files a
// device already has into a release's package. The station applies one to its installed release to make the next
// release's raw archive (release.ts), in a process apart: the old blob is tens of MB.

///|
pub struct Range {
  at : Double
  len : Double
}

///|
pub struct Header {
  files : Array[String]
  inflate : Array[Range]
  old_size : Double
  old_sha256 : String
  deflate : Array[Range]
  made_size : Double
  /// Where the chunks begin.
  payload : Int
}

///|
pub let delta_magic : Bytes = b"SFDELTA1"

///|
pub let chunk_size : Int = 1 << 20

///|
let two32 : Double = 4294967296.0

///|
fn u32le(d : Bytes, at : Int) -> Double {
  (d[at].to_uint() | (d[at + 1].to_uint() << 8) | (d[at + 2].to_uint() << 16) | (d[at + 3].to_uint() << 24)).to_double()
}

///|
fn i32le(d : Bytes, at : Int) -> Int {
  d[at].to_int() | (d[at + 1].to_int() << 8) | (d[at + 2].to_int() << 16) | (d[at + 3].to_int() << 24)
}

///|
/// `checkPath`: refuses a path that could reach outside the folder it is read in.
pub fn check_path(path : String) -> Unit raise {
  let bad = path == "" ||
    starts_with(path, "/") ||
    (path.length() >= 2 &&
    cu(path, 1) == 58 &&
    {
      let c = cu(path, 0)
      (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }) ||
    includes(path, "\\") ||
    includes(path, "\u{0}") ||
    split(path, "/").iter().any(part => part == "" || part == "..")
  if bad {
    raise fail("the delta names a path an applier refuses: \{stringify(js(path))}")
  }
}

///|
/// UTF-8 as `new TextDecoder("utf-8", { fatal: true })` takes it: none where it is not UTF-8; a leading BOM dropped.
fn strict_utf8(b : Bytes) -> String? {
  let n = b.length()
  let mut i = 0
  while i < n {
    let c = b[i].to_int()
    let (need, min) = if c < 0x80 {
      (0, 0)
    } else if c >= 0xc2 && c <= 0xdf {
      (1, 0x80)
    } else if c >= 0xe0 && c <= 0xef {
      (2, 0x800)
    } else if c >= 0xf0 && c <= 0xf4 {
      (3, 0x10000)
    } else {
      return None
    }
    if need > 0 && i + need >= n {
      return None
    }
    let mut v = if need == 0 { c } else if need == 1 { c & 0x1f } else if need == 2 { c & 0x0f } else { c & 0x07 }
    for k in 1..=need {
      let x = b[i + k].to_int()
      if (x & 0xc0) != 0x80 {
        return None
      }
      v = (v << 6) | (x & 0x3f)
    }
    if need > 0 && (v < min || v > 0x10ffff || (v >= 0xd800 && v <= 0xdfff)) {
      return None
    }
    i += need + 1
  }
  let s = @utf8.decode_lossy(b)
  Some(if s.length() > 0 && cu(s, 0) == 0xfeff { slice(s, 1) } else { s })
}

///|
/// `parseHeader`: the header of a delta, refused when it is not one an applier takes.
pub fn parse_header(d : Bytes) -> Header raise {
  if d.length() < 8 || d[0:8].to_owned() != delta_magic {
    raise fail("not a delta (bad magic)")
  }
  let mut p = 8
  let need = (n : Int) => if p + n > d.length() { raise fail("the delta's header is cut short") }
  let u32 = () => {
    need(4)
    p += 4
    u32le(d, p - 4)
  }
  let u64 = () => {
    need(8)
    let hi = u32le(d, p + 4)
    if hi > 2097151.0 {
      raise fail("the delta's header has a number too large")
    }
    p += 8
    hi * two32 + u32le(d, p - 8)
  }
  let ranges = (what : String) => {
    let list : Array[Range] = []
    let mut n = u32()
    let mut end = 0.0
    while n > 0.0 {
      let at = u64()
      let len = u64()
      if at < end {
        raise fail("the delta's \{what} ranges are not ascending")
      }
      end = at + len
      list.push({ at, len })
      n -= 1.0
    }
    list
  }
  let files : Array[String] = []
  let mut n = u32()
  while n > 0.0 {
    need(2)
    let len = d[p].to_int() | (d[p + 1].to_int() << 8)
    p += 2
    need(len)
    let path = match strict_utf8(d[p:p + len].to_owned()) {
      Some(s) => s
      None => raise fail("the delta names a path that is not UTF-8")
    }
    check_path(path)
    files.push(path)
    p += len
    n -= 1.0
  }
  let inflate = ranges("inflate")
  let old_size = u64()
  need(32)
  let old_sha256 = hex(d[p:p + 32].to_owned())
  p += 32
  let deflate = ranges("deflate")
  let made_size = u64()
  if files.length() > 0 && inflate.length() > 0 {
    raise fail("the delta names both files and an apk's ranges")
  }
  if deflate.length() > 0 {
    let last = deflate[deflate.length() - 1]
    if last.at + last.len > made_size {
      raise fail("the delta's deflate ranges go past made_size")
    }
  }
  { files, inflate, old_size, old_sha256, deflate, made_size, payload: p }
}

///|
/// Raw deflate undone, at most `most` bytes made (`inflateRawSync` with `maxOutputLength`); none where it does not
/// inflate.
fn inflate_raw(b : Bytes, most : Int) -> Bytes? {
  match inflate(b, size=most) {
    Some(out) if out.length() <= most => Some(out)
    _ => None
  }
}

///|
/// The delta's chunks read in order, each inflated as it is reached.
priv struct Chunks {
  d : Bytes
  mut at : Int
  mut buf : Bytes
  mut pos : Int
}

///|
fn Chunks::next(self : Chunks) -> Bool raise {
  let d = self.d
  if self.at + 8 > d.length() {
    raise fail("the delta has no end chunk")
  }
  let raw = u32le(d, self.at)
  let packed = u32le(d, self.at + 4)
  self.at += 8
  if raw == 0.0 {
    if packed != 0.0 || self.at != d.length() {
      raise fail("the delta goes on after its end chunk")
    }
    return false
  }
  if raw > chunk_size.to_double() {
    raise fail("a chunk of \{num_text(raw)} bytes, more than \{chunk_size}")
  }
  if self.at.to_double() + packed > d.length().to_double() {
    raise fail("the delta has no end chunk (a chunk is cut short)")
  }
  let r = raw.to_int()
  let p = packed.to_int()
  let made = match inflate_raw(d[self.at:self.at + p].to_owned(), r) {
    Some(b) => b
    None => raise fail("a chunk does not inflate to its raw_len")
  }
  if made.length() != r {
    raise fail("a chunk does not inflate to its raw_len")
  }
  self.buf = made
  self.at += p
  self.pos = 0
  true
}

///|
/// How many of at most `max` bytes are at hand now (at least one), from `buf` at `pos`.
fn Chunks::take(self : Chunks, max : Int) -> Int raise {
  while self.pos == self.buf.length() {
    if !self.next() {
      raise fail("the delta's stream ends early")
    }
  }
  let left = self.buf.length() - self.pos
  if max < left {
    max
  } else {
    left
  }
}

///|
fn Chunks::end(self : Chunks) -> Unit raise {
  if self.pos != self.buf.length() || self.next() {
    raise fail("the delta's stream goes on past made_size")
  }
}

///|
/// `patch` (bspatch): the made bytes, handed to `sink` in order, a chunk's worth at a time.
pub async fn patch(h : Header, old : Bytes, d : Bytes, sink : async (Bytes) -> Unit) -> Unit {
  let r : Chunks = { d, at: h.payload, buf: b"", pos: 0 }
  let out = FixedArray::make(chunk_size, b'\x00')
  let ctrl = FixedArray::make(24, b'\x00')
  let oldsize = old.length().to_double()
  let made = h.made_size
  let mut fill = 0
  let mut o = 0.0
  let mut p = 0.0
  let flush = async fn(n : Int) { sink(Bytes::makei(n, i => out[i])) }
  let room = async fn() -> Int {
    if fill == chunk_size {
      flush(chunk_size)
      fill = 0
    }
    chunk_size - fill
  }
  let i64 = (at : Int) => {
    let c = Bytes::makei(8, i => ctrl[at + i])
    let hi = i32le(c, 4)
    if hi > 0x1fffff || hi < -0x200000 {
      raise fail("a record's number is too large")
    }
    hi.to_double() * two32 + u32le(c, 0)
  }
  while o < made {
    let mut got = 0
    while got < 24 {
      let k = r.take(24 - got)
      for i in 0..<k {
        ctrl[got + i] = r.buf[r.pos + i]
      }
      r.pos += k
      got += k
    }
    let x = i64(0)
    let y = i64(8)
    let z = i64(16)
    if x < 0.0 || y < 0.0 {
      raise fail("a record with a negative length")
    }
    if x > made - o || y > made - o - x {
      raise fail("a record goes past made_size")
    }
    let mut left = x
    while left > 0.0 {
      let space = room()
      let k = r.take(if left < space.to_double() { left.to_int() } else { space })
      let b = r.buf
      let s = r.pos
      if p >= 0.0 && p + k.to_double() <= oldsize {
        let pi = p.to_int()
        for i in 0..<k {
          out[fill + i] = (b[s + i].to_int() + old[pi + i].to_int()).to_byte()
        }
      } else {
        for i in 0..<k {
          let q = p + i.to_double()
          let was = if q >= 0.0 && q < oldsize { old[q.to_int()].to_int() } else { 0 }
          out[fill + i] = (b[s + i].to_int() + was).to_byte()
        }
      }
      r.pos += k
      fill += k
      p += k.to_double()
      left -= k.to_double()
    }
    left = y
    while left > 0.0 {
      let space = room()
      let k = r.take(if left < space.to_double() { left.to_int() } else { space })
      for i in 0..<k {
        out[fill + i] = r.buf[r.pos + i]
      }
      r.pos += k
      fill += k
      left -= k.to_double()
    }
    o += x + y
    p += z
  }
  r.end()
  if fill > 0 {
    flush(fill)
  }
}

///|
/// A sink deflating `ranges` of what it is given (each held whole while it comes) before handing it on.
priv struct Deflating {
  ranges : Array[Range]
  sink : async (Bytes) -> Unit
  deflate : async (Bytes) -> Bytes
  mut o : Double
  mut k : Int
  mut held : Buffer
  mut fill : Double
  mut holding : Bool
}

///|
async fn Deflating::write(self : Deflating, b : Bytes) -> Unit {
  let mut i = 0
  while i < b.length() ||
        (self.k < self.ranges.length() &&
        self.ranges[self.k].at == self.o &&
        self.ranges[self.k].len == 0.0) {
    let r = if self.k < self.ranges.length() { Some(self.ranges[self.k]) } else { None }
    match r {
      Some(r) if !(self.o < r.at) => {
        if !self.holding {
          self.held = Buffer()
          self.fill = 0.0
          self.holding = true
        }
        let want = r.len - self.fill
        let n = if (b.length() - i).to_double() < want { b.length() - i } else { want.to_int() }
        self.held.write_bytes(b[i:i + n].to_owned())
        self.fill += n.to_double()
        i += n
        self.o += n.to_double()
        if self.fill == r.len {
          (self.sink)((self.deflate)(self.held.to_bytes()))
          self.holding = false
          self.k += 1
        }
      }
      _ => {
        let n = match r {
          Some(r) => {
            let gap = r.at - self.o
            if (b.length() - i).to_double() < gap { b.length() - i } else { gap.to_int() }
          }
          None => b.length() - i
        }
        (self.sink)(b[i:i + n].to_owned())
        i += n
        self.o += n.to_double()
      }
    }
  }
}

///|
async fn Deflating::end(self : Deflating) -> Unit {
  self.write(b"")
  if self.k != self.ranges.length() || self.holding {
    raise fail("the made bytes end inside a deflate range")
  }
}

///|
/// `apply`: the made package: bspatch, then the deflate ranges deflated.
pub async fn apply(
  h : Header,
  old : Bytes,
  d : Bytes,
  sink : async (Bytes) -> Unit,
  deflate : async (Bytes) -> Bytes,
) -> Unit {
  if h.deflate.length() == 0 {
    return patch(h, old, d, sink)
  }
  let w : Deflating = {
    ranges: h.deflate,
    sink,
    deflate,
    o: 0.0,
    k: 0,
    held: Buffer(),
    fill: 0.0,
    holding: false,
  }
  patch(h, old, d, b => w.write(b))
  w.end()
}

///|
/// What a delta is applied to: the folder of what is installed, or an apk.
pub(all) enum Old {
  Dir(String)
  Apk(String)
}

///|
/// `readOld`: the old blob a delta wants, checked against its size and sha256.
pub async fn read_old(w : World, h : Header, from : Old) -> Bytes {
  let blob = Buffer()
  match from {
    Dir(dir) => {
      if h.inflate.length() > 0 || h.deflate.length() > 0 {
        raise fail("an apk's delta, given a folder")
      }
      let mut total = 0.0
      for f in h.files {
        guard w.lstat_or_null(pjoin([dir, f]), sync=true) is Some(st) && st.file else {
          raise fail("the old file \{f} is not there")
        }
        total += st.size
      }
      if total != h.old_size {
        raise fail("the old files are \{num_text(total)} bytes, the delta's old blob \{num_text(h.old_size)}")
      }
      for f in h.files {
        blob.write_bytes(w.read_bytes(pjoin([dir, f]), sync=true))
      }
    }
    Apk(apk_path) => {
      if h.files.length() > 0 {
        raise fail("a folder's delta, given an apk")
      }
      let apk = w.read_bytes(apk_path, sync=true)
      let mut p = 0
      let most = if h.old_size > 1.0 { h.old_size.to_int() } else { 1 }
      for r in h.inflate {
        if r.at + r.len > apk.length().to_double() {
          raise fail("the delta's inflate ranges go past the old apk")
        }
        let at = r.at.to_int()
        let end = (r.at + r.len).to_int()
        if at > p {
          blob.write_bytes(apk[p:at].to_owned())
        }
        match inflate_raw(apk[at:end].to_owned(), most) {
          Some(b) => blob.write_bytes(b)
          None => raise fail("the old apk's bytes at \{num_text(r.at)} do not inflate")
        }
        p = end
      }
      if p < apk.length() {
        blob.write_bytes(apk[p:].to_owned())
      }
    }
  }
  let b = blob.to_bytes()
  if b.length().to_double() != h.old_size {
    raise fail("the old blob is \{b.length()} bytes, the delta's \{num_text(h.old_size)}")
  }
  if sha256(b) != h.old_sha256 {
    raise fail("the old blob's sha256 is not the delta's")
  }
  b
}

///|
/// `applyFile`: applies the delta file to what is installed, writing the made package to `out`; nothing is left on
/// failure.
pub async fn apply_file(
  w : World,
  from : Old,
  delta_path : String,
  out : String,
  deflate : async (Bytes) -> Bytes,
) -> Unit {
  let d = w.read_bytes(delta_path, sync=true)
  let h = parse_header(d)
  let old = read_old(w, h, from)
  w.write_bytes(out, b"")
  let buf = Buffer()
  let wrote : Result[Unit, Error] = try {
    apply(h, old, d, async fn(b) { buf.write_bytes(b) }, deflate)
    Ok(())
  } catch {
    e => Err(e)
  }
  match wrote {
    Ok(_) => w.write_bytes(out, buf.to_bytes())
    Err(e) => {
      w.rm(out, sync=true)
      raise e
    }
  }
}
