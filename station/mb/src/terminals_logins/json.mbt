// JSON as the TypeScript of station/src/terminals and station/src/logins holds it (`@jsjson`: JSON.parse and
// JSON.stringify's own): an object's keys in the order they were set, strings by their UTF-16 units, numbers as
// JavaScript writes them, so what is written to a runner, a stream, a file or an agent is that TypeScript's byte for
// byte. And the few things of Node's they lean on: Buffer's base64, a Set's live order.

///|
pub using @jsjson {
  type JValue as J, jval_str as js, jval_num as jn, jval_int as ji, jval_bool as jb, jval_obj as jo,
  jval_array as ja, jval_strs as jstrs, jval_at as get, jval_str_raw_of as text, jval_num_of as num, stringify,
  parse, stringify_pretty as pretty, jval_js_str_raw as js_string_of,
}

///|
using @jsjson {jval_or_null as or_null}

///|
pub using @codec {base64_decode_loose as from_base64}

///|
pub using @jscase {trim_end as js_trim_end}

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
