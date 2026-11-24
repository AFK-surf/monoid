// A PDF's objects, read from its bytes for the words on its pages (page.mbt). The file comes from elsewhere: every read
// is bounded, what is damaged reads as nothing, and nothing here aborts. Objects are found by walking the file, so a
// damaged cross-reference table costs nothing and a later update of an object wins as it does in a reader.

///|
/// A PDF object, or a keyword of a content stream (`Op`).
priv enum Obj {
  Null
  Num(Double)
  Str(Bytes)
  Name(String)
  List(Array[Obj])
  Dict(Map[String, Obj])
  Link(Int)
  /// a stream's dictionary, and where its bytes are in the file
  Stream(Map[String, Obj], Int, Int)
  Op(String)
}

///|
/// How deep arrays and dictionaries may nest.
const MOST_NESTED : Int = 64

///|
/// The largest file read for its words.
const MOST_FILE : Int = 134217728

///|
/// The most bytes one stream may decode to.
const MOST_STREAM : Int = 67108864

///|
/// The most bytes the streams read for one page (or for opening the file) may decode to.
const MOST_DECODED : Int = 134217728

///|
priv struct Lex {
  b : Bytes
  mut i : Int
  end : Int
  /// whether `N G R` is a link (a file's objects), or three operands (a content stream)
  links : Bool
}

///|
fn Lex::new(b : Bytes, i : Int, end : Int, links~ : Bool) -> Lex {
  { b, i: imax(i, 0), end: imin(end, b.length()), links }
}

///|
fn imin(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn imax(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn is_space(c : Int) -> Bool {
  c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32
}

///|
fn is_delim(c : Int) -> Bool {
  c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93 || c == 123 || c == 125 || c == 47 || c == 37
}

///|
fn Lex::peek(self : Lex) -> Int {
  if self.i < self.end {
    self.b[self.i].to_int()
  } else {
    -1
  }
}

///|
fn Lex::peek_at(self : Lex, k : Int) -> Int {
  if self.i + k < self.end {
    self.b[self.i + k].to_int()
  } else {
    -1
  }
}

///|
/// Past white space and comments.
fn Lex::skip(self : Lex) -> Unit {
  while self.i < self.end {
    let c = self.b[self.i].to_int()
    if is_space(c) {
      self.i += 1
    } else if c == 37 {
      while self.i < self.end && self.b[self.i].to_int() != 10 && self.b[self.i].to_int() != 13 {
        self.i += 1
      }
    } else {
      break
    }
  }
}

///|
fn hex_value(c : Int) -> Int {
  if c >= 48 && c <= 57 {
    c - 48
  } else if c >= 65 && c <= 70 {
    c - 55
  } else if c >= 97 && c <= 102 {
    c - 87
  } else {
    -1
  }
}

///|
fn Lex::name(self : Lex) -> Obj {
  self.i += 1
  let out = StringBuilder()
  while self.i < self.end {
    let c = self.b[self.i].to_int()
    if is_space(c) || is_delim(c) {
      break
    }
    if c == 35 && hex_value(self.peek_at(1)) >= 0 && hex_value(self.peek_at(2)) >= 0 {
      out.write_char((hex_value(self.peek_at(1)) * 16 + hex_value(self.peek_at(2))).unsafe_to_char())
      self.i += 3
    } else {
      out.write_char(c.unsafe_to_char())
      self.i += 1
    }
  }
  Name(out.to_string())
}

///|
fn Lex::literal(self : Lex) -> Obj {
  self.i += 1
  let out : Array[Byte] = []
  let mut depth = 1
  while self.i < self.end {
    let c = self.b[self.i].to_int()
    self.i += 1
    if c == 92 {
      let e = self.peek()
      self.i += 1
      match e {
        110 => out.push(b'\n')
        114 => out.push(b'\r')
        116 => out.push(b'\t')
        98 => out.push(b'\x08')
        102 => out.push(b'\x0C')
        13 => if self.peek() == 10 { self.i += 1 }
        10 => ()
        -1 => ()
        _ =>
          if e >= 48 && e <= 55 {
            let mut v = e - 48
            let mut k = 0
            while k < 2 && self.peek() >= 48 && self.peek() <= 55 {
              v = v * 8 + (self.peek() - 48)
              self.i += 1
              k += 1
            }
            out.push((v & 255).to_byte())
          } else {
            out.push(e.to_byte())
          }
      }
    } else if c == 40 {
      depth += 1
      out.push(c.to_byte())
    } else if c == 41 {
      depth -= 1
      if depth == 0 {
        break
      }
      out.push(c.to_byte())
    } else {
      out.push(c.to_byte())
    }
  }
  Str(Bytes::from_array(out))
}

///|
fn Lex::hex(self : Lex) -> Obj {
  self.i += 1
  let out : Array[Byte] = []
  let mut high = -1
  while self.i < self.end {
    let c = self.b[self.i].to_int()
    self.i += 1
    if c == 62 {
      break
    }
    let v = hex_value(c)
    if v >= 0 {
      if high < 0 {
        high = v
      } else {
        out.push((high * 16 + v).to_byte())
        high = -1
      }
    }
  }
  if high >= 0 {
    out.push((high * 16).to_byte())
  }
  Str(Bytes::from_array(out))
}

///|
/// A token as a number, if it is one.
fn number_of(b : Bytes, from : Int, to : Int) -> Double? {
  let mut i = from
  let mut neg = false
  while i < to && (b[i].to_int() == 43 || b[i].to_int() == 45) {
    if b[i].to_int() == 45 {
      neg = true
    }
    i += 1
  }
  let mut v = 0.0
  let mut digits = 0
  while i < to && b[i].to_int() >= 48 && b[i].to_int() <= 57 {
    v = v * 10.0 + (b[i].to_int() - 48).to_double()
    digits += 1
    i += 1
  }
  if i < to && b[i].to_int() == 46 {
    i += 1
    let mut unit = 0.1
    while i < to && b[i].to_int() >= 48 && b[i].to_int() <= 57 {
      v = v + (b[i].to_int() - 48).to_double() * unit
      unit = unit * 0.1
      digits += 1
      i += 1
    }
  }
  if i != to || digits == 0 {
    return None
  }
  Some(if neg { -v } else { v })
}

///|
fn Lex::word(self : Lex) -> Obj {
  let from = self.i
  while self.i < self.end {
    let c = self.b[self.i].to_int()
    if is_space(c) || is_delim(c) {
      break
    }
    self.i += 1
  }
  if self.i == from {
    // a delimiter that starts nothing
    self.i += 1
    return Op(ascii(self.b, from, self.i))
  }
  match number_of(self.b, from, self.i) {
    Some(v) => {
      if self.links && v >= 0.0 && v == v.floor() {
        let at = self.i
        self.skip()
        let g = self.i
        while self.peek() >= 48 && self.peek() <= 57 {
          self.i += 1
        }
        if self.i > g {
          self.skip()
          if self.peek() == 82 && (self.peek_at(1) < 0 || is_space(self.peek_at(1)) || is_delim(self.peek_at(1))) {
            self.i += 1
            return Link(v.to_int())
          }
        }
        self.i = at
      }
      Num(v)
    }
    None => {
      let s = ascii(self.b, from, self.i)
      match s {
        "true" | "false" | "null" => Null
        _ => Op(s)
      }
    }
  }
}

///|
fn ascii(b : Bytes, from : Int, to : Int) -> String {
  let out = StringBuilder()
  for i in from..<to {
    out.write_char(b[i].to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
/// The next object or keyword; None at the end.
fn Lex::next(self : Lex, depth? : Int = 0) -> Obj? {
  self.skip()
  let c = self.peek()
  if c < 0 {
    return None
  }
  if depth > MOST_NESTED {
    self.i = self.end
    return None
  }
  match c {
    47 => Some(self.name())
    40 => Some(self.literal())
    60 =>
      if self.peek_at(1) == 60 {
        self.i += 2
        let d : Map[String, Obj] = Map([])
        while true {
          match self.next(depth=depth + 1) {
            None => break
            Some(Op(">>")) => break
            Some(Name(k)) =>
              match self.next(depth=depth + 1) {
                None | Some(Op(">>")) => break
                Some(v) => d[k] = v
              }
            Some(_) => ()
          }
        }
        Some(Dict(d))
      } else {
        Some(self.hex())
      }
    62 =>
      if self.peek_at(1) == 62 {
        self.i += 2
        Some(Op(">>"))
      } else {
        self.i += 1
        Some(Op(">"))
      }
    91 => {
      self.i += 1
      let a : Array[Obj] = []
      while true {
        match self.next(depth=depth + 1) {
          None | Some(Op("]")) => break
          Some(v) => a.push(v)
        }
      }
      Some(List(a))
    }
    93 => {
      self.i += 1
      Some(Op("]"))
    }
    _ => Some(self.word())
  }
}

///|
/// A PDF's objects.
priv struct Objects {
  b : Bytes
  /// where each object's value starts in the file
  at : Map[Int, Int]
  /// those read (and those in object streams, read as they were found)
  read : Map[Int, Obj]
  mut root : Obj
  mut encrypted : Bool
  mut decoded : Int
}

///|
fn matches(b : Bytes, i : Int, word : String) -> Bool {
  if i < 0 || i + word.length() > b.length() {
    return false
  }
  for k in 0..<word.length() {
    if b[i + k].to_int() != word.code_unit_at(k).to_int() {
      return false
    }
  }
  true
}

///|
/// Where `word` next is from `i`, -1 if nowhere before `to`.
fn find(b : Bytes, word : String, i : Int, to : Int) -> Int {
  let first = word.code_unit_at(0).to_int()
  let last = imin(to, b.length()) - word.length()
  let mut k = imax(i, 0)
  while k <= last {
    if b[k].to_int() == first && matches(b, k, word) {
      return k
    }
    k += 1
  }
  -1
}

///|
/// The object number before the `obj` at `i` (`N G obj`), -1 if it is not one.
fn number_before(b : Bytes, i : Int) -> Int {
  let mut k = i - 1
  if k < 0 || !is_space(b[k].to_int()) {
    return -1
  }
  while k >= 0 && is_space(b[k].to_int()) {
    k -= 1
  }
  let gen_end = k
  while k >= 0 && b[k].to_int() >= 48 && b[k].to_int() <= 57 {
    k -= 1
  }
  if k == gen_end || k < 0 || !is_space(b[k].to_int()) {
    return -1
  }
  while k >= 0 && is_space(b[k].to_int()) {
    k -= 1
  }
  let end = k
  let mut n = 0
  let mut unit = 1
  let mut digits = 0
  while k >= 0 && b[k].to_int() >= 48 && b[k].to_int() <= 57 {
    digits += 1
    if digits > 9 {
      return -1
    }
    n += (b[k].to_int() - 48) * unit
    unit *= 10
    k -= 1
  }
  if k == end {
    -1
  } else {
    n
  }
}

///|
/// The object at `at`, a stream with where its bytes are; and where it ends.
fn read_value(b : Bytes, at : Int) -> (Obj, Int)? {
  let lex = Lex::new(b, at, b.length(), links=true)
  guard lex.next() is Some(v) else { return None }
  match v {
    Dict(d) => {
      lex.skip()
      if matches(b, lex.i, "stream") {
        let mut s = lex.i + 6
        if s < b.length() && b[s].to_int() == 13 {
          s += 1
        }
        if s < b.length() && b[s].to_int() == 10 {
          s += 1
        }
        // (its length, where it is said here and is right; else as far as its end's keyword)
        let by_len = match d.get("Length") {
          Some(Num(n)) if n >= 0.0 && n < b.length().to_double() => s + n.to_int()
          _ => -1
        }
        let e = if by_len >= 0 && by_len <= b.length() && find(b, "endstream", by_len, by_len + 16) >= 0 {
          by_len
        } else {
          match find(b, "endstream", s, b.length()) {
            -1 => b.length()
            k => k
          }
        }
        Some((Stream(d, s, e), e))
      } else {
        Some((v, lex.i))
      }
    }
    _ => Some((v, lex.i))
  }
}

///|
/// A file's objects, walked from its start.
fn Objects::scan(b : Bytes) -> Objects? {
  if b.length() > MOST_FILE || find(b, "%PDF-", 0, imin(1024, b.length())) < 0 {
    return None
  }
  let o : Objects = { b, at: Map([]), read: Map([]), root: Null, encrypted: false, decoded: 0 }
  let stms : Array[Int] = []
  let mut catalog = -1
  let mut i = 0
  let n = b.length()
  while i < n {
    let c = b[i].to_int()
    if c == 111 && matches(b, i, "obj") {
      let id = number_before(b, i)
      if id < 0 {
        i += 3
        continue
      }
      o.at[id] = i + 3
      o.read.remove(id)
      match read_value(b, i + 3) {
        Some((v, end)) => {
          match v {
            Stream(d, _, _) =>
              match d.get("Type") {
                Some(Name("ObjStm")) => stms.push(id)
                Some(Name("XRef")) => o.trailer(d)
                _ => ()
              }
            Dict(d) =>
              if d.get("Type") is Some(Name("Catalog")) {
                catalog = id
              }
            _ => ()
          }
          i = imax(end, i + 3)
        }
        None => i += 3
      }
    } else if c == 116 && matches(b, i, "trailer") {
      let lex = Lex::new(b, i + 7, n, links=true)
      match lex.next() {
        Some(Dict(d)) => {
          o.trailer(d)
          i = imax(lex.i, i + 7)
        }
        _ => i += 7
      }
    } else {
      i += 1
    }
  }
  if o.encrypted {
    return None
  }
  for id in stms {
    o.expand(id)
  }
  // (a catalog inside an object stream, or a trailer that names none)
  if o.root is Null {
    if catalog >= 0 {
      o.root = Link(catalog)
    } else {
      for id, v in o.read {
        if v is Dict(d) && d.get("Type") is Some(Name("Catalog")) {
          o.root = Link(id)
        }
      }
    }
  }
  if o.root is Null {
    None
  } else {
    Some(o)
  }
}

///|
fn Objects::trailer(self : Objects, d : Map[String, Obj]) -> Unit {
  match d.get("Root") {
    Some(Link(_) as r) => self.root = r
    _ => ()
  }
  if d.contains("Encrypt") {
    self.encrypted = true
  }
}

///|
/// The objects compressed in object stream `id`.
fn Objects::expand(self : Objects, id : Int) -> Unit {
  let s = self.get(Link(id))
  guard s is Stream(d, _, _) else { return }
  let count = self.int_of(d.get("N"), 0)
  let first = self.int_of(d.get("First"), 0)
  guard self.stream_bytes(s) is Some(data) else { return }
  guard count > 0 && first > 0 && first <= data.length() else { return }
  let head = Lex::new(data, 0, first, links=false)
  let pairs : Array[(Int, Int)] = []
  for _ in 0..<count {
    match (head.next(), head.next()) {
      (Some(Num(n)), Some(Num(off))) => pairs.push((n.to_int(), off.to_int()))
      _ => break
    }
  }
  for p in pairs {
    let at = first + p.1
    if at < 0 || at >= data.length() {
      continue
    }
    let lex = Lex::new(data, at, data.length(), links=true)
    match lex.next() {
      Some(v) => {
        // (one written again in the file after this stream keeps that later copy only if it came later: a stream's
        // own objects are this file's newest unless a plain object of the number stands)
        if !self.at.contains(p.0) {
          self.read[p.0] = v
        }
      }
      None => ()
    }
  }
}

///|
/// `v`, what it links to where it is a link.
fn Objects::get(self : Objects, v : Obj) -> Obj {
  let mut now = v
  let mut hops = 0
  while now is Link(id) {
    hops += 1
    if hops > 32 {
      return Null
    }
    now = match self.read.get(id) {
      Some(r) => r
      None =>
        match self.at.get(id) {
          Some(at) =>
            match read_value(self.b, at) {
              Some((r, _)) => {
                self.read[id] = r
                r
              }
              None => Null
            }
          None => Null
        }
    }
  }
  now
}

///|
fn Objects::of(self : Objects, v : Obj?) -> Obj {
  match v {
    Some(x) => self.get(x)
    None => Null
  }
}

///|
fn Objects::dict(self : Objects, v : Obj?) -> Map[String, Obj]? {
  match self.of(v) {
    Dict(d) | Stream(d, _, _) => Some(d)
    _ => None
  }
}

///|
fn Objects::num(self : Objects, v : Obj?, none : Double) -> Double {
  match self.of(v) {
    Num(n) => n
    _ => none
  }
}

///|
fn Objects::int_of(self : Objects, v : Obj?, none : Int) -> Int {
  match self.of(v) {
    Num(n) if n.abs() < 2147483647.0 => n.to_int()
    _ => none
  }
}

///|
fn Objects::name_of(self : Objects, v : Obj?) -> String {
  match self.of(v) {
    Name(s) => s
    _ => ""
  }
}

///|
/// Numbers of array `v`, each resolved.
fn Objects::nums(self : Objects, v : Obj?) -> Array[Double] {
  match self.of(v) {
    List(a) => a.map(fn(x) { self.num(Some(x), 0.0) })
    _ => []
  }
}

///|
/// What stream `s` holds, its filters undone; None for a filter that is not for words, or damaged.
fn Objects::stream_bytes(self : Objects, s : Obj) -> Bytes? {
  guard s is Stream(d, from, to) else { return None }
  let filters : Array[String] = match self.of(d.get("Filter")) {
    Name(f) => [f]
    List(a) => a.map(fn(x) { self.name_of(Some(x)) })
    _ => []
  }
  let parms : Array[Obj] = match self.of(d.get("DecodeParms")) {
    List(a) => a.map(fn(x) { self.get(x) })
    Dict(_) as p => [p]
    _ => []
  }
  let mut data : Bytes? = None
  let room = imin(MOST_STREAM, MOST_DECODED - self.decoded)
  if room <= 0 {
    return None
  }
  for k, f in filters {
    let now = match data {
      Some(x) => x
      None => slice(self.b, from, to)
    }
    let made = match f {
      "FlateDecode" | "Fl" => flate(now, room)
      "ASCII85Decode" | "A85" => Some(ascii85(now))
      "ASCIIHexDecode" | "AHx" => Some(ascii_hex(now))
      "LZWDecode" | "LZW" => lzw(now, room)
      _ => None
    }
    guard made is Some(m) else { return None }
    let undone = if k < parms.length() {
      self.predictor(m, parms[k])
    } else {
      Some(m)
    }
    guard undone is Some(u) else { return None }
    data = Some(u)
  }
  let out = match data {
    Some(x) => x
    None => slice(self.b, from, to)
  }
  self.decoded += out.length()
  Some(out)
}

///|
fn slice(b : Bytes, from : Int, to : Int) -> Bytes {
  let a = imax(from, 0)
  let e = imin(to, b.length())
  if e <= a {
    return b""
  }
  Bytes::makei(e - a, fn(i) { b[a + i] })
}
