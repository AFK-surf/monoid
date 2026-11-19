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
  v is Some(Num(d)) && @jsjson.is_integer(d) && d >= lo.to_double() && d <= hi.to_double()
}

///|
fn int_of(v : J?) -> Int {
  match v {
    Some(Num(d)) => d.to_int()
    _ => 0
  }
}

///|
/// `bytes.toString("base64")`.
pub fn base64_of(b : Bytes) -> String {
  @codec.base64_encode(b[:])
}

///|
/// `Buffer.from(s, "base64")`: either alphabet, what is not of it passed over, ended at the first `=`.
pub fn from_base64(s : String) -> Bytes {
  @codec.base64_decode_loose(s)
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
  @jscase.trim_end(s)
}
