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
/// `JSON.stringify(v)`.
pub fn stringify(v : Json) -> String {
  @vault_crypto.stringify(v)
}

///|
/// `JSON.parse(text)`, a text that is not JSON given as null.
fn parse_or_null(text : String) -> Json {
  @vault_crypto.parse_js(text) catch {
    _ => Json::null()
  }
}

///|
/// `JSON.parse(text)`.
fn parse(text : String) -> Json raise {
  @vault_crypto.parse_js(text)
}

///|
fn js(s : String) -> Json {
  Json::string(s)
}

///|
fn jn(n : Double) -> Json {
  Json::number(n)
}

///|
fn ji(n : Int) -> Json {
  Json::number(n.to_double())
}

///|
fn jb(b : Bool) -> Json {
  Json::boolean(b)
}

///|
fn jarr(xs : Array[Json]) -> Json {
  Json::array(xs)
}

///|
fn jstrs(xs : Array[String]) -> Json {
  Json::array(xs.map(x => Json::string(x)))
}

///|
/// An object of these fields, in this order (a field given twice: its last value, in its first place).
fn obj(fields : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for f in fields {
    m[f.0] = f.1
  }
  Json::object(m)
}

///|
/// `o[k]`.
fn get(o : Json?, k : String) -> Json? {
  match o {
    Some(Object(m)) => m.get(k)
    _ => None
  }
}

///|
/// `o[k]` where it is a string.
fn gs(o : Json?, k : String) -> String? {
  match get(o, k) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// `o[k]` as a string, "" where it is none.
fn gtext(o : Json?, k : String) -> String {
  gs(o, k).unwrap_or("")
}

///|
/// `o[k]` where it is a number.
fn gn(o : Json?, k : String) -> Double? {
  match get(o, k) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
/// `o[k]` where it is an array.
fn ga(o : Json?, k : String) -> Array[Json]? {
  match get(o, k) {
    Some(Array(a)) => Some(a)
    _ => None
  }
}

///|
/// The strings of an array read off a record.
fn strings_of(v : Json?) -> Array[String] {
  match v {
    Some(Array(a)) => {
      let out = []
      for x in a {
        if x is String(s) {
          out.push(s)
        }
      }
      out
    }
    _ => []
  }
}

///|
/// Whether a value read off a record is truthy, as JS has it.
fn truthy(v : Json?) -> Bool {
  match v {
    None | Some(Null) | Some(False) => false
    Some(Number(n, ..)) => !(n == 0.0 || n.is_nan())
    Some(String(s)) => s != ""
    _ => true
  }
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
  match v {
    Some(Number(n, ..)) =>
      n == n.floor() && n.abs() <= 9007199254740991.0 && !n.is_nan()
    _ => false
  }
}

///|
/// A number as a template says it (`${n}`).
fn num_text(n : Double) -> String {
  @vault_crypto.js_number(n)
}

///|
/// `JSON.stringify(s)`: a string quoted as JS quotes it.
fn quoted(s : String) -> String {
  stringify(Json::string(s))
}

///|
/// JS's `String(v)` of what a record holds.
fn js_text(v : Json?) -> String {
  @vault_crypto.js_string(v)
}

///|
/// `s.trim()`: JS's white space at both ends taken off.
fn trim(s : String) -> String {
  let mut a = 0
  let mut b = s.length()
  while a < b && js_space(s.code_unit_at(a).to_int()) {
    a += 1
  }
  while b > a && js_space(s.code_unit_at(b - 1).to_int()) {
    b -= 1
  }
  s.unsafe_substring(start=a, end=b)
}

///|
/// JS's white space and line terminators (`\s`).
fn js_space(c : Int) -> Bool {
  c == 0x20 ||
  (c >= 0x09 && c <= 0x0d) ||
  c == 0xa0 ||
  c == 0x1680 ||
  (c >= 0x2000 && c <= 0x200a) ||
  c == 0x2028 ||
  c == 0x2029 ||
  c == 0x202f ||
  c == 0x205f ||
  c == 0x3000 ||
  c == 0xfeff
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
  let n = s.length()
  let norm = (i : Int) => if i < 0 { (n + i).max(0) } else { i.min(n) }
  let from = norm(a)
  let to = match b {
    Some(x) => norm(x)
    None => n
  }
  if to <= from {
    ""
  } else {
    s.unsafe_substring(start=from, end=to)
  }
}

///|
/// `s.includes(t)`.
fn contains(s : String, t : String) -> Bool {
  s.find(t) is Some(_)
}

///|
/// `s.startsWith(t)`.
fn starts(s : String, t : String) -> Bool {
  s.has_prefix(t)
}

///|
/// `s.endsWith(t)`.
fn ends(s : String, t : String) -> Bool {
  s.has_suffix(t)
}

///|
/// `s.split(sep).join(by)`: every `sep` in `s` replaced.
fn replace_all(s : String, sep : String, by : String) -> String {
  if sep == "" {
    return s
  }
  let b = StringBuilder()
  let mut i = 0
  let n = s.length()
  let m = sep.length()
  while i < n {
    if i + m <= n && s.unsafe_substring(start=i, end=i + m) == sep {
      b.write_string(by)
      i += m
    } else {
      b.write_char(s.code_unit_at(i).to_int().unsafe_to_char())
      i += 1
    }
  }
  b.to_string()
}

///|
/// `xs.join(sep)`.
fn join(xs : Array[String], sep : String) -> String {
  let b = StringBuilder()
  for i, x in xs {
    if i > 0 {
      b.write_string(sep)
    }
    b.write_string(x)
  }
  b.to_string()
}

///|
/// `[...new Set(xs)]`.
fn uniq(xs : Array[String]) -> Array[String] {
  let seen : Map[String, Unit] = Map([])
  let out = []
  for x in xs {
    if !seen.contains(x) {
      seen[x] = ()
      out.push(x)
    }
  }
  out
}

///|
/// JS's `<` of two strings: by UTF-16 code units.
fn str_lt(a : String, b : String) -> Bool {
  let n = a.length().min(b.length())
  for i in 0..<n {
    let x = a.code_unit_at(i).to_int()
    let y = b.code_unit_at(i).to_int()
    if x != y {
      return x < y
    }
  }
  a.length() < b.length()
}

///|
/// The strings sorted as JS's default sort sorts them.
fn sorted(xs : Array[String]) -> Array[String] {
  let c = xs.copy()
  c.sort_by((a, b) => if str_lt(a, b) { -1 } else if a == b { 0 } else { 1 })
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
