// An agent reads or changes a session's runtime configuration (station/src/sessions/chat-configure.ts),
// here or on another station of its workspace.

///|
pub let configure_method = "session.configure"

///|
let configure_change_keys : Array[String] = [
  "runtime", "model", "effort", "speed", "fast", "context", "preset", "repick",
]

///|
let configure_runtime_kinds : Array[String] = [
  "claude", "codex", "dsh", "grok", "cursor", "devin", "hermes", "agy", "pi",
]

///|
fn cfg_trimmed(v : Json?) -> String? {
  match v {
    None | Some(Null) => None
    Some(x) => {
      let s = js_trim(js_string(x))
      if s == "" { None } else { Some(s) }
    }
  }
}

///|
fn cfg_speed(v : Json) -> String? {
  match v {
    String(s) =>
      match js_trim(s).to_lower() {
        "standard" => Some("standard")
        "fast" => Some("fast")
        "ultrafast" => Some("ultrafast")
        _ => None
      }
    _ => None
  }
}

///|
fn Storage::describe_session(self : Storage, row : Json) -> Json {
  let key = str(row, "key").unwrap_or("")
  let link = match (self.st.hub.world.link)(key) {
    Some(l) if l != "" => js(l)
    _ => Json::null()
  }
  let running = match get(row, "running") {
    Some(True) => true
    Some(Number(n, ..)) => n != 0.0
    _ => false
  }
  jo([
    ("session", js(key)),
    ("link", link),
    ("runtime", get(row, "runtime").unwrap_or(Json::null())),
    ("model", get(row, "model").unwrap_or(Json::null())),
    ("effort", get(row, "effort").unwrap_or(Json::null())),
    ("speed", get(row, "speed").unwrap_or(Json::null())),
    ("fast", get(row, "fast").unwrap_or(Json::null())),
    ("context", get(row, "context").unwrap_or(Json::null())),
    ("profile", get(row, "profile").unwrap_or(Json::null())),
    ("running", jb(running)),
    ("archived", jb(!nullish(get(row, "archivedAt")))),
    ("created_by", get(row, "createdBy").unwrap_or(Json::null())),
  ])
}

///|
async fn Storage::resolve_configure_here(
  self : Storage,
  chat : String,
  ws : String?,
  caller : String?,
) -> String {
  if chat == "" || chat.to_lower() == "self" {
    guard caller is Some(c) else { raise failed("chat is required") }
    return c
  }
  let reference = if chat.contains("/o/") || chat.contains("/chats/") {
    match chat.find("?") {
      Some(at) => cut(chat, 0, end=at)
      None => chat
    }
  } else {
    chat
  }
  match self.named(reference, ws) {
    Session(k, _) => {
      if ws is Some(w) && !self.in_workspace(k, w) {
        raise failed("that chat is in another workspace: only this workspace's chats can be configured")
      }
      k
    }
    Thread(t) => {
      if !self.thread_in(t, ws) {
        raise failed("that chat is in another workspace: only this workspace's chats can be configured")
      }
      if str(t, "home") is Some(h) {
        return h
      }
      let agents = sessions_of(self.st.threads.thread_sessions(get(t, "id").unwrap_or(Json::null())))
      if agents.length() == 0 {
        raise failed("\{reference} has no agent session to configure")
      }
      if agents.length() > 1 {
        raise failed("\{reference} has several agents; pass one session key as chat: \{agents.join(", ")}")
      }
      agents[0]
    }
  }
}

///|
async fn Storage::parse_configure_change(self : Storage, ws : String?, args : Json) -> Json? {
  let obj = match args {
    Object(m) => m
    _ => return None
  }
  if !configure_change_keys.iter().any(k => obj.contains(k)) {
    return None
  }
  if cfg_trimmed(obj.get("preset")) is Some(preset_name) {
    for k in ["runtime", "model", "effort", "speed", "fast", "context"] {
      if obj.contains(k) {
        raise failed("preset cannot be combined with runtime, model, effort, speed, fast or context")
      }
    }
    let scope = match ws {
      Some(w) => Some(w)
      None => self.st.hub.workspaces().get(0)
    }
    let all = items(Some(self.ask("presets.list", [jopt(scope)])))
    let lower = preset_name.to_lower()
    let found = match all.iter().find_first(p => str(p, "id") == Some(preset_name)) {
      Some(p) => Some(p)
      None => all.iter().find_first(p => str(p, "name").unwrap_or("").to_lower() == lower)
    }
    guard found is Some(preset) else {
      if all.is_empty() {
        raise failed("no preset \{preset_name}: this station has none")
      }
      let names = all.map(p => str(p, "name").unwrap_or("")).join(", ")
      raise failed("no preset \{preset_name} on this station; its presets: \{names}")
    }
    let pname = str(preset, "name").unwrap_or(preset_name)
    guard get(preset, "model") is Some(Object(_) as pm) else {
      raise failed("the preset \{pname} does not configure a model")
    }
    let out : Map[String, Json] = {}
    if str(pm, "runtime") is Some(rt) && rt != "" {
      out["runtime"] = js(rt)
    }
    out["model"] = get(pm, "model").unwrap_or(Json::null())
    out["effort"] = get(pm, "effort").unwrap_or(Json::null())
    out["fast"] = get(pm, "fast").unwrap_or(Json::null())
    out["speed"] = get(pm, "speed").unwrap_or(Json::null())
    out["context"] = get(pm, "context").unwrap_or(Json::null())
    match get(pm, "profiles") {
      Some(ps) => out["profiles"] = ps
      None =>
        match get(pm, "profile") {
          Some(p) => out["profile"] = p
          None => out["profile"] = Json::null()
        }
    }
    if obj.get("repick") is Some(rep) {
      match rep {
        True => out["repick"] = jb(true)
        False => ()
        _ => raise failed("repick must be true or false")
      }
    }
    return Some(Json::object(out))
  }
  let out : Map[String, Json] = {}
  if obj.get("runtime") is Some(v) {
    match cfg_trimmed(Some(v)) {
      Some(rt) if configure_runtime_kinds.contains(rt) => out["runtime"] = js(rt)
      _ => raise failed("runtime must be one of \{configure_runtime_kinds.join(", ")}")
    }
  }
  if obj.get("model") is Some(v) {
    out["model"] = match v {
      Null => Json::null()
      _ => jopt(cfg_trimmed(Some(v)))
    }
  }
  if obj.get("effort") is Some(v) {
    out["effort"] = match v {
      Null => Json::null()
      _ => jopt(cfg_trimmed(Some(v)))
    }
  }
  if obj.get("speed") is Some(v) {
    if v is Null || cfg_trimmed(Some(v)) is None {
      out["speed"] = Json::null()
    } else {
      match cfg_speed(v) {
        Some(sp) => out["speed"] = js(sp)
        None => raise failed("speed must be standard, fast or ultrafast")
      }
    }
  }
  if obj.get("fast") is Some(v) {
    match v {
      Null | True | False => out["fast"] = v
      _ => raise failed("fast must be true, false or null")
    }
  }
  if obj.get("context") is Some(v) {
    out["context"] = match v {
      Null => Json::null()
      Number(0.0, ..) => Json::null()
      _ =>
        match @session_hub.context_asked(self.st.hub.words, Some(v), "en") {
          Some(Some(n)) => jn(n)
          _ => Json::null()
        }
    }
  }
  if obj.get("repick") is Some(v) {
    match v {
      True => out["repick"] = jb(true)
      False => ()
      _ => raise failed("repick must be true or false")
    }
  }
  Some(Json::object(out))
}

///|
fn Storage::infer_runtime(self : Storage, ws : String?, cur : String, model : String) -> String? raise Thrown {
  let available = self.st.hub.profiles_in(ws)
  let rts_of = (p : Json) =>
    match get(p, "runtimes") {
      Some(Array(xs)) => xs.filter_map(x => match x { String(s) => Some(s); _ => None })
      _ => []
    }
  let fits_cur = available.iter().any(p => rts_of(p).contains(cur) && @session_hub.runs(p, model))
  if fits_cur {
    None
  } else {
    let matched : Array[String] = []
    for p in available {
      if @session_hub.runs(p, model) {
        for r in rts_of(p) {
          if !matched.contains(r) {
            matched.push(r)
          }
        }
      }
    }
    if matched.length() == 1 {
      Some(matched[0])
    } else if matched.length() > 1 {
      raise failed("model \{model} runs on multiple runtimes (\{matched.join(", ")}): pass runtime")
    } else {
      None
    }
  }
}

///|
async fn Storage::apply_configure_here(self : Storage, target_key : String, change : Json?) -> String {
  guard self.session(target_key) is Some(row) else {
    raise failed("unknown session \{target_key}")
  }
  guard change is Some(ch) else {
    return self.describe_session(row).stringify(indent=2)
  }
  let next = match ch {
    Object(m) => {
      let copy = m.copy()
      if !copy.contains("runtime") {
        if copy.get("model") is Some(String(model)) && model != "" {
          let inferred = self.infer_runtime(str(row, "ws"), str(row, "runtime").unwrap_or(""), model)
          if inferred is Some(rt) && rt != "" {
            copy["runtime"] = js(rt)
          }
        }
      }
      Json::object(copy)
    }
    other => other
  }
  let before = self.describe_session(row)
  self.st.hub.configure(target_key, next, lang="en")
  let after_row = self.session(target_key).unwrap_or(row)
  let after = self.describe_session(after_row)
  jo([("updated", jb(true)), ("before", before), ("after", after)]).stringify(indent=2)
}

///|
pub async fn Storage::chat_configure(self : Storage, key : String, args : Json) -> String {
  let ws = self.scope_of(key)
  let chat = match get(args, "chat") {
    Some(String(s)) => js_trim(s)
    _ => ""
  }
  let change = self.parse_configure_change(ws, args)
  let is_self = chat == "" || chat.to_lower() == "self"
  let mut station = if is_self { None } else { self.elsewhere(key, chat) }
  let mut target_chat = chat
  if !is_self && station is None {
    let ref_key = match linked_session(chat) {
      Some((k, _)) => k
      None => chat
    }
    let moved = self.st.store.handed_to(ref_key)
    if str(moved, "station") is Some(st) && st != "" {
      station = Some(st)
      target_chat = ref_key
    }
  }
  guard station is Some(st) else {
    let target_key = self.resolve_configure_here(target_chat, ws, Some(key))
    return self.apply_configure_here(target_key, change)
  }
  guard self.peers_of(key) is Some(call) else {
    raise failed("other stations cannot be reached from this one yet")
  }
  let req_fields : Array[(String, Json)] = [
    ("method", js(configure_method)),
    ("session", js(key)),
    ("chat", js(target_chat)),
  ]
  if change is Some(ch) {
    req_fields.push(("change", ch))
  }
  let answer = call(st, jo(req_fields)) catch {
    e => {
      let why = message_of(e)
      if is_kind(e, "Refused") && from_before(why) {
        raise failed("station \{st} is not updated yet: its chats cannot be configured from here")
      }
      raise failed("configure request to station \{st} failed: \{why}")
    }
  }
  guard str(answer, "text") is Some(text) else {
    raise failed("station \{st} answered without a configure result")
  }
  text
}

///|
pub async fn Storage::configure_for_peer(self : Storage, request : Json, ws : String?) -> Json {
  let chat = match get(request, "chat") {
    Some(String(s)) => js_trim(s)
    _ => ""
  }
  if chat == "" {
    raise failed("chat is required")
  }
  let target_key = self.resolve_configure_here(chat, ws, None)
  let change = match get(request, "change") {
    None | Some(Null) => None
    Some(Object(m)) if m.is_empty() => None
    Some(Object(_) as ch) => Some(ch)
    _ => raise failed("change must be an object")
  }
  jo([("text", js(self.apply_configure_here(target_key, change)))])
}
