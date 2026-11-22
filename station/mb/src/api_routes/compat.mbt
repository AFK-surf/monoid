// A station must not send a closed-enum runtime to a client that cannot decode it (station/src/api/runtime-compat.ts):
// a client says the runtimes it reads (`stillfail-runtimes`), one from before says none and reads those of before
// Hermes. What the station's answers say of a runtime is projected for it (read/runtime-view.ts, `@events.runtime_view`),
// never what people wrote.

///|
let legacy_runtimes : Array[String] = [
  "claude", "codex", "dsh", "grok", "cursor", "devin",
]

///|
let runtime_name : Re = re("^[a-z][a-z0-9-]{0,39}$")

///|
/// The runtimes a client reads, in the order it said them, each once.
pub fn client_runtimes(headers : Array[(String, String)]) -> Array[String] {
  match header_of(headers, "stillfail-runtimes") {
    None => legacy_runtimes.copy()
    Some(v) => {
      let out = []
      for s in v.split(",") {
        let t = trim_js(s.to_string())
        if runtime_name.matches(t) && !out.contains(t) {
          out.push(t)
        }
      }
      out
    }
  }
}

///|
fn entries_view(value : JV, supported : Array[String]) -> JV {
  guard value is Obj(_) && value.get("entries") is Some(Arr(entries)) else {
    return value
  }
  jset(
    value,
    "entries",
    jarr(
      entries.map(entry => {
        match jstr(jget(Some(entry), "authorRuntime")) {
          Some(rt) if entry is Obj(_) && !supported.contains(rt) =>
            jdel(entry, "authorRuntime")
          _ => entry
        }
      }),
    ),
  )
}

///|
fn is_omit(v : JV) -> Bool {
  v is Obj([(k, _)]) && k == "$omit"
}

///|
fn client_profile_services(headers : Array[(String, String)]) -> Bool {
  match header_of(headers, "stillfail-profile-services") {
    Some(v) => trim_js(v) == "1"
    None => false
  }
}

///|
fn runtime_view(
  ty : JV,
  value : JV,
  supported : Array[String],
  services : Bool,
) -> JV {
  let set : Map[String, Unit] = {}
  for k in supported {
    set[k] = ()
  }
  match @events.runtime_view(ty, Some(value), set, services~) {
    Omit => jobj([("$omit", jbool(true))])
    Value(Some(v)) => v
    Value(None) => jundef
  }
}

///|
fn shape_for(path : String) -> JV? {
  if path == "/overview" {
    Some(js("Overview"))
  } else if path == "/sessions" {
    Some(jobj([("vec", js("Session"))]))
  } else if re("^\\/sessions\\/[^/]+$").matches(path) {
    Some(js("SessionDetail"))
  } else if path == "/threads" {
    Some(jobj([("vec", js("ChatThread"))]))
  } else if re("^\\/threads\\/[^/]+$").matches(path) {
    Some(js("ChatThread"))
  } else if path == "/chats" {
    Some(jobj([("vec", js("ChatItem"))]))
  } else {
    None
  }
}

///|
fn frame(text : String, supported : Array[String], services : Bool) -> String raise {
  let lines = text.split("\n").map(l => l.to_string()).collect()
  let event = match lines.iter().find_first(l => l.has_prefix("event: ")) {
    Some(l) => Some(l.unsafe_substring(start=7, end=l.length()))
    None => None
  }
  let mut i = -1
  for j in 0..<lines.length() {
    if lines[j].has_prefix("data: ") {
      i = j
      break
    }
  }
  let ty = match event {
    Some("overview") => Some(js("Overview"))
    Some("session") => Some(js("Session"))
    _ => None
  }
  if i < 0 || (ty is None && event != Some("thread")) {
    return text
  }
  let value = parse(lines[i].unsafe_substring(start=6, end=lines[i].length()))
  let view = if event == Some("thread") {
    entries_view(value, supported)
  } else {
    runtime_view(ty.unwrap(), value, supported, services)
  }
  if is_omit(view) && event == Some("session") {
    // Keep the event's id for resumable streams and remove an obsolete cached session.
    for j in 0..<lines.length() {
      if lines[j].has_prefix("event: ") {
        lines[j] = "event: session-removed"
        break
      }
    }
    lines[i] = "data: " +
      stringify(jobj([("key", value.get("key").unwrap_or(jundef))]))
  } else {
    lines[i] = "data: " + stringify(if is_omit(view) { Null } else { view })
  }
  lines.join("\n")
}

///|
fn find_frame_end(b : Bytes, from : Int32) -> Int32 {
  let mut i = from
  while i + 1 < b.length() {
    if b[i] == b'\n' && b[i + 1] == b'\n' {
      return i
    }
    i += 1
  }
  -1
}

///|
/// An event stream's frames, each projected.
fn events_view(
  next : async () -> Bytes?,
  supported : Array[String],
  services : Bool,
) -> async () -> Bytes? {
  let pending = @buffer.new()
  let out : Array[Bytes] = []
  let ended = Ref(false)
  async fn() {
    while out.length() == 0 && !ended.val {
      match next() {
        Some(chunk) => {
          pending.write_bytes(chunk)
          let all = pending.to_bytes()
          let mut at = 0
          while find_frame_end(all, at) is end && end >= 0 {
            let text = utf8_text(all[at:end].to_bytes())
            out.push(utf8(frame(text, supported, services) + "\n\n"))
            at = end + 2
          }
          pending.reset()
          pending.write_bytes(all[at:].to_bytes())
        }
        None => {
          ended.val = true
          let rest = utf8_text(pending.to_bytes())
          pending.reset()
          if rest != "" {
            out.push(utf8(frame(rest, supported, services)))
          }
        }
      }
    }
    if out.length() > 0 {
      Some(out.remove(0))
    } else {
      None
    }
  }
}

///|
let account_re : Re = re(
  "^\\/(profiles|logins|automatic-decisions|archiving|auto-chats|connects|slack|feishu|group|me\\/slack)(\\/|$)",
)

///|
let entries_re : Re = re("^\\/threads\\/[^/]+\\/entries$")

///|
/// The answer as a client reading only `stillfail-runtimes`' runtimes may be given it.
pub async fn Admin::runtime_compatible(
  self : Admin,
  r : Request,
  answer : Answer,
) -> Answer {
  if answer.status < 200 || answer.status >= 300 {
    return answer
  }
  let supported = client_runtimes(r.headers)
  let services = client_profile_services(r.headers)
  if services && self.setup.runtime_kinds.iter().all(k => supported.contains(k)) {
    return answer
  }
  let path = re("\\/+$").replace_all(r.path, _ => "")
  if path == "/events" {
    match answer.body {
      Stream(next) =>
        return { ..answer, body: Stream(events_view(next, supported, services)), }
      Streamed(next, close) =>
        return {
          ..answer,
          body: Streamed(events_view(next, supported, services), close),
        }
      Whole(_) => ()
    }
  }
  guard answer.body is Whole(bytes) else { return answer }
  if !answer.headers
    .get("content-type")
    .unwrap_or("")
    .has_prefix("application/json") {
    return answer
  }
  if path == "/batch" {
    let gets = jget(Some(parse(r.text())), "gets")
    let raw = parse(utf8_text(bytes))
    guard gets is Some(Arr(gets)) && raw.get("answers") is Some(Arr(answers)) else {
      return answer
    }
    let projected = []
    for i, a in answers {
      match jstr(gets.get(i)) {
        None => projected.push(a)
        Some(g) => {
          let p = self.runtime_compatible(
            {
              ..r,
              verb: "GET",
              path: g.split("?").next().unwrap().to_string(),
            },
            {
              status: jnumber(a.get("status")).unwrap_or(0.0).to_int(),
              headers: { "content-type": "application/json" },
              body: Whole(
                utf8(stringify_opt(a.get("body")).unwrap_or("undefined")),
              ),
            },
          )
          let body = parse(p.text())
          projected.push(jset(jset(a, "status", jint(p.status)), "body", body))
        }
      }
    }
    let headers = answer.headers.copy()
    headers.remove("content-length")
    return {
      ..answer,
      headers,
      body: Whole(utf8(stringify(jset(raw, "answers", jarr(projected))))),
    }
  }
  let ty = shape_for(path)
  let entries = entries_re.matches(path)
  let account = account_re.matches(path)
  if ty is None && !account && !entries {
    return answer
  }
  let raw = parse(utf8_text(bytes))
  let view = if entries {
    entries_view(raw, supported)
  } else if account && raw is Obj(_) {
    match raw.get("overview") {
      Some(o) =>
        jset(raw, "overview", runtime_view(js("Overview"), o, supported, services))
      None => runtime_view(js("Overview"), raw, supported, services)
    }
  } else {
    runtime_view(ty.unwrap(), raw, supported, services)
  }
  if is_omit(view) {
    return error(426, self.tr(r.lang, "station.admin.updateClientForRuntime"))
  }
  let headers = answer.headers.copy()
  headers.remove("content-length")
  { ..answer, headers, body: Whole(utf8(stringify(view))), }
}
