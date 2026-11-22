// runtime.ts and live.ts: the seam's own words, what every driver says of a turn's failure and of the station's tools.
// What failed a turn by what a runtime said of it (`failureOf`) is the reading's already (mb/src/claude
// `failure_of`), and so is what says the tools are out of reach (`unreachable`): taken from there, one text for both.

///|
/// A runtime as stored or sent (`runtimeKind`) and how it is named to people (`runtimeLabel`).
pub using @agent_runtimes {runtime_kind, runtime_label}

///|
/// The station's tools by their server's name.
let tool_servers : Array[String] = ["stillfail"]

///|
/// A tool call's error that says the station's tools could not be reached at all.
pub fn tools_unreachable(text : String) -> Bool {
  @claude.unreachable(text)
}

///|
/// Whether a call, by the name the station gives it, is to one of the station's tools (`stationTool`).
pub fn station_tool(name : String) -> Bool {
  tool_servers.iter().any(s => name.has_prefix("mcp__\{s}__") || name.has_prefix("\{s}__"))
}

///|
/// What failed a turn by what the runtime said of it, with its own words of the account and its limits.
pub fn failure_of(
  text : String,
  auth_codes? : Array[String] = [],
  auth? : Array[String] = [],
  limit_codes? : Array[String] = [],
  limit? : Array[String] = [],
) -> String {
  @claude.failure_of(text, auth_codes~, auth~, limit_codes~, limit~)
}

///|
/// At most `n` characters (`chars`: Rust's chars().take(n)), a pair of surrogates one.
pub fn chars(text : String, count : Int) -> String {
  if text.length() <= count {
    return text
  }
  @jsjson.sanitize_str(@claude.chars(text, count))
}

///|
pub fn ascii_word(c : Int) -> Bool {
  (c >= 0x30 && c <= 0x39) ||
  (c >= 0x41 && c <= 0x5a) ||
  (c >= 0x61 && c <= 0x7a) ||
  c == 0x5f
}

///|
pub fn lower_ascii(c : Int) -> Int {
  if c >= 0x41 && c <= 0x5a {
    c + 32
  } else {
    c
  }
}

///|
/// `\b` at `i` of `u` (ASCII words, as a regular expression without `u` has them).
pub fn boundary(u : Array[Int], i : Int) -> Bool {
  let before = i > 0 && ascii_word(u[i - 1])
  let after = i < u.length() && ascii_word(u[i])
  before != after
}

///|
/// `word` at `i` of `u`, ASCII letters in either case.
pub fn at_word(u : Array[Int], i : Int, word : String) -> Bool {
  if i + word.length() > u.length() {
    return false
  }
  for k in 0..<word.length() {
    if lower_ascii(u[i + k]) != word.unsafe_charcode_at(k) {
      return false
    }
  }
  true
}

///|
/// The model whose own allowance a limit was, as the runtime named it, none for the account's own (`modelLimitOf`).
pub fn model_limit_of(text : String) -> String? {
  let u = @jsjson.units(text)
  let in_name = (c : Int) => ascii_word(c) || c == 0x2e || c == 0x2d || c == 0x20
  for start in 0..<u.length() {
    if !boundary(u, start) {
      continue
    }
    let after_verb = if at_word(u, start, "reached") {
      start + 7
    } else if at_word(u, start, "hit") {
      start + 3
    } else {
      continue
    }
    if !at_word(u, after_verb, " your ") {
      continue
    }
    let from = after_verb + 6
    let mut k = from
    while k < u.length() && in_name(u[k]) {
      k += 1
      // (lazily: the least name followed by " limit" and a boundary)
      if at_word(u, k, " limit") && boundary(u, k + 6) {
        let name = @jscase.trim(@jsjson.text(u[from:k].to_array()))
        return if name != "" && !account_limit(name) { Some(name) } else { None }
      }
    }
  }
  None
}

///|
/// `\b(?:usage|session|weekly|daily|monthly|spend|rate|\d+[- ]hour)\b`, either case.
pub fn account_limit(name : String) -> Bool {
  let u = @jsjson.units(name)
  for i in 0..<u.length() {
    if !boundary(u, i) {
      continue
    }
    for w in ["usage", "session", "weekly", "daily", "monthly", "spend", "rate"] {
      if at_word(u, i, w) && boundary(u, i + w.length()) {
        return true
      }
    }
    let mut k = i
    while k < u.length() && u[k] >= 0x30 && u[k] <= 0x39 {
      k += 1
    }
    if k > i &&
      k < u.length() &&
      (u[k] == 0x2d || u[k] == 0x20) &&
      at_word(u, k + 1, "hour") &&
      boundary(u, k + 5) {
      return true
    }
  }
  false
}

///|
/// What failed once neither the account, the provider nor a limit: the conversation's size, the network, else the
/// model (`failureRest`).
pub fn failure_rest(text : String) -> String {
  let lower = @jscase.lower(text)
  let context = [
    "context window", "context_window", "context length", "context_length", "context overflow", "prompt is too long",
    "maximum context", "too many tokens", "input is too long",
  ]
  if context.iter().any(w => lower.contains(w)) {
    return "context"
  }
  let u = @jsjson.units(text)
  let network = [
    "stream disconnected", "error sending request", "connection reset", "connection refused", "connection closed",
    "connection error", "connection failed", "network error", "timed out", "timeout", "econnreset", "econnrefused",
    "etimedout", "enotfound", "eai_again", "epipe", "socket hang up", "fetch failed", "dns error", "tls handshake",
  ]
  for i in 0..<u.length() {
    for w in network {
      if at_word(u, i, w) {
        return "network"
      }
    }
  }
  "model"
}

///|
/// Where the station's tools were for a process taken up after a crash (`options.mcpUrl || null`): none where the
/// station's door was not open yet ("") as it took it up, so the address the door opens on is not taken for another
/// one the process was told (`Actors::tools_at`).
fn crashed_tools_url(o : JValue?) -> String? {
  match str_at(o, "mcpUrl") {
    Some(u) if u != "" => Some(u)
    _ => None
  }
}
