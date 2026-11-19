// The device tools (station/src/mesh/tools.ts; contract v1 §8), over the presence socket or on the mesh: ALPN
// `comma/tools/1`, admitted only from the iroh ids the control plane names as its gateways. One request a stream: a
// JSON head line `{op, id, context, args}`, answered by one JSON line `{ok: true, result}` or `{ok: false, error: {code,
// message}}`. What an op does is the station's (`run`, given); the chats it starts and drives are made and said
// through the admin API (`ask`, given), as the person it names.

///|
pub let tools_alpn : String = "comma/tools/1"

///|
/// A request's line holds its arguments: up to 12 MiB (contract §8).
pub let max_tools_line : Int = 12 * 1024 * 1024

///|
/// How long a request's line may take to come.
pub let tools_line_ms : Int = 120_000

///|
/// What the tools stand on (`ToolsDeps`), read at each request.
pub(all) struct ToolsDeps {
  /// Whether the station's provider has gateways at all.
  enabled : () -> Bool
  /// The workspace of the station's state, None before it has one.
  workspace : () -> String?
  /// Whether the station was removed.
  removed : () -> Bool
  /// The gateways' keys, as the presence socket said last.
  gateway_keys : () -> Array[String]
  /// An op run: its result, or the refusal's code and words (`ToolError`).
  run : async (String, Json, Json) -> Result[Json, (String, String)]
  said : (String, String, Json) -> Unit
}

///|
/// Why `peer` may not call the tools now, or None when it may (`refusal`).
pub fn tools_refusal(d : ToolsDeps, peer : String) -> String? {
  if !(d.enabled)() || (d.workspace)() is None {
    return Some("this station takes no device tools")
  }
  if (d.removed)() {
    return Some("station removed")
  }
  if !(d.gateway_keys)().contains(peer) {
    return Some("not a gateway of this station's control plane")
  }
  None
}

///|
/// Why a request over the presence socket may not be answered now (`presenceTools`): being on it is the admission.
pub fn presence_refusal(d : ToolsDeps) -> String? {
  if !(d.enabled)() || (d.workspace)() is None {
    return Some("this station takes no device tools")
  }
  if (d.removed)() {
    return Some("station removed")
  }
  None
}

///|
fn failed(code : String, message : String) -> Json {
  jobj([("ok", Json::boolean(false)), ("error", jobj([("code", jstr(code)), ("message", jstr(message))]))])
}

///|
/// One request answered (`answer`); `refused` says why the caller may not call now, read at the request.
pub async fn tools_answer(d : ToolsDeps, head : Json?, refused : () -> String?) -> Json {
  if refused() is Some(still) {
    return failed("forbidden", still)
  }
  guard head is Some(Object(h)) && h.get("op") is Some(String(op)) else {
    return failed("invalid_request", "a request names its op")
  }
  let args = match h.get("args") {
    Some(Object(_) as a) => a
    _ => Json::object(Map([]))
  }
  let context = match h.get("context") {
    Some(Object(_) as c) => c
    // (`typeof [] === "object"`: an array is a context with nothing in it)
    Some(Array(_) as c) => c
    _ => Json::object(Map([]))
  }
  let theirs = match context {
    Object(c) => c.get("workspace")
    _ => None
  }
  let ours = (d.workspace)()
  let same = match (theirs, ours) {
    (Some(String(t)), Some(o)) => t == o
    (None, None) => true
    _ => false
  }
  if !same {
    return failed("forbidden", "the request is for another workspace than this station's")
  }
  let result = (d.run)(op, args, context) catch { e => return failed("invalid_request", message_of(e)) }
  let agent = match context {
    Object(c) => c.get("agent").unwrap_or(Json::null())
    _ => Json::null()
  }
  (d.said)(
    "info",
    "device tool",
    jobj([
      ("op", jstr(op)),
      ("id", match h.get("id") { Some(String(_) as i) => i; _ => Json::null() }),
      ("ok", Json::boolean(result is Ok(_))),
      ("agent", agent),
    ]),
  )
  match result {
    Ok(r) => jobj([("ok", Json::boolean(true)), ("result", r)])
    Err((code, message)) => failed(code, message)
  }
}

///|
/// A gateway's connection (`serveTools`): each of its streams one op, while it is a gateway. One that is none is
/// closed (`not_a_gateway`) and refused.
pub async fn serve_tools(d : ToolsDeps, conn : @door.Connection, rt : @effect.Runtime) -> Unit {
  let peer = (conn.remote_id)()
  if tools_refusal(d, peer) is Some(refused) {
    (conn.close)(1, "not_a_gateway")
    raise Failure(refused)
  }
  while (conn.accept_bi)() is Some(stream) {
    ignore(
      rt.fork(name="tools", () => {
        let reader = @door.Reader::new(stream, max_line=max_tools_line)
        let reply = (async fn() -> Json {
          match @effect.timeout(tools_line_ms, () => reader.line()) {
            None => failed("invalid_request", "tools request timed out")
            Some(head) => tools_answer(d, head, () => tools_refusal(d, peer))
          }
        })() catch {
          e => failed("invalid_request", message_of(e))
        }
        (async fn() {
          @door.write_line(stream, reply)
          (stream.finish)()
        })() catch {
          e => (d.said)("info", "tools stream ended", jobj([("error", jstr(message_of(e)))]))
        }
      }),
    )
  }
}

///|
/// The same requests over the presence socket (`presenceTools`).
pub async fn presence_tools(d : ToolsDeps, request : Json?) -> Json {
  tools_answer(d, request, () => presence_refusal(d))
}

///|
/// What the admin API answered a request of the tools' (`adminSessions`' `ask`): its value, or why it failed and the
/// code that says so (`not_found`, `forbidden`, `failed`).
pub fn admin_answered(status : Int, text : String) -> Result[Json, (String, String)] {
  let value = payload_json(@utf8.encode(text)).unwrap_or(Json::null())
  if status >= 300 {
    let message = match field(value, "error") {
      Some(String(e)) => e
      _ => "the station answered \{status}"
    }
    let code = if status == 404 {
      "not_found"
    } else if status == 403 {
      "forbidden"
    } else {
      "failed"
    }
    return Err((message, code))
  }
  Ok(value)
}

///|
/// A refusal of the admin API's, with its code (`Object.assign(new Error(…), {code})`).
pub(all) suberror AdminRefused {
  AdminRefused(String, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for AdminRefused with output(self, logger) {
  match self {
    AdminRefused(m, _) => logger.write_string(m)
  }
}

///|
/// A request of the admin API's, as the person `requester` (method, path, body): its value.
pub type Ask = async (String, String, String, Json) -> Json

///|
/// The chat a tool starts (`start`): made by its runtime (the one asked, else the first the station has of `kinds`,
/// else codex), its prompt said in it; its session and thread.
pub async fn tools_start(
  ask : Ask,
  runtimes : Array[String],
  kinds : Array[String],
  prompt : String,
  title : String?,
  runtime : String?,
  requester : String,
) -> (String, String) {
  let which = match runtime {
    Some(r) => r
    None =>
      match kinds.search_by(r => runtimes.contains(r)) {
        Some(i) => kinds[i]
        None => "codex"
      }
  }
  let body = [("runtime", jstr(which))]
  if title is Some(t) {
    body.push(("title", jstr(t)))
  }
  let made = ask(requester, "POST", "/sessions", jobj(body))
  let thread_of = match field(made, "thread") {
    Some(t) =>
      match field(t, "id") {
        Some(Null) | None => field(t, "thread")
        id => id
      }
    None => None
  }
  let thread = match thread_of {
    None | Some(Null) => ""
    Some(String(s)) => s
    Some(Number(n, ..)) => js_num(n)
    Some(True) => "true"
    Some(False) => "false"
    Some(other) => js_string_of(other)
  }
  if thread == "" {
    raise Failure("the chat was made without a thread")
  }
  ignore(ask(requester, "POST", "/threads/\{thread}/messages", jobj([("text", jstr(prompt)), ("client", jstr("comma tools"))])))
  let key = match field(made, "key") {
    Some(String(s)) => s
    Some(Number(n, ..)) => js_num(n)
    None => "undefined"
    Some(other) => js_string_of(other)
  }
  (key, thread)
}

///|
/// `String(v)` of an object or array: what JavaScript says of it.
fn js_string_of(v : Json) -> String {
  match v {
    Array(xs) => xs.map(x => match x { Null => ""; String(s) => s; Number(n, ..) => js_num(n); other => js_string_of(other) }).join(",")
    Object(_) => "[object Object]"
    Null => "null"
    True => "true"
    False => "false"
    Number(n, ..) => js_num(n)
    String(s) => s
  }
}

///|
/// `encodeURIComponent(s)`.
pub fn encode_uri_component(s : String) -> String {
  let b = StringBuilder()
  let hex = "0123456789ABCDEF"
  for byte in @utf8.encode(s) {
    let c = byte.to_int()
    let keep = (c >= 0x41 && c <= 0x5a) ||
      (c >= 0x61 && c <= 0x7a) ||
      (c >= 0x30 && c <= 0x39) ||
      c == 0x2d || c == 0x5f || c == 0x2e || c == 0x21 || c == 0x7e || c == 0x2a || c == 0x27 || c == 0x28 || c == 0x29
    if keep {
      b.write_char(c.unsafe_to_char())
    } else {
      b.write_char('%')
      b.write_char(hex.code_unit_at(c >> 4).to_int().unsafe_to_char())
      b.write_char(hex.code_unit_at(c & 15).to_int().unsafe_to_char())
    }
  }
  b.to_string()
}

///|
/// What a tool says in a chat (`say`).
pub async fn tools_say(ask : Ask, thread : String, text : String, requester : String) -> Unit {
  ignore(
    ask(requester, "POST", "/threads/\{encode_uri_component(thread)}/messages", jobj([("text", jstr(text)), ("client", jstr("comma tools"))])),
  )
}

///|
/// The store a chat's status is read from (`adminSessions`' `store`): whether a thread is, its sessions, and the last
/// turn of each (a row as the store gives it, None for none).
pub(all) struct ToolsStore {
  has_thread : (Double) -> Bool
  thread_sessions : (Double) -> Array[String]
  last_turn : (String) -> Json?
}

///|
/// Where the chat of `thread` is (`status`): None where the store is not open, the thread is no whole number
/// (`Number(thread)`, so "" is 0 and " 42 " is 42) or no thread of the store.
pub fn tools_thread_status(store : ToolsStore?, thread : String) -> Json? {
  guard store is Some(s) else { return None }
  let id = js_number(thread)
  if !js_is_integer(id) || !(s.has_thread)(id) {
    return None
  }
  Some(tools_status((s.thread_sessions)(id).filter_map(k => (s.last_turn)(k))))
}

///|
/// Where a chat is (`status`), by its turns' rows (`lastTurn` of each of its sessions): running while one is, else what
/// the last begun said (`all_done`, `need_human`, `waiting`, `idle`) with its summary.
pub fn tools_status(turns : Array[Json]) -> Json {
  if turns.iter().any(t => field(t, "endedAt") is Some(Null)) {
    return jobj([("state", jstr("running"))])
  }
  guard turns.length() > 0 else { return jobj([("state", jstr("idle"))]) }
  // (the latest begun; of those begun at once, the first: a stable sort's)
  let mut last = turns[0]
  let started = (t : Json) => num_of(field(t, "startedAt")).unwrap_or(@double.not_a_number)
  for t in turns {
    if started(t) > started(last) {
      last = t
    }
  }
  let some = (k : String) => match field(last, k) {
    None | Some(Null) => None
    v => v
  }
  let said = match some("declared") {
    Some(String(s)) => s
    Some(_) => ""
    None =>
      match some("ending") {
        Some(String(s)) => s
        _ => ""
      }
  }
  let summary = match some("detail") {
    Some(v) => Some(v)
    None => some("need")
  }
  let state = match said {
    "all_done" | "final" => "all_done"
    "need_help" | "need_human" | "block" | "need_decision" => "need_human"
    "waiting" => "waiting"
    _ => "idle"
  }
  match summary {
    None => jobj([("state", jstr(state))])
    Some(s) => jobj([("state", jstr(state)), ("summary", s)])
  }
}
