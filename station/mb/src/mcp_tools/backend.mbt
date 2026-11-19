// The agents' tools (station/src/tools and the parts' tools beside them) in MoonBit: what each tool asks of the
// station's other parts (the hub and its conversations, the jobs, the screens, the scheduler, the ways, the files of
// the machine...) is one seam, `ToolsBackend`, as the admin API's is (@api_routes.Backend): a call by its name, the
// part's method as station/src reaches it (`hub.store.handedTo`, `jobs.start`) or a module's function
// (`sessions/conversations.chatPost`), with JSON (a part by reference `{"$ref": name}`, bytes `{"$bytes": base64}`,
// JavaScript's undefined `{"$undef": 1}`, the call's abort signal `{"$signal": true}`), a refusal thrown by its class's
// name (@api_routes.Thrown). A field of a part that is data, not a part (`plane.state.state`), is read as a call of it
// with no arguments. So each part can move to the program behind it, and a tool is never written again for it.

using @api_routes {
  type JV,
  type Thrown,
  js,
  jnum,
  jint,
  jbool,
  jarr,
  jstrs,
  jobj,
  jget,
  jstr,
  jnumber,
  jitems,
  jfields,
  jref,
  jundef,
  is_undef,
  nullish,
  ref_of,
  parse,
  try_parse,
  js_string,
  num_text,
  trim_js,
  utf8,
  utf8_text,
  is_integer,
  is_safe_integer,
  js_compare,
}

///|
/// JSON.stringify(v): undefined fields left out, undefined in an array null.
pub fn stringify(v : JV) -> String {
  @jsjson.stringify(to_js(v))
}

///|
/// What a tool says went wrong: `throw new Error(message)`.
pub(all) suberror Failed {
  Failed(String)
}

///|
pub impl Show for Failed with output(self, logger) {
  match self {
    Failed(m) => logger.write_string(m)
  }
}

///|
/// A refusal as station/src/mesh/bus.ts `Refused` is (what a station's bus gives back as a refusal, not a failure).
pub(all) suberror Refusal {
  Refusal(String)
}

///|
pub impl Show for Refusal with output(self, logger) {
  match self {
    Refusal(m) => logger.write_string(m)
  }
}

///|
/// The station's parts, as the tools ask them.
pub struct ToolsBackend {
  call : async (String, Array[JV]) -> JV
}

///|
pub fn ToolsBackend::new(call : async (String, Array[JV]) -> JV) -> ToolsBackend {
  { call, }
}

///|
/// A call of the part `name`, its answer (`{"$undef": 1}` for undefined).
pub async fn ToolsBackend::ask(
  self : ToolsBackend,
  name : String,
  args : Array[JV],
) -> JV {
  (self.call)(name, args)
}

///|
/// A call whose answer is not used.
pub async fn ToolsBackend::tell(
  self : ToolsBackend,
  name : String,
  args : Array[JV],
) -> Unit {
  ignore((self.call)(name, args))
}

///|
/// A call that is a log line (`ops/log.log.info`, `.warn`, `.error`): never a failure of what logs it.
pub async fn ToolsBackend::log(
  self : ToolsBackend,
  level : String,
  area : String,
  message : String,
  fields : JV,
) -> Unit {
  ignore((self.call)("ops/log.log.\{level}", [js(area), js(message), fields])) catch {
    _ => ()
  }
}

///|
/// A function given by reference (a `{"$ref"}` answer), called.
pub async fn ToolsBackend::invoke(
  self : ToolsBackend,
  f : JV,
  args : Array[JV],
) -> JV {
  match ref_of(f) {
    Some(name) => (self.call)(name, args)
    None => raise Failed("not a function")
  }
}

///|
/// The abort signal of a call, as it is given to a part.
pub let jsignal : JV = jobj([("$signal", jbool(true))])

///|
/// What a thrown error says (`(e as Error).message`).
pub fn message_of(e : Error) -> String {
  match e {
    Failed(m) => m
    Refusal(m) => m
    ToolError(_, m) => m
    @api_routes.Thrown(_, said) => js_string(jget(Some(said), "message"))
    _ => @api_routes.message_of(e)
  }
}

///|
/// Whether it was thrown as `kind` by a part (`e instanceof Kind`), with what it carries.
pub fn thrown_as(e : Error, kind : String) -> JV? {
  @api_routes.thrown_as(e, kind)
}

///|
pub fn[X] fail(message : String) -> X raise Failed {
  raise Failed(message)
}

///|
/// JSON.stringify(v, null, 2).
pub fn pretty(v : JV) -> String {
  @jsjson.stringify_indent(to_js(v), 2)
}

///|
fn to_js(v : JV) -> @jsjson.JValue {
  match v {
    Null => Null
    Bool(b) => Bool(b)
    Num(n) => Num(n)
    Str(s) => Str(s)
    Arr(a) => Arr(a.map(x => if is_undef(x) { @jsjson.JValue::Null } else { to_js(x) }))
    Obj(f) => Obj(f.filter(p => !is_undef(p.1)).map(p => (p.0, to_js(p.1))))
  }
}

///|
/// JSON.stringify(s) of a string.
pub fn quoted(s : String) -> String {
  stringify(js(s))
}

///|
/// Buffer.byteLength(s): its UTF-8 bytes.
pub fn byte_length(s : String) -> Int {
  utf8(s).length()
}

///|
/// `typeof v === "string" ? v : undefined`.
pub fn str_of(v : JV?) -> String? {
  jstr(v)
}

///|
/// `typeof v === "string" ? v.trim() : ""`.
pub fn trimmed(v : JV?) -> String {
  match v {
    Some(Str(s)) => trim_js(s)
    _ => ""
  }
}

///|
/// `typeof v === "string" ? v : ""`.
pub fn text(v : JV?) -> String {
  match v {
    Some(Str(s)) => s
    _ => ""
  }
}

///|
/// `typeof v === "number" && Number.isFinite(v)`.
pub fn finite(v : JV?) -> Double? {
  match v {
    Some(Num(n)) if !n.is_nan() && !n.is_inf() => Some(n)
    _ => None
  }
}

///|
/// `v === true`.
pub fn is_true(v : JV?) -> Bool {
  v is Some(Bool(true))
}

///|
/// `v === false`.
pub fn is_false(v : JV?) -> Bool {
  v is Some(Bool(false))
}

///|
/// A field of an object, JavaScript's undefined where it has none (as an argument to a part).
pub fn field(v : JV, k : String) -> JV {
  match v.get(k) {
    Some(x) => x
    None => jundef
  }
}

///|
/// `v === undefined` for a field: absent, or given as undefined.
pub fn absent(v : JV?) -> Bool {
  match v {
    None => true
    Some(x) => is_undef(x)
  }
}

///|
/// An answer that is undefined as an option.
pub fn given(v : JV) -> JV? {
  if is_undef(v) {
    None
  } else {
    Some(v)
  }
}

///|
/// A JavaScript truthy value.
pub fn truthy(v : JV?) -> Bool {
  match v {
    None | Some(Null) => false
    Some(Bool(b)) => b
    Some(Num(n)) => !(n == 0.0 || n.is_nan())
    Some(Str(s)) => s != ""
    Some(x) => !is_undef(x)
  }
}

///|
/// An object with `fields` set over `o`'s (`{ ...o, k: v }`): a key it has keeps its place.
pub fn spread(o : JV, fields : Array[(String, JV)]) -> JV {
  let mut out = match o {
    Obj(_) => o
    _ => jobj([])
  }
  for f in fields {
    out = @api_routes.jset(out, f.0, f.1)
  }
  out
}

///|
/// An object without key `k` (`const { k: _, ...rest } = o`).
pub fn without(o : JV, k : String) -> JV {
  @api_routes.jdel(o, k)
}

///|
/// `String(n)` of a whole number.
pub fn int_text(n : Int) -> String {
  n.to_string()
}

///|
/// A JavaScript `\s`.
pub fn is_js_space(c : Int) -> Bool {
  @jsjson.is_js_space(c)
}

///|
/// `s.replace(/\s+/g, " ")`.
pub fn squeeze_spaces(s : String) -> String {
  let out = StringBuilder::new()
  let mut in_space = false
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    if is_js_space(c) {
      if !in_space {
        out.write_char(' ')
      }
      in_space = true
    } else {
      in_space = false
      out.write_char(c.unsafe_to_char())
    }
  }
  out.to_string()
}

///|
/// `s.slice(from, to)` by UTF-16 units.
pub fn slice(s : String, from : Int, to? : Int) -> String {
  @jsjson.js_slice(s, from, end?=to)
}

///|
/// `s.startsWith(p)`.
pub fn starts(s : String, p : String) -> Bool {
  s.has_prefix(p)
}

///|
/// `s.indexOf(p)` from `from` (-1: none).
pub fn index_of(s : String, p : String, from? : Int = 0) -> Int {
  @jsjson.js_index_of(s, p, from~)
}

///|
/// `s.lastIndexOf(p)` (-1: none).
pub fn last_index_of(s : String, p : String) -> Int {
  @jsjson.js_last_index_of(s, p)
}

///|
/// `s.split(sep)`.
pub fn split(s : String, sep : String) -> Array[String] {
  @jsjson.js_split(s, sep)
}

///|
/// `s.replaceAll(a, b)`.
pub fn replace_all(s : String, a : String, b : String) -> String {
  split(s, a).join(b)
}

///|
/// `s.toLowerCase()` for what the tools compare by it (ASCII and the Latin letters a name may have).
pub fn lower(s : String) -> String {
  s.to_lower()
}

///|
/// `s.toUpperCase()`.
pub fn upper(s : String) -> String {
  s.to_upper()
}

///|
/// `[...s].length`: its code points.
pub fn code_point_count(s : String) -> Int {
  @api_routes.code_points(s)
}

///|
/// Math.round, as JavaScript rounds (halves up).
pub fn js_round(x : Double) -> Double {
  @jsjson.js_round(x)
}

///|
/// `Number(n.toFixed(digits))`: the exact decimal of the double rounded at `digits`, a half up (as toFixed does it),
/// for what a double holds whole at that many digits (the rest is as it is).
pub fn fixed_number(n : Double, digits : Int) -> Double {
  let mut scale = 1L
  for _ in 0..<digits {
    scale = scale * 10L
  }
  // (past what a double holds whole, it is itself)
  if n.is_nan() || n.is_inf() || n.abs() * scale.to_double() >= 9007199254740992.0 {
    return n
  }
  let bits = n.abs().reinterpret_as_uint64()
  let exp = ((bits >> 52) & 0x7ffUL).to_int()
  let frac = bits & ((1UL << 52) - 1UL)
  let (m, e) = if exp == 0 {
    (frac, -1074)
  } else {
    (frac | (1UL << 52), exp - 1075)
  }
  let num = @bigint.BigInt::from_uint64(m) * @bigint.BigInt::from_int64(scale)
  let k = if e >= 0 {
    num.shl(e)
  } else {
    let den = @bigint.BigInt::from_int(1).shl(-e)
    let q = num / den
    let r = num % den
    if (r + r).compare(den) >= 0 {
      q + @bigint.BigInt::from_int(1)
    } else {
      q
    }
  }
  let v = k.to_int64().to_double() / scale.to_double()
  if n < 0.0 {
    -v
  } else {
    v
  }
}

///|
/// The parts' answer as a JS array of strings (`.filter((m) => typeof m === "string")`).
pub fn strings_of(v : JV?) -> Array[String] {
  jitems(v).filter_map(x => jstr(Some(x)))
}

///|
/// `Array.isArray(v)`.
pub fn is_arr(v : JV?) -> Bool {
  v is Some(Arr(_))
}

///|
/// A plain object: `v !== null && typeof v === "object" && !Array.isArray(v)`.
pub fn is_obj(v : JV?) -> Bool {
  match v {
    Some(Obj(_)) => !is_undef(v.unwrap())
    _ => false
  }
}

///|
/// A stable sort by `cmp` (JavaScript's Array.prototype.sort keeps equal elements in their order).
pub fn[T] stable_sorted(xs : Array[T], cmp : (T, T) -> Int) -> Array[T] {
  let n = xs.length()
  if n < 2 {
    return xs.copy()
  }
  let mid = n / 2
  let a = stable_sorted(xs[0:mid].to_array(), cmp)
  let b = stable_sorted(xs[mid:].to_array(), cmp)
  let out = []
  let mut i = 0
  let mut j = 0
  while i < a.length() && j < b.length() {
    if cmp(b[j], a[i]) < 0 {
      out.push(b[j])
      j += 1
    } else {
      out.push(a[i])
      i += 1
    }
  }
  while i < a.length() {
    out.push(a[i])
    i += 1
  }
  while j < b.length() {
    out.push(b[j])
    j += 1
  }
  out
}

///|
/// A string given, or undefined.
pub fn jundef_or(s : String?) -> JV {
  match s {
    Some(v) => js(v)
    None => jundef
  }
}
