// JSON as the TypeScript of station/src/terminals and station/src/logins holds it (`@jsjson`: JSON.parse and
// JSON.stringify's own): an object's keys in the order they were set, strings by their UTF-16 units, numbers as
// JavaScript writes them, so what is written to a runner, a stream, a file or an agent is that TypeScript's byte for
// byte. And the few things of Node's they lean on: Buffer's base64, a Set's live order.

///|
pub using @jsjson {type JValue as J}

///|
pub fn js(s : String) -> J {
  @jsjson.JValue::of_string(s)
}

///|
pub fn jn(d : Double) -> J {
  @jsjson.JValue::of_double(d)
}

///|
pub fn ji(i : Int) -> J {
  @jsjson.JValue::of_int(i)
}

///|
pub fn jb(b : Bool) -> J {
  @jsjson.JValue::of_bool(b)
}

///|
pub fn jo(pairs : Array[(String, J)]) -> J {
  @jsjson.JValue::of_object(pairs)
}

///|
pub fn ja(items : Array[J]) -> J {
  @jsjson.JValue::of_array(items)
}

///|
pub fn jstrs(items : Array[String]) -> J {
  @jsjson.JValue::of_strings(items)
}

///|
/// `o[k]` where `o` is an object (None where it is not one, or has no `k`).
pub fn get(o : J?, k : String) -> J? {
  @jsjson.jval_at(o, k)
}

///|
pub fn text(j : J?) -> String? {
  match j {
    Some(Str(u)) => Some(@jsjson.raw_text(u))
    _ => None
  }
}

///|
pub fn num(j : J?) -> Double? {
  @jsjson.jval_num_of(j)
}

///|
pub fn stringify(j : J) -> String {
  @jsjson.stringify(j)
}

///|
pub fn parse(s : String) -> J raise {
  @jsjson.parse(s)
}

///|
/// `JSON.stringify(v, null, 2)`.
pub fn pretty(j : J) -> String {
  @jsjson.stringify_indent(j, 2)
}

///|
/// `String(v)`.
pub fn js_string_of(v : J) -> String {
  @jsjson.raw_text(@jsjson.js_string(v))
}

///|
/// `v ?? null`.
fn or_null(v : J?) -> J {
  match v {
    Some(x) => x
    None => Null
  }
}

///|
/// `Number.isInteger(n) && lo <= n && n <= hi`.
fn within(v : J?, lo : Int, hi : Int) -> Bool {
  match v {
    Some(Num(d)) => d == d.floor() && d >= lo.to_double() && d <= hi.to_double() && !d.is_inf()
    _ => false
  }
}

///|
fn int_of(v : J?) -> Int {
  match v {
    Some(Num(d)) => d.to_int()
    _ => 0
  }
}

///|
let b64_chars : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
/// `bytes.toString("base64")`.
pub fn base64_of(b : Bytes) -> String {
  let out = StringBuilder::new()
  let n = b.length()
  let mut i = 0
  while i + 2 < n {
    let v = (b[i].to_int() << 16) | (b[i + 1].to_int() << 8) | b[i + 2].to_int()
    out.write_char(b64_chars.get_char((v >> 18) & 63).unwrap())
    out.write_char(b64_chars.get_char((v >> 12) & 63).unwrap())
    out.write_char(b64_chars.get_char((v >> 6) & 63).unwrap())
    out.write_char(b64_chars.get_char(v & 63).unwrap())
    i += 3
  }
  if n - i == 1 {
    let v = b[i].to_int() << 16
    out.write_char(b64_chars.get_char((v >> 18) & 63).unwrap())
    out.write_char(b64_chars.get_char((v >> 12) & 63).unwrap())
    out.write_string("==")
  } else if n - i == 2 {
    let v = (b[i].to_int() << 16) | (b[i + 1].to_int() << 8)
    out.write_char(b64_chars.get_char((v >> 18) & 63).unwrap())
    out.write_char(b64_chars.get_char((v >> 12) & 63).unwrap())
    out.write_char(b64_chars.get_char((v >> 6) & 63).unwrap())
    out.write_char('=')
  }
  out.to_string()
}

///|
fn b64_value(c : Int) -> Int {
  if c >= 'A'.to_int() && c <= 'Z'.to_int() {
    c - 'A'.to_int()
  } else if c >= 'a'.to_int() && c <= 'z'.to_int() {
    c - 'a'.to_int() + 26
  } else if c >= '0'.to_int() && c <= '9'.to_int() {
    c - '0'.to_int() + 52
  } else if c == '+'.to_int() || c == '-'.to_int() {
    62
  } else if c == '/'.to_int() || c == '_'.to_int() {
    63
  } else {
    -1
  }
}

///|
/// `Buffer.from(s, "base64")`: either alphabet, what is not of it passed over, ended at the first `=`.
pub fn from_base64(s : String) -> Bytes {
  let out = @buffer.new()
  let mut acc = 0
  let mut bits = 0
  for i in 0..<s.length() {
    let c = s.code_unit_at(i).to_int()
    if c == '='.to_int() {
      break
    }
    let v = b64_value(c)
    if v < 0 {
      continue
    }
    acc = ((acc << 6) | v) & 0xFFFFFF
    bits += 6
    if bits >= 8 {
      bits -= 8
      out.write_byte(((acc >> bits) & 0xFF).to_byte())
    }
  }
  out.to_bytes()
}

///|
/// `Buffer.from(s)` (UTF-8, a lone surrogate as U+FFFD).
pub fn utf8_of(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
/// `bytes.toString("utf8")`.
pub fn utf8_text(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}

///|
/// Listeners as a Set keeps them: in the order added, a call going over them seeing one added meanwhile and not one
/// taken out (each by the id `add` gave).
pub struct Listeners[T] {
  priv entries : Array[(Int, T?)]
  priv mut next : Int
  priv mut live : Int
}

///|
pub fn[T] Listeners::new() -> Listeners[T] {
  { entries: [], next: 0, live: 0 }
}

///|
pub fn[T] Listeners::add(self : Listeners[T], f : T) -> Int {
  self.next += 1
  self.entries.push((self.next, Some(f)))
  self.live += 1
  self.next
}

///|
pub fn[T] Listeners::delete(self : Listeners[T], id : Int) -> Unit {
  for i, e in self.entries {
    if e.0 == id && e.1 is Some(_) {
      self.entries[i] = (id, None)
      self.live -= 1
      break
    }
  }
}

///|
pub fn[T] Listeners::size(self : Listeners[T]) -> Int {
  self.live
}

///|
pub fn[T] Listeners::each(self : Listeners[T], f : (T) -> Unit) -> Unit {
  let mut i = 0
  while i < self.entries.length() {
    match self.entries[i].1 {
      Some(g) => f(g)
      None => ()
    }
    i += 1
  }
  // (what was taken out let go once none goes over them)
  if self.live == 0 {
    self.entries.clear()
  }
}

///|
/// `s.trimEnd()`.
pub fn js_trim_end(s : String) -> String {
  let mut j = s.length()
  while j > 0 && js_space(s.code_unit_at(j - 1).to_int()) {
    j -= 1
  }
  s.unsafe_substring(start=0, end=j)
}
