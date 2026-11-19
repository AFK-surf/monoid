// The copies of a station's chats, its retirement and a chat's hand-over (station/src/replica, its AGENTS.md), in
// MoonBit: what the station is to these parts is a `World` (its store, its hub, the other stations over the mesh, its
// clock, its log and its words), each asked by name as station/src names the part and its method; the files are this
// package's own, asked of the shell (`fs.*`, `zstd.*`). What the TypeScript throws is `Thrown(kind, fields)`: its class
// (`Refused`, `Said`, `Gone`, `AskAgain`, `Error`) and what it carries (`message`, a system failure's `code`).

///|
using @jsjson {type JValue as J}

///|
pub(all) suberror Thrown {
  Thrown(String, J)
}

///|
pub impl Show for Thrown with output(self, logger) {
  match self {
    Thrown(kind, said) => logger.write_string("\{kind}: \{text_at(said, "message")}")
  }
}

///|
/// What a thrown error says (`(e as Error).message`).
pub fn message_of(e : Error) -> String {
  match e {
    Thrown(_, said) => text_at(said, "message")
    Failure(m) => m
    e => @session_storage.message_of(e)
  }
}

///|
/// The class station/src throws it as.
pub fn kind_of(e : Error) -> String {
  match e {
    Thrown(k, _) => k
    @session_storage.Thrown(k, _) => k
    _ => "Error"
  }
}

///|
/// A system failure's code (`ENOENT`, `ENOSPC`...), as node:fs gives it; "" where none.
pub fn code_of(e : Error) -> String {
  match e {
    Thrown(_, said) => text_at(said, "code")
    @session_storage.Thrown(_, said) =>
      match said {
        Object(o) => if o.get("code") is Some(String(c)) { c } else { "" }
        _ => ""
      }
    e => {
      let c = @session_storage.code_of(e)
      if c == "EIO" && !message_of(e).contains("EIO") {
        ""
      } else {
        c
      }
    }
  }
}

///|
pub fn refused(message : String) -> Thrown {
  Thrown("Refused", jo([("message", js(message))]))
}

///|
pub fn failed(message : String) -> Thrown {
  Thrown("Error", jo([("message", js(message))]))
}

///|
/// move/module.ts `Said`: words a person reads, as they are.
pub fn said(message : String) -> Thrown {
  Thrown("Said", jo([("message", js(message))]))
}

///|
pub fn is_refused(e : Error) -> Bool {
  kind_of(e) == "Refused"
}

// ── JSON as JavaScript has it ──

///|
pub fn js(s : String) -> J {
  @jsjson.JValue::of_string(s)
}

///|
pub fn jn(n : Double) -> J {
  @jsjson.JValue::of_double(n)
}

///|
pub fn ji(n : Int) -> J {
  @jsjson.JValue::of_int(n)
}

///|
pub fn jb(b : Bool) -> J {
  @jsjson.JValue::of_bool(b)
}

///|
pub fn jo(fields : Array[(String, J)]) -> J {
  @jsjson.JValue::of_object(fields)
}

///|
pub fn ja(xs : Array[J]) -> J {
  @jsjson.JValue::of_array(xs)
}

///|
pub fn jopt(s : String?) -> J {
  @jsjson.JValue::of_opt_string(s)
}

///|
pub fn jstrs(xs : Array[String]) -> J {
  @jsjson.JValue::of_strings(xs)
}

///|
/// `v[key]` (None where it is no object or has none).
pub fn at(v : J, key : String) -> J? {
  @jsjson.jval_at(Some(v), key)
}

///|
pub fn str_of(v : J?) -> String? {
  @jsjson.jval_str_of(v)
}

///|
pub fn num_of(v : J?) -> Double? {
  @jsjson.jval_num_of(v)
}

///|
pub fn text_at(v : J, key : String) -> String {
  @jsjson.jval_text(at(v, key))
}

///|
pub fn str_at(v : J, key : String) -> String? {
  str_of(at(v, key))
}

///|
pub fn num_at(v : J, key : String) -> Double? {
  num_of(at(v, key))
}

///|
pub fn yes_at(v : J, key : String) -> Bool {
  @jsjson.jval_is_true(at(v, key))
}

///|
pub fn items(v : J?) -> Array[J] {
  @jsjson.jval_arr(v)
}

///|
/// The strings of an array (what is not one left out).
pub fn strings_of(v : J?) -> Array[String] {
  items(v).filter_map(x => str_of(Some(x)))
}

///|
pub fn is_nullish(v : J?) -> Bool {
  @jsjson.jval_nullish(v)
}

///|
/// An object's entries as names and values (none: not an object).
pub fn entries(v : J?) -> Array[(String, J)] {
  @jsjson.jval_entries(v)
}

///|
/// `Object.fromEntries(Object.entries(v ?? {}).filter(([, x]) => typeof x === "string"))`.
pub fn string_map(v : J?) -> Array[(String, String)] {
  entries(v).filter_map(e => match e.1 {
    Str(u) => Some((e.0, @jsjson.text(u)))
    _ => None
  })
}

///|
pub fn pairs_json(xs : Array[(String, String)]) -> J {
  jo(xs.map(p => (p.0, js(p.1))))
}

///|
pub fn pair_get(xs : Array[(String, String)], key : String) -> String? {
  for p in xs {
    if p.0 == key {
      return Some(p.1)
    }
  }
  None
}

///|
/// `o[key] = v` on an object (made anew; a key there keeps its place, a new one goes last).
pub fn set(v : J, key : String, x : J) -> J {
  @jsjson.jval_set_or_new(v, key, x)
}

///|
/// `delete o[key]`.
pub fn unset(v : J, key : String) -> J {
  @jsjson.jval_del(v, key)
}

///|
/// `{...a, ...b}`.
pub fn merged(a : J, b : J) -> J {
  @jsjson.jval_spread(a, b)
}

///|
pub fn stringify(v : J) -> String {
  @jsjson.stringify(v)
}

///|
pub fn parse(text : String) -> J raise {
  @jsjson.parse(text)
}

///|
/// The number as String(n) says it.
pub fn num_text(n : Double) -> String {
  @jsjson.num_text(n)
}

///|
/// `x.toFixed(1)` of a non-negative number.
pub fn fixed1(x : Double) -> String {
  let n = (x * 10.0 + 0.5).floor()
  let whole = (n / 10.0).floor()
  let tenth = (n - whole * 10.0).to_int()
  "\{num_text(whole)}.\{tenth}"
}

///|
/// `${(n / 1024 ** 3).toFixed(1)} GB`.
pub fn gb(n : Double) -> String {
  "\{fixed1(n / (1024.0 * 1024.0 * 1024.0))} GB"
}

///|
pub fn sha256_text(s : String) -> String {
  @memory.sha256_hex(@utf8.encode(s))
}

///|
/// `Math.round`.
pub fn js_round(x : Double) -> Double {
  @jsjson.js_round(x)
}

///|
/// `Math.trunc`.
pub fn js_trunc(x : Double) -> Double {
  if x < 0.0 {
    x.ceil()
  } else {
    x.floor()
  }
}

///|
/// `[...new Set(xs)]`.
pub fn uniq(xs : Array[String]) -> Array[String] {
  let seen : Map[String, Bool] = {}
  let out = []
  for x in xs {
    if !seen.contains(x) {
      seen[x] = true
      out.push(x)
    }
  }
  out
}

///|
/// `s.slice(0, n)` by UTF-16 units.
pub fn head_of(s : String, n : Int) -> String {
  if s.length() <= n {
    s
  } else {
    s.unsafe_substring(start=0, end=n)
  }
}

///|
pub fn ends_with(s : String, suffix : String) -> Bool {
  s.has_suffix(suffix)
}

///|
pub fn starts_with(s : String, prefix : String) -> Bool {
  s.has_prefix(prefix)
}

///|
/// `a < b` as JavaScript compares strings (by UTF-16 units).
pub fn js_less(a : String, b : String) -> Bool {
  @jsjson.js_compare(a, b) < 0
}

///|
pub fn js_cmp(a : String, b : String) -> Int {
  let c = @jsjson.js_compare(a, b)
  if c < 0 {
    -1
  } else if c > 0 {
    1
  } else {
    0
  }
}

// ── names a copy is made of (format.ts) ──

///|
fn all_of(s : String, f : (Int) -> Bool) -> Bool {
  for i in 0..<s.length() {
    if !f(s.unsafe_charcode_at(i)) {
      return false
    }
  }
  true
}

///|
fn is_hex_char(c : Int) -> Bool {
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
}

///|
fn is_digit(c : Int) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// `WORKSPACE`: /^[0-9A-Za-z_-]{1,64}$/.
pub fn is_workspace(s : String) -> Bool {
  s.length() >= 1 &&
  s.length() <= 64 &&
  all_of(s, c => is_digit(c) ||
    (c >= 'A' && c <= 'Z') ||
    (c >= 'a' && c <= 'z') ||
    c == '_' ||
    c == '-')
}

///|
/// `STATION`: /^[0-9a-f]{64}$/.
pub fn is_station(s : String) -> Bool {
  s.length() == 64 && all_of(s, is_hex_char)
}

///|
/// `HASH`: /^[0-9a-f]{64}$/.
pub fn is_hash(s : String) -> Bool {
  is_station(s)
}

///|
/// `GEN`: /^[0-9a-z]{1,16}-[0-9a-f]{8}$/.
pub fn is_gen(s : String) -> Bool {
  let n = s.length()
  if n < 10 || n > 25 || s.unsafe_charcode_at(n - 9) != '-' {
    return false
  }
  let first = s.unsafe_substring(start=0, end=n - 9)
  let last = s.unsafe_substring(start=n - 8, end=n)
  all_of(first, c => is_digit(c) || (c >= 'a' && c <= 'z')) && all_of(last, is_hex_char)
}

///|
/// `BATCH`: /^(\d{10})-(\d{10})-[0-9a-f]{8}\.ndjson\.zst$/.
pub fn is_batch(s : String) -> Bool {
  let suffix = ".ndjson.zst"
  if s.length() != 10 + 1 + 10 + 1 + 8 + suffix.length() || !s.has_suffix(suffix) {
    return false
  }
  all_of(s.unsafe_substring(start=0, end=10), is_digit) &&
  s.unsafe_charcode_at(10) == '-' &&
  all_of(s.unsafe_substring(start=11, end=21), is_digit) &&
  s.unsafe_charcode_at(21) == '-' &&
  all_of(s.unsafe_substring(start=22, end=30), is_hex_char)
}

///|
/// `/^[0-9a-z-]{1,80}$/`: a hand-over's id.
pub fn is_handover_id(s : String) -> Bool {
  s.length() >= 1 && s.length() <= 80 && all_of(s, c => is_digit(c) || (c >= 'a' && c <= 'z') || c == '-')
}
