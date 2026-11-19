// What every part of the vault's service reads and writes records with: JSON as JavaScript has it (keys in their
// order, `JSON.stringify` and `JSON.parse` by station/vault_crypto's codec, a duplicate key's last value in its first
// place), the record's fields read as station/src/vault reads them (`typeof x === "string"`, truthiness), and the
// shapes it builds (a spread's key order: a key already there keeps its place, a new one goes last).

///|
/// What a tool or a route is told when it cannot go on (secrets.ts and signin.ts `Refused`): its words are the answer.
pub suberror Refused {
  Refused(String)
}

///|
pub impl Show for Refused with output(self, logger) {
  match self {
    Refused(m) => logger.write_string(m)
  }
}

///|
/// An error as `(e as Error).message` reads it.
pub fn message_of(e : Error) -> String {
  match e {
    Refused(m) => m
    @vault_crypto.Refused(m) => m
    @vault_crypto.DbError(m) => m
    Failure(m) => m
    _ => e.to_string()
  }
}

///|
pub using @vault_crypto {stringify}

///|
using @vault_crypto {parse_js as parse, js_number as num_text, js_string as js_text}

///|
using @jsjson {
  json_str as js, json_num as jn, json_int as ji, json_bool as jb, json_arr as jarr, json_strs as jstrs,
  json_obj as obj, json_at as get, json_str_at as gs, json_num_at as gn, json_arr_at as ga,
  json_strings_of as strings_of, json_truthy as truthy, js_includes as contains, js_starts as starts,
  js_ends as ends, js_uniq as uniq, js_less as str_lt,
}

///|
using @jscase {trim, is_space as js_space}

///|
/// `JSON.parse(text)`, a text that is not JSON given as null.
fn parse_or_null(text : String) -> Json {
  @vault_crypto.parse_js(text) catch {
    _ => Json::null()
  }
}

///|
/// `o[k]` as a string, "" where it is none.
fn gtext(o : Json?, k : String) -> String {
  gs(o, k).unwrap_or("")
}

///|
/// `o.k` is present and not undefined (here: present).
fn has(o : Json?, k : String) -> Bool {
  get(o, k) is Some(_)
}


///|
/// `o.k = v` in place: a key there keeps its place, a new one goes last.
fn set(o : Json, k : String, v : Json) -> Unit {
  if o is Object(m) {
    m[k] = v
  }
}

///|
/// `delete o.k` in place.
fn unset(o : Json, k : String) -> Unit {
  if o is Object(m) {
    m.remove(k)
  }
}

///|
/// `{ ...o }`: a shallow copy.
fn copy(o : Json) -> Json {
  match o {
    Object(m) => {
      let c : Map[String, Json] = Map([])
      for k, v in m {
        c[k] = v
      }
      Json::object(c)
    }
    Array(a) => Json::array(a.copy())
    x => x
  }
}

///|
/// `{ ...o, ...more }`.
fn spread(o : Json?, more : Array[(String, Json)]) -> Json {
  let c : Map[String, Json] = Map([])
  if o is Some(Object(m)) {
    for k, v in m {
      c[k] = v
    }
  }
  for f in more {
    c[f.0] = f.1
  }
  Json::object(c)
}

///|
/// `{ ...o }` without `k` (`const { k: _, ...rest } = o`).
fn without(o : Json, k : String) -> Json {
  let c = copy(o)
  unset(c, k)
  c
}





///|
/// `Number.isSafeInteger(v)`.
fn safe_int(v : Json?) -> Bool {
  v is Some(Number(n, ..)) && @jsjson.is_safe_integer(n)
}

///|
/// `JSON.stringify(s)`: a string quoted as JS quotes it.
fn quoted(s : String) -> String {
  stringify(Json::string(s))
}

///|
/// `s.toLowerCase()` (ASCII and the common Latin letters; what an email or a host holds).
fn lower(s : String) -> String {
  s.to_lower()
}

///|
/// `s.toUpperCase()`.
fn upper(s : String) -> String {
  s.to_upper()
}

///|
/// `s.slice(a, b)` by UTF-16 units, as JS slices.
fn slice(s : String, a : Int, b? : Int) -> String {
  @jsjson.js_slice(s, a, end?=b)
}

///|
/// `s.split(sep).join(by)`: every `sep` in `s` replaced.
fn replace_all(s : String, sep : String, by : String) -> String {
  if sep == "" {
    s
  } else {
    s.replace_all(old=sep, new=by)
  }
}

///|
/// `xs.join(sep)`.
fn join(xs : Array[String], sep : String) -> String {
  xs.join(sep)
}

///|
/// The strings sorted as JS's default sort sorts them.
fn sorted(xs : Array[String]) -> Array[String] {
  let c = xs.copy()
  c.sort_by((a, b) => @jsjson.js_compare(a, b))
  c
}

///|
/// Whether every UTF-16 surrogate in `s` is paired (`s.isWellFormed()`).
fn well_formed(s : String) -> Bool {
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s.code_unit_at(i).to_int()
    if c >= 0xd800 && c <= 0xdbff {
      if i + 1 < n {
        let d = s.code_unit_at(i + 1).to_int()
        if d >= 0xdc00 && d <= 0xdfff {
          i += 2
          continue
        }
      }
      return false
    }
    if c >= 0xdc00 && c <= 0xdfff {
      return false
    }
    i += 1
  }
  true
}

///|
/// `new Date(seconds * 1000).toISOString()`.
fn iso(seconds : Double) -> String {
  iso_ms(seconds * 1000.0)
}

///|
/// `new Date(ms).toISOString()`.
fn iso_ms(ms : Double) -> String {
  @time.format_iso_ms(ms.floor().to_int64())
}

///|
let crockford : String = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

///|
/// A ULID: 48 bits of milliseconds, 80 random (secrets.ts `ulid`; its 16 random characters each a random byte mod 32).
pub fn ulid(ms : Double, random : Bytes) -> String {
  let t = StringBuilder()
  let digits : Array[Char] = []
  let mut v = ms
  for _ in 0..<10 {
    let r = v - (v / 32.0).floor() * 32.0
    digits.push(crockford.code_unit_at(r.to_int()).to_int().unsafe_to_char())
    v = (v / 32.0).floor()
  }
  for i in 0..<10 {
    t.write_char(digits[9 - i])
  }
  for i in 0..<16 {
    let b = if i < random.length() { random[i].to_int() } else { 0 }
    t.write_char(crockford.code_unit_at(b % 32).to_int().unsafe_to_char())
  }
  t.to_string()
}

///|
/// The integer a run of decimal digits says; None where it holds anything else.
fn digits_int(s : String) -> Int? {
  if s == "" {
    return None
  }
  let mut n = 0
  for i in 0..<s.length() {
    let c = s.code_unit_at(i).to_int()
    if c < 48 || c > 57 {
      return None
    }
    n = n * 10 + (c - 48)
  }
  Some(n)
}
