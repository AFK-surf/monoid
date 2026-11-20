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
using @jsjson {
  json_str as js, json_num as jn, json_int as ji, json_bool as jb, json_obj as jo, json_arr as ja,
  json_opt_str as jopt, json_field as get, json_str_field as str, json_num_field as num,
  json_items as items, json_str_of as as_str, json_num_of as as_num, json_js_str as js_text, num_text,
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
