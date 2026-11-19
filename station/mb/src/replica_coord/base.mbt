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
pub using @jsjson {
  jval_str as js, jval_num as jn, jval_int as ji, jval_bool as jb, jval_obj as jo, jval_array as ja,
  jval_opt_str as jopt, jval_strs as jstrs, jval_str_of as str_of, jval_num_of as num_of, jval_arr as items,
  jval_strings_of as strings_of, jval_nullish as is_nullish, jval_entries as entries, jval_set_or_new as set,
  jval_del as unset, jval_spread as merged, stringify, parse, num_text, js_round, js_trunc, js_uniq as uniq,
  js_slice_to as head_of, js_ends as ends_with, js_starts as starts_with, js_less,
}

///|
/// `v[key]` (None where it is no object or has none).
pub fn at(v : J, key : String) -> J? {
  @jsjson.jval_at(Some(v), key)
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
/// `Object.fromEntries(Object.entries(v ?? {}).filter(([, x]) => typeof x === "string"))`.
pub fn string_map(v : J?) -> Array[(String, String)] {
  entries(v).filter_map(e => match e.1 {
    Str(u) => Some((e.0, @jsjson.sanitize_str(u)))
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
