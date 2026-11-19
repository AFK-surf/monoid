///|
/// `[A-Za-z0-9_]`, what `\w` and `\b` take.
fn word_unit(c : Int) -> Bool {
  (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f
}

///|
fn boundary(s : String, at : Int) -> Bool {
  let before = at > 0 && word_unit(s.unsafe_get(at - 1).to_int())
  let after = at < s.length() && word_unit(s.unsafe_get(at).to_int())
  before != after
}

///|
fn at_is(s : String, at : Int, w : String) -> Bool {
  if at < 0 || at + w.length() > s.length() {
    return false
  }
  for j in 0..<w.length() {
    if s.unsafe_get(at + j) != w.unsafe_get(j) {
      return false
    }
  }
  true
}

///|
/// `/\b(?:401|unauthorized|token_revoked)\b|invalidated oauth token/i.test(s)`: a regular expression's `i` folds ASCII
/// letters alone.
fn says_unauthorized(s : String) -> Bool {
  let b = StringBuilder(capacity=s.length())
  for i in 0..<s.length() {
    let c = s.unsafe_get(i).to_int()
    b.write_char((if c >= 0x41 && c <= 0x5a { c + 32 } else { c }).unsafe_to_char())
  }
  let folded = b.to_string()
  for i = 0; i < folded.length(); i = i + 1 {
    if at_is(folded, i, "invalidated oauth token") {
      return true
    }
    if !boundary(folded, i) {
      continue
    }
    for w in ["401", "unauthorized", "token_revoked"] {
      if at_is(folded, i, w) && boundary(folded, i + w.length()) {
        return true
      }
    }
  }
  false
}

///|
/// Why a Codex turn failed (codex.ts `classifyCodexError`), from its error's `codexErrorInfo` (a code, or a code with
/// the HTTP status it came with) and message: the code first, then the status, then what the message says.
pub fn classify_error(info : J?, message : String) -> String {
  let code : String? = match info {
    Some(Str(s)) => Some(s)
    Some(Obj(_) as o) => o.keys().get(0)
    _ => None
  }
  match code {
    Some("unauthorized") => return "auth"
    Some("usageLimitExceeded") | Some("rateLimitExceeded") => return "rate_limit"
    Some("serverOverloaded") => return "overloaded"
    Some("contextWindowExceeded") => return "context"
    _ => ()
  }
  let held = match (code, info) {
    (Some(c), Some(Obj(_) as o)) => o.get(c)
    _ => None
  }
  // (`held && typeof held === "object"`: an array's `httpStatusCode` is none)
  let status = match held {
    Some(Obj(_) as h) =>
      match h.get("httpStatusCode") {
        Some(Num(n)) => Some(n)
        _ => None
      }
    _ => None
  }
  if status is Some(n) && [401.0, 403.0, 429.0, 529.0].contains(n) {
    return @claude.failure_of("\{n.to_int()} " + message)
  }
  // Some versions report the HTTP refusal in the message without an unauthorized codexErrorInfo.
  if says_unauthorized(message) {
    return "auth"
  }
  // The request not made, or its answer cut off, with no status that says more: the way to the provider.
  if ["httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected"].contains(code.unwrap_or("")) &&
    (match status {
      Some(n) => n >= 500.0
      None => true
    }) {
    return "network"
  }
  @claude.failure_of(message)
}

///|
/// The servers of the station's tools (runtime.ts `TOOL_SERVERS`).
let tool_servers : Array[String] = ["stillfail"]

///|
/// What a notification says of the station's tools being out of reach (codex.ts `codexToolsLost`): a call to one of
/// them that failed as unreachable, its error's first 300 characters.
pub fn tools_lost(method : String, params : J) -> String? {
  let item = field(Some(params), "item")
  guard method == "item/completed" &&
    is_str(field(item, "type"), "mcpToolCall") &&
    (match field(item, "server") {
      Some(Str(s)) => tool_servers.contains(s)
      _ => false
    }) &&
    is_str(field(item, "status"), "failed") else {
    return None
  }
  let error = text(field(field(item, "error"), "message"))
  if @claude.unreachable(error) {
    Some(@claude.chars(error, 300))
  } else {
    None
  }
}

///|
/// Whether a notification says its thread compacted its context, on its own as it filled or by thread/compact/start
/// (codex.ts `codexCompacted`): a contextCompaction item done.
pub fn compacted(method : String, params : J) -> Bool {
  method == "item/completed" && is_str(field(field(Some(params), "item"), "type"), "contextCompaction")
}

///|
/// A turn's outcome as its `turn/completed` says it (runtime.ts `TurnOutcome`): interrupted, failed with its reason and
/// at most 1000 characters of its message, else completed.
pub fn outcome(params : J) -> J {
  let turn = field(Some(params), "turn")
  let status = field(turn, "status")
  if is_str(status, "interrupted") {
    return obj([("kind", jstr("aborted"))])
  }
  if is_str(status, "failed") {
    let error = field(turn, "error")
    let message = match field(error, "message") {
      Some(Str(m)) => Some(m)
      _ => None
    }
    let info = match field(error, "codexErrorInfo") {
      None => None
      v => v
    }
    return obj([
      ("kind", jstr("failed")),
      ("reason", jstr(classify_error(info, message.unwrap_or("")))),
      ("message", Str(@claude.chars(message.unwrap_or("turn failed"), 1000))),
    ])
  }
  obj([("kind", jstr("completed"))])
}

///|
/// What a thread's notification comes to for its session (codex.ts `CodexSession.sink`), its live steps fed: its live
/// steps, the station's tools out of reach, a compaction, a turn's start (with the turn's id where it says one) and its
/// end with its outcome, as runtime events.
pub fn events(live : Live, method : String, params : J) -> Array[J] {
  let out = live.feed(method, params).map(e => obj([("type", jstr("live")), ("event", e)]))
  if tools_lost(method, params) is Some(why) {
    out.push(obj([("type", jstr("toolsLost")), ("why", Str(why))]))
  }
  if compacted(method, params) {
    out.push(obj([("type", jstr("compacted"))]))
  }
  match method {
    "turn/started" => {
      let fields = [("type", jstr("turnStarted"))]
      if field(field(Some(params), "turn"), "id") is Some(Str(id)) {
        fields.push(("turnId", Str(id)))
      }
      out.push(Obj(fields))
    }
    "turn/completed" => out.push(obj([("type", jstr("turnEnded")), ("outcome", outcome(params))]))
    _ => ()
  }
  out
}
