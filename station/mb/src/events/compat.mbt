// A core that cannot take every runtime (station/src/api/runtime-compat.ts): what is said of a runtime it does not
// know is left out of what it is answered and told, by the client's shapes (shapes.mbt; read/runtime-view.ts
// `runtimeView`), never anything people or agents wrote.

///|
/// runtime-compat.ts RUNTIMES_HEADER.
pub let runtimes_header : String = "stillfail-runtimes"

///|
/// The runtimes a core from before the header takes.
let legacy_runtimes : Array[String] = [
  "claude", "codex", "dsh", "grok", "cursor", "devin",
]

///|
/// agents/runtime.ts RUNTIME_KINDS.
pub let runtime_kinds : Array[String] = [
  "claude", "codex", "dsh", "grok", "cursor", "devin", "hermes", "agy", "pi",
]

///|
let shapes : J = parse(shapes_text).unwrap_or(Obj([]))

///|
/// A header's value, its name in any case (the first that is).
fn header_of(headers : Array[(String, String)], name : String) -> String? {
  for h in headers {
    if @jscase.lower(h.0) == name {
      return Some(h.1)
    }
  }
  None
}

///|
fn runtime_name(s : String) -> Bool {
  let n = s.length()
  if n < 1 || n > 40 {
    return false
  }
  for i, c in s {
    let ok = (c >= 'a' && c <= 'z') ||
      (i > 0 && ((c >= '0' && c <= '9') || c == '-'))
    if !ok {
      return false
    }
  }
  true
}

///|
/// runtime-compat.ts `clientRuntimes`: the runtimes a request says its core takes.
pub fn client_runtimes(headers : Array[(String, String)]) -> Map[String, Unit] {
  let out : Map[String, Unit] = Map([])
  match header_of(headers, runtimes_header) {
    None =>
      for r in legacy_runtimes {
        out[r] = ()
      }
    Some(v) =>
      for part in v.split(",") {
        let r = @jscase.trim(part.to_string())
        if runtime_name(r) {
          out[r] = ()
        }
      }
  }
  out
}

///|
/// Whether a core takes every runtime (it is answered as it is).
pub fn takes_every(supported : Map[String, Unit]) -> Bool {
  runtime_kinds.iter().all(k => supported.contains(k))
}

///|
/// What `runtimeView` makes of a value: left out (`OMIT`), or a value (none: undefined, as it was).
pub(all) enum View {
  Omit
  Value(J?)
}

///|
fn view_or_null(v : View) -> J? {
  match v {
    Omit => Some(Null)
    Value(v) => v
  }
}

///|
/// read/runtime-view.ts `runtimeView`: `value` of type `ty` (a Ty as data) for a core that takes `supported`.
pub fn runtime_view(ty : J, value : J?, supported : Map[String, Unit]) -> View {
  guard value is Some(v) && !(v is Null) else { return Value(value) }
  match ty {
    Str(_) => {
      let name = text_of(Some(ty)).unwrap()
      if name == "RuntimeKind" {
        return if v is Str(s) && !supported.contains(s) {
          Omit
        } else {
          Value(value)
        }
      }
      guard shapes.get(name) is Some(shape) else { return Value(value) }
      guard v is Obj(_) else { return Value(value) }
      match str_prop(shape, "k") {
        Some("t") => {
          let tag = str_prop(shape, "tag").unwrap_or("")
          let content = str_prop(shape, "c").unwrap_or("")
          let variant = match shape.get("v") {
            Some(variants) => variants.get(string_of_tag(v.get(tag)))
            None => None
          }
          guard variant is Some(variant) else { return Value(value) }
          match runtime_view(variant, v.get(content), supported) {
            Omit => Omit
            Value(c) => Value(Some(set_or_undefined(v, content, c)))
          }
        }
        Some("s") => {
          let mut out : J = v
          if name == "Message" &&
            text_of(v.get("authorRuntime")) is Some(r) &&
            !supported.contains(r) {
            out = without(out, "authorRuntime")
          }
          if shape.get("f") is Some(Arr(fields)) {
            for f in fields {
              let field = text_of(at(f, 0)).unwrap_or("")
              guard has(out, field) else { continue }
              match
                runtime_view(at(f, 1).unwrap_or(Null), v.get(field), supported) {
                Omit => return Omit
                Value(fv) => out = set_or_undefined(out, field, fv)
              }
            }
          }
          Value(Some(out))
        }
        _ => Value(value)
      }
    }
    Obj(_) =>
      if ty.get("opt") is Some(inner) {
        Value(view_or_null(runtime_view(inner, value, supported)))
      } else if ty.get("vec") is Some(inner) {
        match v {
          Arr(items) => {
            let out = []
            for item in items {
              match runtime_view(inner, Some(item), supported) {
                Omit => ()
                Value(Some(x)) => out.push(x)
                // (an item undefined: JSON's null)
                Value(None) => out.push(Null)
              }
            }
            Value(Some(Arr(out)))
          }
          _ => Value(value)
        }
      } else if ty.get("map") is Some(inner) {
        match v {
          Obj(entries) => {
            let out = []
            for e in entries {
              match runtime_view(inner, Some(e.1), supported) {
                Omit => ()
                Value(Some(x)) => out.push((e.0, x))
                Value(None) => ()
              }
            }
            Value(Some(Obj(out)))
          }
          _ => Value(value)
        }
      } else if ty.get("tuple") is Some(Arr(types)) {
        match v {
          Arr(items) => {
            let out = []
            for i, item in items {
              if i < types.length() {
                match runtime_view(types[i], Some(item), supported) {
                  Omit => return Omit
                  Value(Some(x)) => out.push(x)
                  Value(None) => out.push(Null)
                }
              } else {
                out.push(item)
              }
            }
            Value(Some(Arr(out)))
          }
          _ => Value(value)
        }
      } else {
        Value(value)
      }
    _ => Value(value)
  }
}

///|
/// `String(value[tag])`, as a variant is looked up by it.
fn string_of_tag(v : J?) -> String {
  match v {
    None => "undefined"
    Some(v) => @jsjson.js_string(v)
  }
}

///|
/// `{ ...v, [name]: value }`, where `value` undefined leaves the property out of what is written.
fn set_or_undefined(v : J, name : String, value : J?) -> J {
  match value {
    Some(x) => with_prop(v, name, x)
    None => without(v, name)
  }
}

///|
/// runtime-compat.ts `entriesView`: a thread's entries, an unknown runtime of their authors' left out.
pub fn entries_view(value : J, supported : Map[String, Unit]) -> J {
  guard value is Obj(_) && value.get("entries") is Some(Arr(entries)) else {
    return value
  }
  with_prop(
    value,
    "entries",
    Arr(
      entries.map(entry => {
        guard entry is Obj(_) &&
          text_of(entry.get("authorRuntime")) is Some(r) &&
          !supported.contains(r) else {
          return entry
        }
        without(entry, "authorRuntime")
      }),
    ),
  )
}

///|
/// An event's data shaped by its name (runtime-compat.ts EVENTS).
fn event_type(event : String) -> String? {
  match event {
    "overview" => Some("Overview")
    "session" => Some("Session")
    _ => None
  }
}

///|
/// runtime-compat.ts `frame`: one SSE block (without its blank line) for such a core.
pub fn compat_frame(text : String, supported : Map[String, Unit]) -> String {
  let lines = text.split("\n").map(l => l.to_string()).to_array()
  let event = lines
    .iter()
    .find_first(l => l.has_prefix("event: "))
    .map(l => l.view(start_offset=7).to_string())
  let mut i = -1
  for k, l in lines {
    if l.has_prefix("data: ") {
      i = k
      break
    }
  }
  let ty = match event {
    Some(e) => event_type(e)
    None => None
  }
  if i < 0 || (ty is None && event != Some("thread")) {
    return text
  }
  guard parse(lines[i].view(start_offset=6).to_string()) is Some(value) else {
    return text
  }
  let view = if event == Some("thread") {
    Value(Some(entries_view(value, supported)))
  } else {
    runtime_view(js(ty.unwrap()), Some(value), supported)
  }
  if view is Omit && event == Some("session") {
    for k, l in lines {
      if l.has_prefix("event: ") {
        lines[k] = "event: session-removed"
        break
      }
    }
    lines[i] = "data: \{stringify(jopt([("key", value.get("key"))]))}"
  } else {
    lines[i] = "data: " +
      (match view {
        Omit => "null"
        Value(Some(v)) => stringify(v)
        Value(None) => "undefined"
      })
  }
  lines.join("\n")
}

///|
/// runtime-compat.ts `events`: a stream's pieces for such a core, each block shaped as it is whole.
pub struct CompatStream {
  supported : Map[String, Unit]
  mut pending : String
}

///|
pub fn CompatStream::new(supported : Map[String, Unit]) -> CompatStream {
  { supported, pending: "", }
}

///|
/// A piece told: the blocks it ends, each shaped, with its blank line.
pub fn CompatStream::push(self : CompatStream, piece : String) -> Array[String] {
  self.pending += piece
  let out = []
  while self.pending.find("\n\n") is Some(end) {
    out.push(
      compat_frame(
        self.pending.view(end_offset=end).to_string(),
        self.supported,
      ) +
      "\n\n",
    )
    self.pending = self.pending.view(start_offset=end + 2).to_string()
  }
  out
}

///|
/// The stream ended: what was left of a block, shaped.
pub fn CompatStream::end(self : CompatStream) -> String? {
  if self.pending == "" {
    None
  } else {
    Some(compat_frame(self.pending, self.supported))
  }
}

///|
/// runtime-compat.ts `shapeFor`.
fn shape_for(path : String) -> J? {
  let one = (prefix : String) => {
    path.has_prefix(prefix) &&
    path.length() > prefix.length() &&
    !path.view(start_offset=prefix.length()).contains("/")
  }
  if path == "/overview" {
    Some(js("Overview"))
  } else if path == "/sessions" {
    Some(jo([("vec", js("Session"))]))
  } else if one("/sessions/") {
    Some(js("SessionDetail"))
  } else if path == "/threads" {
    Some(jo([("vec", js("ChatThread"))]))
  } else if one("/threads/") {
    Some(js("ChatThread"))
  } else if path == "/chats" {
    Some(jo([("vec", js("ChatItem"))]))
  } else {
    None
  }
}

///|
/// The station's words for a core to update to see an agent's runs (station.admin.updateClientForRuntime).
fn update_for_runtime(lang : String) -> String {
  if lang == "en" {
    "Update the app to view this agent’s execution history"
  } else {
    "请更新客户端后查看此 agent 的执行记录"
  }
}

///|
/// A JSON answer: its status, its headers (in order) and its body.
pub(all) struct JsonAnswer {
  status : Int32
  headers : Array[(String, String)]
  body : String
}

///|
fn trim_slashes(path : String) -> String {
  let mut end = path.length()
  while end > 0 && path.unsafe_charcode_at(end - 1) == '/'.to_int() {
    end -= 1
  }
  path.view(end_offset=end).to_string()
}

///|
/// `^/(profiles|logins|…)(/|$)`: a write that answers the overview.
fn account_path(path : String) -> Bool {
  for
    p in [
      "profiles", "logins", "automatic-decisions", "archiving", "connects", "slack",
      "feishu", "group", "me/slack",
    ] {
    let prefix = "/" + p
    if path == prefix || path.has_prefix(prefix + "/") {
      return true
    }
  }
  false
}

///|
fn entries_path(path : String) -> Bool {
  guard path.has_prefix("/threads/") && path.has_suffix("/entries") else {
    return false
  }
  let middle = path
    .view(start_offset=9, end_offset=path.length() - 8)
    .to_string()
  middle.length() > 0 && !middle.contains("/")
}

///|
/// runtime-compat.ts `runtimeCompatible` for an answer of JSON (the event stream is CompatStream's): `path` and
/// `headers` the request's, `body` its body (a batch's gets), `lang` its language.
pub fn runtime_compatible(
  path : String,
  headers : Array[(String, String)],
  body : String,
  lang : String,
  answer : JsonAnswer,
) -> JsonAnswer {
  if answer.status < 200 || answer.status >= 300 {
    return answer
  }
  let supported = client_runtimes(headers)
  if takes_every(supported) {
    return answer
  }
  let path = trim_slashes(path)
  let json_type = answer.headers
    .iter()
    .find_first(h => h.0 == "content-type")
    .map(h => h.1)
    .unwrap_or("")
  if !json_type.has_prefix("application/json") {
    return answer
  }
  let no_length = answer.headers.filter(h => h.0 != "content-length")
  if path == "/batch" {
    let gets = match parse(body) {
      Some(v) => v.get("gets")
      None => None
    }
    guard parse(answer.body) is Some(raw) else { return answer }
    guard gets is Some(Arr(gets)) && raw.get("answers") is Some(Arr(answers)) else {
      return answer
    }
    let projected = answers.mapi((i, a) => {
      guard i < gets.length() && gets[i] is Str(_) else { return a }
      let get = text_of(Some(gets[i])).unwrap()
      let get_path = match get.find("?") {
        Some(q) => get.view(end_offset=q).to_string()
        None => get
      }
      let status = match a.get("status") {
        Some(Num(s)) => s.to_int()
        _ => 0
      }
      let one = runtime_compatible(get_path, headers, "", lang, {
        status,
        headers: [("content-type", "application/json")],
        body: match a.get("body") {
          Some(b) => stringify(b)
          None => "undefined"
        },
      })
      with_prop(
        with_prop(a, "status", jn(one.status.to_double())),
        "body",
        parse(one.body).unwrap_or(Null),
      )
    })
    return {
      status: answer.status,
      headers: no_length,
      body: stringify(with_prop(raw, "answers", Arr(projected))),
    }
  }
  let ty = shape_for(path)
  let entries = entries_path(path)
  let account = account_path(path)
  if ty is None && !account && !entries {
    return answer
  }
  guard parse(answer.body) is Some(raw) else { return answer }
  let view = if entries {
    Value(Some(entries_view(raw, supported)))
  } else if account && raw is Obj(_) {
    if has(raw, "overview") {
      match runtime_view(js("Overview"), raw.get("overview"), supported) {
        // (`{ ...raw, overview: OMIT }`: a symbol JSON leaves out)
        Omit => Value(Some(without(raw, "overview")))
        Value(v) => Value(Some(set_or_undefined(raw, "overview", v)))
      }
    } else {
      runtime_view(js("Overview"), Some(raw), supported)
    }
  } else {
    runtime_view(ty.unwrap(), Some(raw), supported)
  }
  match view {
    Omit =>
      {
        status: 426,
        headers: [
          ("content-type", "application/json"),
          ("cache-control", "no-store"),
        ],
        body: stringify(jo([("error", js(update_for_runtime(lang)))])),
      }
    Value(v) =>
      {
        status: answer.status,
        headers: no_length,
        body: match v {
          Some(v) => stringify(v)
          None => "undefined"
        },
      }
  }
}
