// What the TypeScript these are moved from takes of JavaScript as it is: a value of config.json or a runtime's line as
// JSON.parse gives it (`J`, its objects' keys in their order), `typeof v === "string"`, an object spread (`{...a, ...b}`:
// a key that was there keeps its place), strings compared as `<` compares them (by UTF-16 units), `trim`, `\s`, a
// number as `String(n)` says it, `toFixed`, `toISOString`, `Buffer.byteLength`, and the SHA-256 of a string's UTF-8.

///|
using @jsjson {
  type JValue, sanitize_str as t, jval_str as js, jval_num as num, jval_int as int, jval_obj as obj,
  jval_strs as arr_of, jval_at as get, jval_str_of as str_of, jval_nonempty as nonempty,
  jval_is_true as is_true, jval_num_of as num_of, jval_finite_or_zero as finite_or_zero, jval_arr as arr,
  jval_is_obj as is_object, jval_entries as fields, js_less, js_index_of as index_of,
  jval_stringify_num as num_text, points as code_points, stringify, jval_quote as quote,
  jval_try_parse as parse, js_utf8_len as utf8_length,
}

///|
using @jscase {trim, is_space, lower}

///|
pub type J = JValue

///|
fn is_s(v : J?, s : String) -> Bool {
  v is Some(Str(x)) && x == s
}

///|
/// An object's own fields as a spread takes them (`{...v}`): none of anything else, an array's by their indexes.
fn spread_of(v : J?) -> Array[(String, J)] {
  match v {
    Some(Obj(entries)) => entries.map(e => (t(e.0), e.1))
    Some(Arr(items)) => items.mapi((i, x) => (i.to_string(), x))
    Some(Str(s)) => Array::makei(s.length(), i => (i.to_string(), Str(s.unsafe_substring(start=i, end=i + 1))))
    _ => []
  }
}

///|
/// An object as JavaScript keeps one: its keys in the order they came, a key set again keeping its place.
pub struct Fields {
  keys : Array[String]
  values : Map[String, J]
}

///|
pub fn Fields::new() -> Fields {
  { keys: [], values: {} }
}

///|
fn Fields::of(entries : Array[(String, J)]) -> Fields {
  let f = Fields::new()
  for e in entries {
    f.set(e.0, e.1)
  }
  f
}

///|
pub fn Fields::set(self : Fields, key : String, value : J) -> Unit {
  if !self.values.contains(key) {
    self.keys.push(key)
  }
  self.values[key] = value
}

///|
fn Fields::set_str(self : Fields, key : String, value : String) -> Unit {
  self.set(key, js(value))
}

///|
fn Fields::spread(self : Fields, entries : Array[(String, J)]) -> Unit {
  for e in entries {
    self.set(e.0, e.1)
  }
}

///|
pub fn Fields::get(self : Fields, key : String) -> J? {
  self.values.get(key)
}

///|
fn Fields::has(self : Fields, key : String) -> Bool {
  self.values.contains(key)
}

///|
fn Fields::delete(self : Fields, key : String) -> Unit {
  if self.values.contains(key) {
    self.values.remove(key)
    let at = self.keys.search(key).unwrap()
    self.keys.remove(at) |> ignore
  }
}

///|
/// `env.KEY ??= value`.
fn Fields::or_set(self : Fields, key : String, value : String) -> Unit {
  match self.values.get(key) {
    None | Some(Null) => self.set_str(key, value)
    _ => ()
  }
}

///|
fn Fields::entries(self : Fields) -> Array[(String, J)] {
  self.keys.map(k => (k, self.values[k]))
}

///|
pub fn Fields::json(self : Fields) -> J {
  obj(self.entries())
}

///|
/// Sorted as `.sort(([a], [b]) => (a < b ? -1 : 1))` sorts (stable, by JavaScript's `<`).
fn[T] sort_js(items : Array[T], key : (T) -> String) -> Array[T] {
  let out = items.copy()
  // An insertion sort: stable, and what it sorts is short (a memory's skills, a dozen overrides).
  for i in 1..<out.length() {
    let x = out[i]
    let mut j = i
    while j > 0 && js_less(key(x), key(out[j - 1])) {
      out[j] = out[j - 1]
      j -= 1
    }
    out[j] = x
  }
  out
}

///|
fn has_space(s : String) -> Bool {
  for i in 0..<s.length() {
    if is_space(s.unsafe_charcode_at(i)) {
      return true
    }
  }
  false
}

///|
fn sub(s : String, from : Int, to? : Int) -> String {
  let end = match to {
    Some(e) => if e > s.length() { s.length() } else { e }
    None => s.length()
  }
  let start = if from > end { end } else { from }
  s.view(start_offset=start, end_offset=end).to_owned()
}

///|
fn replace_all(s : String, old : String, new : String) -> String {
  s.replace_all(old~, new~)
}

///|
/// `s.replace(old, new)`: the first only.
fn replace_first(s : String, old : String, new : String) -> String {
  match s.find(old) {
    Some(i) => sub(s, 0, to=i) + new + sub(s, i + old.length())
    None => s
  }
}

///|
/// `createHash("sha256").update(s).digest("hex")`.
fn sha256_hex(s : String) -> String {
  @activity.sha256_hex(@activity.utf8(s))
}

///|
fn is_digit(c : Int) -> Bool {
  c >= '0'.to_int() && c <= '9'.to_int()
}

///|
fn is_lower(c : Int) -> Bool {
  c >= 'a'.to_int() && c <= 'z'.to_int()
}

///|
fn is_upper(c : Int) -> Bool {
  c >= 'A'.to_int() && c <= 'Z'.to_int()
}

///|
fn is_alnum(c : Int) -> Bool {
  is_digit(c) || is_lower(c) || is_upper(c)
}

///|
fn all_units(s : String, f : (Int) -> Bool) -> Bool {
  for i in 0..<s.length() {
    if !f(s.unsafe_charcode_at(i)) {
      return false
    }
  }
  true
}

///|
fn is_hex_lower(c : Int) -> Bool {
  is_digit(c) || (c >= 'a'.to_int() && c <= 'f'.to_int())
}

///|
/// `path.join(...parts)` on this machine (POSIX: the station's tests and stations run there; Windows's `\` where its
/// paths are given so).
fn join(parts : Array[String]) -> String {
  @nodepath.join("/", parts)
}

///|
fn dirname(path : String) -> String {
  @nodepath.dirname("/", path)
}

///|
/// `new Date(ms).toISOString()` (ms within ±8.64e15; its fraction cut as the Date's time value is).
fn iso_date(at : Double) -> String {
  @time.format_iso_ms(at.to_int64())
}

///|
/// `x.toFixed(digits)`: the integer nearest x·10^digits (the larger of two as near), from the double's exact value.
fn to_fixed(x : Double, digits : Int) -> String {
  if x.is_nan() {
    return "NaN"
  }
  if x.abs() >= 1.0e21 || x.is_inf() {
    return num_text(x)
  }
  let negative = x < 0.0
  let v = x.abs()
  let bits = v.reinterpret_as_uint64()
  let exponent = ((bits >> 52) & 0x7ffUL).to_int()
  let fraction = bits & 0xfffffffffffffUL
  let (mantissa, e) = if exponent == 0 {
    (fraction, -1074)
  } else {
    (fraction | 0x10000000000000UL, exponent - 1075)
  }
  let scale = @bigint.BigInt::from_int(10).pow(@bigint.BigInt::from_int(digits))
  let m = @bigint.BigInt::from_uint64(mantissa) * scale
  let n = if e >= 0 {
    m * @bigint.BigInt::from_int(1).shl(e)
  } else {
    let d = @bigint.BigInt::from_int(1).shl(-e)
    (m * @bigint.BigInt::from_int(2) + d) / (d * @bigint.BigInt::from_int(2))
  }
  let text = n.to_string()
  let whole = if text.length() > digits {
    text
  } else {
    "0".repeat(digits + 1 - text.length()) + text
  }
  let cut = whole.length() - digits
  let said = if digits == 0 {
    whole
  } else {
    sub(whole, 0, to=cut) + "." + sub(whole, cut)
  }
  if negative && n != @bigint.BigInt::from_int(0) {
    "-" + said
  } else {
    said
  }
}

///|
/// `s` as one word of sh's (sandbox.ts and repo-rules.ts `quoted`).
fn sh_quoted(s : String) -> String {
  "'" + replace_all(s, "'", "'\\''") + "'"
}

///|
/// `mcpUrl.replace(/\/mcp$/, "/peer")` (tools/http.ts `peerHttpBase`).
pub fn peer_http_base(mcp_url : String) -> String {
  if mcp_url.has_suffix("/mcp") {
    sub(mcp_url, 0, to=mcp_url.length() - 4) + "/peer"
  } else {
    mcp_url
  }
}

///|
/// runtime.ts `cleanEnv`: the station's environment as it starts what it runs (`base`: ops/agent-env.ts `startEnv()`,
/// whose own variables it is) less what would let a runtime be another account than its profile's, and the station's
/// internal variables (`STATION_INTERNAL`: the launcher's front, whose socket binds the station's endpoint).
pub fn clean_env(base : Fields, scrubbed : Array[String]) -> Fields {
  let out = Fields::new()
  for e in base.entries() {
    if !scrubbed.contains(e.0) && e.0 != "STILLFAIL_MESH_FRONT" && e.1 is Str(_) {
      out.set(e.0, e.1)
    }
  }
  out
}

///|
/// The env a profile and a route give, each value a string (`expandRoute(profileEnv(...))`), set over `env`.
fn spread_env(env : Fields, more : Fields) -> Unit {
  env.spread(more.entries())
}

///|
/// `a === b`: two objects are the same only as one (never here: each is parsed apart).
fn same(a : J?, b : J?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(Null), Some(Null)) => true
    (Some(Bool(x)), Some(Bool(y))) => x == y
    (Some(Num(x)), Some(Num(y))) => x == y
    (Some(Str(x)), Some(Str(y))) => x == y
    _ => false
  }
}

///|
/// `v ?? …`'s test: none for undefined and null.
fn present(v : J?) -> J? {
  match v {
    None | Some(Null) => None
    _ => v
  }
}

///|
/// `/^(https?|all|no)_proxy$/i.test(name)` (`machineProxy`): a variable naming one machine's way out, never a borrowed
/// profile's.
fn machine_proxy(name : String) -> Bool {
  let folded = StringBuilder::new()
  for c in name {
    folded.write_char(if c >= 'A' && c <= 'Z' { (c.to_int() + 32).unsafe_to_char() } else { c })
  }
  ["http_proxy", "https_proxy", "all_proxy", "no_proxy"].contains(folded.to_string())
}

///|
/// `env[name] || env[name.toLowerCase()]`: a variable in either case it is written in, none when empty.
fn either_case(env : Fields, name : String) -> String? {
  match str_of(env.get(name)) {
    Some(v) if v != "" => Some(v)
    _ =>
      match str_of(env.get(lower(name))) {
        Some(v) if v != "" => Some(v)
        _ => None
      }
  }
}

///|
/// `keepLocal`: `env` going through a proxy, this machine left out of it in both cases of NO_PROXY, added to what they
/// name.
fn keep_local_fields(env : Fields) -> Unit {
  if !["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY"].iter().any(p => either_case(env, p) is Some(_)) {
    return
  }
  let named : Array[String] = either_case(env, "NO_PROXY")
    .unwrap_or("")
    .split(",")
    .map(h => trim(h.to_string()))
    .filter(h => h != "")
    .collect()
  if named.contains("*") {
    return
  }
  let kept = named + ["localhost", "127.0.0.1", "::1"].filter(h => !named.contains(h))
  let joined = kept.join(",")
  env.set_str("NO_PROXY", joined)
  env.set_str("no_proxy", joined)
}
