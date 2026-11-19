// What share/index.ts, share/memory.ts and xshare/index.ts stand on, in MoonBit (station/mb src/share_sync): plain JSON
// read as JavaScript reads it (a field's `typeof`, `Array.isArray`, `Number(…)`), written as `JSON.stringify` writes it
// (its keys in JavaScript's order, an integer-like one first), their failures by whose word they are, one thing at a
// time where the TypeScript chained its promises (`Turn`), and what was set going and not waited for (`Tasks`).

///|
/// A failure of the sharing's, by whose word it is: the other station's (`Refused`: it answered with a refusal, mesh/
/// bus.ts `Refused`), a person's (`Said`: words for them, ops/i18n.ts `Said`), the memory's program stopped as the
/// station stops (`Stopped`, memory-mb.ts `MemoryProgramStopped`), a skill past what may be shared (`TooLarge`), or any
/// other (`Failed`, a plain `Error`).
pub suberror ShareError {
  Refused(String)
  Said(String)
  Stopped(String)
  TooLarge(String)
  Failed(String)
}

///|
pub impl Show for ShareError with output(self, logger) {
  logger.write_string(error_words(self))
}

///|
/// What a failure says (`(e as Error).message`).
pub fn error_words(e : Error) -> String {
  match e {
    Refused(m) | Said(m) | Stopped(m) | TooLarge(m) | Failed(m) => m
    @memory.Failed(m) => m
    @wire.ShellError(m) => m
    Failure(m) => m
    e => e.to_string()
  }
}

///|
/// Whose word a failed request is (index.ts `whoSaid`): "them" for the other station's refusal, else "here".
pub fn who_said(e : Error) -> String {
  if e is Refused(_) {
    "them"
  } else {
    "here"
  }
}

// ── JSON as JavaScript reads it ──

///|
fn jstr(s : String) -> Json {
  Json::string(s)
}

///|
fn jnum(d : Double) -> Json {
  Json::number(d)
}

///|
fn jbool(b : Bool) -> Json {
  Json::boolean(b)
}

///|
fn jnull() -> Json {
  Json::null()
}

///|
fn jarr(a : Array[Json]) -> Json {
  Json::array(a)
}

///|
fn jstrs(a : Array[String]) -> Json {
  Json::array(a.map(jstr))
}

///|
fn jobj(pairs : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for p in pairs {
    m[p.0] = p.1
  }
  Json::object(m)
}

///|
/// `v !== null && typeof v === "object" && !Array.isArray(v)`.
fn is_obj(v : Json?) -> Bool {
  v is Some(Object(_))
}

///|
/// `v?.[k]` (undefined: None).
fn get(v : Json?, k : String) -> Json? {
  match v {
    Some(Object(m)) => m.get(k)
    _ => None
  }
}

///|
fn gets(v : Json?, ks : Array[String]) -> Json? {
  let mut at = v
  for k in ks {
    at = get(at, k)
  }
  at
}

///|
fn str_of(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// `Array.isArray(v[k]) ? v[k] : None`.
fn arr_at(v : Json?, k : String) -> Array[Json]? {
  match get(v, k) {
    Some(Array(a)) => Some(a)
    _ => None
  }
}

///|
fn true_at(v : Json?, k : String) -> Bool {
  get(v, k) is Some(True)
}

///|
/// The strings of an array as it is kept (`allow`, a list said): every element, as JavaScript keeps them; a station's
/// list is only ever strings, but one that is not is kept as it was (JSON.stringify writes it so).
fn str_list(a : Array[Json]) -> Array[String] {
  a.filter_map(x => if x is String(s) { Some(s) } else { None })
}

///|
/// A deep copy (`structuredClone` of JSON).
fn clone(v : Json) -> Json {
  match v {
    Array(a) => Json::array(a.map(clone))
    Object(m) => {
      let out : Map[String, Json] = Map([])
      for k, x in m {
        out[k] = clone(x)
      }
      Json::object(out)
    }
    other => other
  }
}

///|
/// An object's keys in the order JavaScript gives them (`Object.keys`): its integer-like ones ascending, then the rest
/// as they were put.
fn js_keys(m : Map[String, Json]) -> Array[String] {
  let keys : Array[String] = m.keys().collect()
  let ints = keys.filter(k => @jsjson.index_key(k) is Some(_))
  if ints.is_empty() {
    return keys
  }
  ints.sort_by((a, b) => @jsjson.index_key(a).unwrap_or(0.0).compare(@jsjson.index_key(b).unwrap_or(0.0)))
  ints + keys.filter(k => @jsjson.index_key(k) is None)
}

///|
/// `JSON.stringify(v)`.
pub fn js_stringify(v : Json) -> String {
  @jsjson.stringify(@jsjson.JValue::of_json(v))
}

///|
/// `JSON.stringify(v, null, 2)`.
pub fn js_stringify2(v : Json) -> String {
  @jsjson.stringify_indent(@jsjson.JValue::of_json(v), 2)
}

///|
/// `JSON.parse(text)` as a plain value (its numbers doubles).
fn js_parse(text : String) -> Json raise {
  @jsjson.parse(text).to_json_lossy()
}

///|
/// SHA-256 of a text's UTF-8 (hex).
fn sha_text(s : String) -> String {
  @memory.sha256_hex(@utf8.encode(s))
}

///|
/// index.ts `hashOf`: of a string itself, of anything else its `JSON.stringify`.
fn hash_of(v : Json) -> String {
  match v {
    String(s) => sha_text(s)
    other => sha_text(js_stringify(other))
  }
}

///|
/// `String(v)` of a JSON value (undefined: "undefined").
fn js_string(v : Json?) -> String {
  match v {
    None => "undefined"
    Some(String(s)) => s
    Some(Null) => "null"
    Some(True) => "true"
    Some(False) => "false"
    Some(Number(d, ..)) => js_number(d)
    Some(Array(a)) => a.map(x => if x is Null { "" } else { js_string(Some(x)) }).join(",")
    Some(Object(_)) => "[object Object]"
  }
}

///|
/// A number as JavaScript writes it (`String(n)`).
fn js_number(d : Double) -> String {
  @jsjson.num_text(d)
}

///|
/// `Number(v)` of a JSON value (undefined: NaN).
fn js_num(v : Json?) -> Double {
  match v {
    None => @double.not_a_number
    Some(Null) => 0.0
    Some(True) => 1.0
    Some(False) => 0.0
    Some(Number(d, ..)) => d
    Some(String(s)) => @jsjson.js_number(s)
    Some(Array(a)) =>
      match a.length() {
        0 => 0.0
        1 => js_num(Some(a[0]))
        _ => @double.not_a_number
      }
    Some(Object(_)) => @double.not_a_number
  }
}

///|
/// `Number(v ?? 0)`.
fn num_or0(v : Json?) -> Double {
  match v {
    None | Some(Null) => 0.0
    _ => js_num(v)
  }
}

///|
/// A JSON number of a double that may be NaN (`JSON.stringify` writes it null).
fn jnum_js(d : Double) -> Json {
  if d != d || d == @double.infinity || d == @double.neg_infinity {
    Json::null()
  } else {
    Json::number(d)
  }
}

///|
fn js_space(c : Char) -> Bool {
  @jscase.is_space(c.to_int())
}

///|
fn js_trim(s : String) -> String {
  @jscase.trim(s)
}

///|
/// The first `n` UTF-16 units of `s` (`s.slice(0, n)`).
fn js_slice(s : String, n : Int) -> String {
  if s.length() <= n {
    s
  } else {
    s.view(end_offset=n).to_string()
  }
}

///|
/// `Array.from(v.trim()).slice(0, max).join("")` of a string (anything else: ""): at most `max` code points.
fn text_most(v : Json?, max : Int) -> String {
  match v {
    Some(String(s)) => @jsjson.chars(@jscase.trim(s), max)
    _ => ""
  }
}

///|
/// Base64 as `Buffer.from(s, "base64")` reads it: what is not of its alphabet passed over, `-` and `_` as `+` and `/`,
/// padding or none.
fn base64_loose(s : String) -> Bytes {
  let kept = StringBuilder()
  for c in s {
    if c == '=' {
      break
    }
    if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || "+/-_".contains_char(c) {
      kept.write_char(c)
    }
  }
  let kept = kept.to_string()
  // (a lone letter at the end makes no byte)
  let n = kept.length() - (if kept.length() % 4 == 1 { 1 } else { 0 })
  @codec.base64_decode(kept.unsafe_substring(start=0, end=n)).unwrap()
}

///|
/// `Buffer.toString("base64")`.
fn base64_of(b : BytesView) -> String {
  @codec.base64_encode(b)
}

///|
/// A JWT's claims, as index.ts reads them (`JSON.parse(Buffer.from(part, "base64url"))`); None where they do not read.
fn jwt_claims(token : String) -> Json? {
  let parts = token.split(".").collect()
  let part = if parts.length() > 1 { parts[1].to_string() } else { "" }
  let text = @utf8.decode_lossy(base64_loose(part))
  Some(js_parse(text)) catch {
    _ => None
  }
}

///|
/// When a JWT runs out (ms), if it says (index.ts `jwtExpiry`).
pub fn jwt_expiry(token : Json?) -> Double? {
  guard token is Some(String(t)) else { return None }
  match get(jwt_claims(t), "exp") {
    Some(Number(d, ..)) => Some(d * 1000.0)
    _ => None
  }
}

// ── one at a time, and what was set going ──

///|
/// What is done one at a time, each after the one before has settled (a promise chain's `then(f, f)`).
pub struct Turn {
  priv mut tail : @effect.Deferred[Unit]
}

///|
pub fn Turn::new() -> Turn {
  let d = @effect.Deferred::new()
  ignore(d.succeed(()))
  { tail: d }
}

///|
/// `f` once what was asked before it is done; its outcome its own.
pub async fn[T] Turn::run(self : Turn, f : async () -> T) -> T {
  let before = self.tail
  let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.tail = mine
  defer ignore(mine.succeed(()))
  before.wait() catch {
    _ => ()
  }
  f()
}

///|
/// Once what was asked so far is done.
pub async fn Turn::settled(self : Turn) -> Unit {
  self.tail.wait() catch {
    _ => ()
  }
}

///|
/// What a part sets going and does not wait for (`void this.reconcile()`, `void tree.scan()`): each a fiber of the
/// runtime it was made on, what it throws said in the log; counted while it runs (`busy`, a test's settling).
pub struct Tasks {
  rt : @effect.Runtime
  log : Log
  what : String
  mut busy : Int
}

///|
pub fn Tasks::new(rt : @effect.Runtime, log : Log, what : String) -> Tasks {
  { rt, log, what, busy: 0 }
}

///|
pub fn Tasks::spawn(self : Tasks, f : async () -> Unit) -> Unit {
  self.busy += 1
  ignore(
    self.rt.fork_quiet(name=self.what, async fn() {
      f() catch {
        e => self.log.warn(self.what, "background work failed", jobj([("error", jstr(error_words(e)))]))
      }
      self.busy -= 1
    }),
  )
}

///|
/// A part's time: now (ms since the epoch) and a callback after a while, called off by what it returns (ops/fibers.ts
/// `Fibers.now`, `after`).
pub(all) struct Clock {
  now : () -> Double
  after : (Double, () -> Unit) -> () -> Unit
}

///|
/// The runtime's own clock: the machine's time, its timers the runtime's.
pub fn Clock::live(rt : @effect.Runtime) -> Clock {
  {
    now: () => @host.epoch_ms().to_double(),
    after: (ms, f) => {
      let off = Ref(false)
      let wait = if ms < 0.0 { 0 } else if ms > 2147483647.0 { 2147483647 } else { ms.to_int() }
      rt.after(wait, () => if !off.val { f() }, later=true, who="share_sync")
      () => off.val = true
    },
  }
}

///|
/// What a part says in the station's log (ops/log.ts): its level, its part, its words and what goes with them.
pub(all) struct Log {
  say : (String, String, String, Json) -> Unit
}

///|
pub fn Log::info(self : Log, what : String, words : String, fields : Json) -> Unit {
  (self.say)("info", what, words, fields)
}

///|
pub fn Log::warn(self : Log, what : String, words : String, fields : Json) -> Unit {
  (self.say)("warn", what, words, fields)
}

///|
pub fn Log::error(self : Log, what : String, words : String, fields : Json) -> Unit {
  (self.say)("error", what, words, fields)
}

///|
/// The log as the program's stderr (one JSON line each).
pub fn Log::stderr() -> Log {
  {
    say: (level, what, words, fields) => @host.note(
      js_stringify(jobj([("level", jstr(level)), ("part", jstr(what)), ("msg", jstr(words)), ("fields", fields)])),
    ),
  }
}
