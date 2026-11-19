// What the live slices (P5-1 to P5-5) share, once each: `Json` read and made as the TypeScript reads and makes it, the
// same of a value that may be absent (`Json?`) and of a call's arguments, JSON between the station's (`Json`) and
// JavaScript's (`@jsjson.JValue`) codecs and a field of the latter read without converting it whole, a tool's MCP
// answer, the slices' log line, lenient hex, a file read through the shell, the reader's program and the threads'
// store's changes told.

// ── JSON as the TypeScript reads it ──

///|
/// `v[k]`, null where `v` is no object or has no `k`.
fn jfield(v : Json, k : String) -> Json {
  match v {
    Object(m) => m.get(k).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
/// `v[k]` where it is a string.
fn jtext(v : Json, k : String) -> String? {
  match jfield(v, k) {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// `v[k]` where it is a string, else "".
fn jtext_or_empty(v : Json, k : String) -> String {
  jtext(v, k).unwrap_or("")
}

///|
/// `v[k]` where it is a number.
fn jnum_of(v : Json, k : String) -> Double? {
  match jfield(v, k) {
    Number(n, ..) => Some(n)
    _ => None
  }
}

///|
/// Whether `v[k] === true`.
fn jtrue(v : Json, k : String) -> Bool {
  jfield(v, k) is True
}

///|
/// An array's items, none for what is not one.
fn jitems(v : Json) -> Array[Json] {
  match v {
    Array(a) => a
    _ => []
  }
}

///|
/// The first of two that is some.
fn[T] either(a : T?, b : T?) -> T? {
  match a {
    Some(_) => a
    None => b
  }
}

// ── JSON made ──

///|
fn jstr(s : String) -> Json {
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
/// The string, or null.
fn jopt(s : String?) -> Json {
  match s {
    Some(t) => Json::string(t)
    None => Json::null()
  }
}

///|
/// An object of these fields, in this order (a repeated key's last value kept).
fn jobj_of(fields : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for f in fields {
    m[f.0] = f.1
  }
  Json::object(m)
}

///|
/// A field set on a JSON object (a copy; what is no object taken as an empty one).
fn jwith(j : Json, k : String, v : Json) -> Json {
  let m : Map[String, Json] = Map([])
  match j {
    Object(o) =>
      for kk, vv in o {
        m[kk] = vv
      }
    _ => ()
  }
  m[k] = v
  Json::object(m)
}

///|
/// What JSON.stringify(v, null, 2) writes.
fn jpretty(v : Json) -> String {
  v.stringify(indent=2)
}

// ── JSON that may be absent (`Json?`) ──

///|
/// `v[k]` where `v` is an object that has `k`.
fn opt_field(v : Json?, k : String) -> Json? {
  match v {
    Some(Object(m)) => m.get(k)
    _ => None
  }
}

///|
fn opt_str(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn opt_text(v : Json?, k : String) -> String? {
  opt_str(opt_field(v, k))
}

///|
fn opt_num(v : Json?) -> Double? {
  match v {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn opt_true(v : Json?) -> Bool {
  v is Some(True)
}

///|
/// An array's strings (what is not one left out), none for what is not an array.
fn opt_strs(v : Json?) -> Array[String] {
  match v {
    Some(Array(a)) => a.filter_map(x => as_text(x))
    _ => []
  }
}

///|
/// The `i`th argument of a call (`[a, b, …]`), none past its end; a call given one bare value has it as its first.
fn call_arg(args : Json, i : Int) -> Json? {
  match args {
    Array(a) if i < a.length() => Some(a[i])
    Array(_) => None
    other => if i == 0 { Some(other) } else { None }
  }
}

///|
/// The `i`th argument of a call where it is a string, else "".
fn call_arg_text(args : Json, i : Int) -> String {
  opt_str(call_arg(args, i)).unwrap_or("")
}

// ── between the two JSONs the packages speak ──

///|
/// JSON as a JavaScript value (jsjson's).
fn to_jv(j : Json) -> @jsjson.JValue {
  @jsjson.JValue::of_json(j)
}

///|
/// A JavaScript value (jsjson's) as JSON.
fn of_jv(v : @jsjson.JValue) -> Json {
  v.to_json()
}

// ── what the slices say ──

///|
/// A tool's answer as MCP gives it (tools/mcp.ts): its text, `isError` where it failed.
fn tool_answer(text : String, error? : Bool = false) -> Json {
  let content : Json = [{ "type": "text", "text": Json::string(text) }]
  if error {
    { "content": content, "isError": Json::boolean(true) }
  } else {
    { "content": content }
  }
}

///|
/// A slice's log line (P5-2 to P5-5, their parts' `log`), as P5-1's own: its time and level as log.ts writes them,
/// and heard (the station's log sent, an error reported). Written bare, those lines had no time and none reached
/// either (0.1.9984).
fn slice_log(level : String, at : String, message : String, fields : Json) -> Unit {
  let f = match fields {
    Object(m) if m.length() > 0 => Some(fields)
    Object(_) | Null => None
    other => Some({ "said": other })
  }
  p51_log(level.to_upper(), at, message, fields?=f)
}

///|
/// Bytes from their hex (the shell's `fs.bytes`, a scope's key): each pair a byte, a character that is no hex digit
/// read as 0 and an odd last one left, unlike `@vault_crypto.unhex`, which stops at the first that is not one.
fn unhex_lenient(h : String) -> Bytes {
  let digit = (c : Int) => if c >= '0'.to_int() && c <= '9'.to_int() {
    c - '0'.to_int()
  } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
    c - 'a'.to_int() + 10
  } else if c >= 'A'.to_int() && c <= 'F'.to_int() {
    c - 'A'.to_int() + 10
  } else {
    0
  }
  let n = h.length() / 2
  Bytes::makei(n, i => (digit(h.code_unit_at(2 * i).to_int()) * 16 + digit(h.code_unit_at(2 * i + 1).to_int())).to_byte())
}

///|
/// A JSON value's number, none for what is not one.
fn as_num(v : Json) -> Double? {
  match v {
    Number(n, ..) => Some(n)
    _ => None
  }
}

///|
/// A JSON value's string, none for what is not one.
fn as_text(v : Json) -> String? {
  match v {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// `v[k]` of a JavaScript value without making all of it JSON: what `jfield(of_jv(v), k)` reads (a repeated key's last
/// value), none where `v` is no object or has no `k`.
fn jv_field(v : @jsjson.JValue, k : String) -> @jsjson.JValue? {
  guard v is Obj(entries) else { return None }
  let key = @jsjson.units(k)
  let mut found = None
  for e in entries {
    if e.0 == key {
      found = Some(e.1)
    }
  }
  found
}

///|
/// `jtext(of_jv(v), k)` without making all of `v` JSON.
fn jv_text(v : @jsjson.JValue, k : String) -> String? {
  match jv_field(v, k) {
    Some(Str(u)) => Some(@jsjson.raw_text(u))
    _ => None
  }
}

///|
/// `jnum_of(of_jv(v), k)` without making all of `v` JSON (NaN and the infinities none, as `to_json` makes them null).
fn jv_num(v : @jsjson.JValue, k : String) -> Double? {
  match jv_field(v, k) {
    Some(Num(n)) if !(n.is_nan() || n.is_inf()) => Some(n)
    _ => None
  }
}

// ── what several slices do alike ──

///|
/// A file read as text, none where it is not there.
async fn shell_read_text(host : @host.Host, path : String) -> String? {
  match (try { Ok(host.shell("fs.read", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok((String(s), _)) => Some(s)
    _ => None
  }
}

///|
/// The program the station runs as (its readers' and builders').
fn reader_program(bus : LiveBus) -> String {
  attempt(() => @drive.realpath(bus.argv0)).unwrap_or(bus.argv0)
}

///|
/// The threads' store's changes told to the bus's listeners.
fn told_threads(bus : LiveBus, threads : @store_threads.Store) -> Unit {
  let sent = threads.sent.copy()
  threads.sent.clear()
  for c in sent {
    bus.notify_store(c)
  }
  // (what it found not prepared yet, asked of the builders: agents.ts `requestSessionChat`, `followLatestThreadRequests`)
  bus.drain_thread_requests(threads)
}
