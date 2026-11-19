// What the station's parts are to this package: the store, the hub, the live view, the peers, the chats, and the
// functions of other subsystems not here (a thread's history, an archive's lifecycle, a picture's facts), each asked by
// its name, `<part>.<method>`, with its arguments as JSON, as station/src/sessions names the part and its method (the
// hub's `store.getSession`, `live.page`, `peers.call`...; another module's `fn.<name>`). A part that refuses raises
// `Thrown` with the class station/src throws (`Refused`, `Error`) and what it carries (`message`). The files are this
// package's own, asked of the shell (`fs.*`, `tar.*`, `zstd.*`), and so are the transcripts' and the workspaces' packing
// (station/packed, in this program).

///|
pub(all) suberror Thrown {
  Thrown(String, Json)
}

///|
pub impl Show for Thrown with output(self, logger) {
  match self {
    Thrown(kind, said) => logger.write_string("\{kind}: \{message_in(said)}")
  }
}

///|
fn message_in(said : Json) -> String {
  match said {
    Object(o) =>
      match o.get("message") {
        Some(String(m)) => m
        _ => ""
      }
    String(m) => m
    _ => ""
  }
}

///|
/// An Error as station/src throws one: `new Error(message)`.
pub fn failed(message : String) -> Thrown {
  Thrown("Error", { "message": Json::string(message) })
}

///|
/// What an error says (`(e as Error).message`).
pub fn message_of(e : Error) -> String {
  match e {
    Thrown(_, said) => message_in(said)
    @packed.Failed(m) => m
    e => {
      let s = e.to_string()
      // (the shell's words as it said them)
      if s.has_prefix("ShellError(\"") && s.has_suffix("\")") {
        try @json.parse(s.view(start_offset=11, end_offset=s.length() - 1).to_string()) catch {
          _ => s
        } noraise {
          String(m) => m
          _ => s
        }
      } else {
        s
      }
    }
  }
}

///|
/// Whether an error is the class `kind` station/src throws.
pub fn is_kind(e : Error, kind : String) -> Bool {
  e is Thrown(k, _) && k == kind
}

///|
/// The station's parts, as this package asks them.
pub struct Station {
  call : async (String, Array[Json]) -> Json
}

///|
pub fn Station::new(call : async (String, Array[Json]) -> Json) -> Station {
  { call, }
}

///|
pub async fn Station::ask(self : Station, name : String, args : Array[Json]) -> Json {
  (self.call)(name, args)
}

///|
pub async fn Station::tell(self : Station, name : String, args : Array[Json]) -> Unit {
  ignore((self.call)(name, args))
}

// ── JSON ─────────────────────────────────────────────────────────────────────────────────────────────────────────

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
fn jo(fields : Array[(String, Json)]) -> Json {
  let m = Map::new()
  for f in fields {
    m[f.0] = f.1
  }
  Json::object(m)
}

///|
fn ja(xs : Array[Json]) -> Json {
  Json::array(xs)
}

///|
fn jopt(s : String?) -> Json {
  match s {
    Some(x) => js(x)
    None => Json::null()
  }
}

///|
fn get(v : Json, key : String) -> Json? {
  match v {
    Object(o) => o.get(key)
    _ => None
  }
}

///|
fn str(v : Json, key : String) -> String? {
  match get(v, key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn num(v : Json, key : String) -> Double? {
  match get(v, key) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn yes(v : Json, key : String) -> Bool {
  get(v, key) is Some(True)
}

///|
fn items(v : Json?) -> Array[Json] {
  match v {
    Some(Array(xs)) => xs
    _ => []
  }
}

///|
fn nullish(v : Json?) -> Bool {
  match v {
    None | Some(Null) => true
    Some(Object(o)) => o.size() == 1 && o.get("$undef") is Some(_)
    _ => false
  }
}

///|
fn some_of(v : Json) -> Json? {
  if nullish(Some(v)) {
    None
  } else {
    Some(v)
  }
}

///|
fn as_str(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn as_num(v : Json?) -> Double? {
  match v {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
/// JavaScript's undefined, as an argument.
let jundef : Json = jo([("$undef", ji(1))])

///|
/// Bytes as JSON (`{"$bytes": base64}`).
fn jbytes(b : Bytes) -> Json {
  jo([("$bytes", js(@base64.encode(b)))])
}

///|
/// The bytes an answer carries (`{"$bytes": base64}`).
fn bytes_in(v : Json) -> Bytes? {
  match str(v, "$bytes") {
    Some(b) => Some(@base64.decode(b)) catch { _ => None }
    None => None
  }
}

///|
/// JSON.stringify of a string, as JavaScript writes it.
fn quoted(s : String) -> String {
  Json::string(s).stringify()
}

///|
/// What JavaScript's `String(x)` gives for a JSON value.
fn js_text(v : Json?) -> String {
  match v {
    None => "undefined"
    Some(Null) => "null"
    Some(String(s)) => s
    Some(True) => "true"
    Some(False) => "false"
    Some(Number(n, ..)) => num_text(n)
    Some(Array(xs)) => xs.map(x => if x is Null { "" } else { js_text(Some(x)) }).join(",")
    Some(Object(_)) => "[object Object]"
  }
}

///|
/// A number as JavaScript prints it (integers without a fraction).
fn num_text(n : Double) -> String {
  @jsjson.num_text(n)
}

///|
/// A run of decimal digits as a number; -1 where it is none.
fn digits_of(s : String) -> Int {
  if s == "" {
    return -1
  }
  let mut n = 0
  for c in s {
    if c < '0' || c > '9' {
      return -1
    }
    n = n * 10 + (c.to_int() - '0'.to_int())
  }
  n
}

///|
/// `s.slice(start, end)` (UTF-16 units, as JavaScript's).
fn cut(s : String, start : Int, end? : Int) -> String {
  let e = match end {
    Some(e) => if e > s.length() { s.length() } else { e }
    None => s.length()
  }
  let b = if start > e { e } else { start }
  s.view(start_offset=b, end_offset=e).to_string()
}
