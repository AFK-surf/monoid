// What the agents spent, read from their transcripts (station/src/usage/counter.ts `callsOf`): each model call a
// runtime wrote, as the counter there reads it, line for line.

///|
/// store/usage.ts `UsageCall`.
pub(all) struct Call {
  id : String
  at : Double
  model : String?
  subagent : Bool
  fast : Bool
  input : Double
  cache_read : Double
  cache_write : Double
  cache_write_long : Double
  mut output : Double
  calls : Double
  context : Double?
  window : Double?
  /// How long it took (ms; speed.mbt): 0, not known.
  mut gen_ms : Double
}

///|
/// counter.ts `CallState`: the model last named (Codex), its session's id (Codex's first line) and the model's window as
/// last told (dsh).
pub(all) struct CallState {
  mut model : String?
  mut codex_id : String?
  mut window : Double?
  /// Where its reading stands of its model's time (speed.mbt).
  mut speed : Speed
}

///|
/// A property of an object (counter.ts `get`): None where the value is no object or has none of that name.
fn get(v : Json?, k : String) -> Json? {
  match v {
    Some(Object(m)) => m.get(k)
    _ => None
  }
}

///|
fn str(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// serde_json's as_i64, or 0 (counter.ts `n`: an integer JSON says).
fn n(v : Json?) -> Double {
  match v {
    Some(Number(d, ..)) if !d.is_nan() && !d.is_inf() && d == d.floor() => d
    _ => 0.0
  }
}

///|
/// counter.ts `told`: a count a line tells, none when it says none.
fn told(v : Json?) -> Double? {
  let x = n(v)
  if x > 0.0 {
    Some(x)
  } else {
    None
  }
}

///|
/// A number JSON says, as `typeof v === "number"` takes it.
fn number(v : Json?) -> Double? {
  match v {
    Some(Number(d, ..)) => Some(d)
    _ => None
  }
}

///|
fn max_d(a : Double, b : Double) -> Double {
  if a >= b {
    a
  } else {
    b
  }
}

///|
fn min_d(a : Double, b : Double) -> Double {
  if a <= b {
    a
  } else {
    b
  }
}

///|
/// A number as JavaScript writes it in a template (integers as their digits).
pub fn js_number(d : Double) -> String {
  if d == d.floor() && d.abs() < 1.0e21 {
    if d == 0.0 {
      "0"
    } else {
      d.to_int64().to_string()
    }
  } else {
    d.to_string()
  }
}

///|
/// JValue (JSON.parse's reading) as Json: a lone surrogate as U+FFFD, as Node binds it.
fn of_jvalue(v : @jsjson.JValue) -> Json {
  v.to_json_lossy()
}

///|
/// A line as JSON.parse reads it; None where it is not JSON.
fn parse_line(line : String) -> Json? {
  try {
    Some(@json.parse(line))
  } catch {
    _ =>
      try {
        Some(of_jvalue(@jsjson.parse(line)))
      } catch {
        _ => None
      }
  }
}

///|
/// transcript.ts `parseIso`: milliseconds of an ISO time (YYYY-MM-DDTHH:MM:SS[.fff]), read by position.
pub fn parse_iso(at : String) -> Double? {
  @readops.parse_iso(at)
}

///|
/// Whether `b` holds `p` (ASCII): as the line's text includes it.
fn holds(b : BytesView, p : Bytes) -> Bool {
  let m = p.length()
  if m == 0 {
    return true
  }
  let first = p[0]
  let last = b.length() - m
  let mut i = 0
  while i <= last {
    if b[i] == first {
      let mut j = 1
      while j < m && b[i + j] == p[j] {
        j += 1
      }
      if j == m {
        return true
      }
    }
    i += 1
  }
  false
}

///|
fn begins(b : BytesView, p : Bytes) -> Bool {
  if b.length() < p.length() {
    return false
  }
  for i in 0..<p.length() {
    if b[i] != p[i] {
      return false
    }
  }
  true
}

///|
let usage_word : Bytes = b"\"usage\""

///|
let dsh_message : Bytes = b"{\"type\":\"assistant/message\""

///|
let dsh_context : Bytes = b"{\"type\":\"request/context\""

///|
let pi_message : Bytes = b"{\"type\":\"message\""

///|
let grok_usage : Bytes = b"{\"type\":\"stillfail/usage\""

///|
let type_usage : Bytes = b"\"type\":\"usage\""

///|
let type_user : Bytes = b"\"type\":\"user\""

///|
let type_tool : Bytes = b"\"type\":\"tool\""

///|
let type_end : Bytes = b"\"type\":\"end\""

///|
let token_count : Bytes = b"token_count"

///|
let turn_context : Bytes = b"turn_context"

///|
let session_meta : Bytes = b"session_meta"

///|
/// Whether a line may hold usage (counter.ts: only those are parsed).
fn wanted(runtime : String, line : BytesView) -> Bool {
  match runtime {
    "claude" => holds(line, usage_word)
    "dsh" => (begins(line, dsh_message) && holds(line, usage_word)) || begins(line, dsh_context)
    "grok" => begins(line, grok_usage)
    "pi" => begins(line, pi_message) && holds(line, usage_word)
    "cursor" | "devin" | "hermes" | "copilot" => holds(line, type_usage)
    "agy" => holds(line, type_usage) || holds(line, type_user) || holds(line, type_tool) || holds(line, type_end)
    _ => holds(line, token_count) || holds(line, turn_context) || holds(line, session_meta)
  }
}

///|
/// counter.ts `callsOf`: a transcript's lines (`text`, whole lines' bytes) read into calls; `state` carries the model,
/// Codex id and window on.
pub fn calls_of(runtime : String, text : BytesView, subagent : Bool, state : CallState) -> Array[Call] {
  let out : Array[Call] = []
  let at_index : Map[String, Int] = Map([])
  let mut start = 0
  let len = text.length()
  while start <= len {
    let mut end = start
    while end < len && text[end] != b'\n' {
      end += 1
    }
    let next = end + 1
    let stop = if end > start && text[end - 1] == b'\r' { end - 1 } else { end }
    let line = text[start:stop]
    start = next
    speed_line(runtime, line, state.speed)
    if !wanted(runtime, line) {
      continue
    }
    guard parse_line(@utf8.decode_lossy(line)) is Some(r) else { continue }
    let rec = Some(r)
    let stamp = str(get(rec, "timestamp"))
    let at = match stamp {
      Some(s) => parse_iso(s).unwrap_or(0.0)
      None => 0.0
    }
    match runtime {
      "grok" => {
        let usage = get(rec, "usage")
        let id = str(get(rec, "id"))
        guard usage is Some(u) && !(u is Null) && id is Some(id) else { continue }
        out.push({
          id: "grok:" + id,
          at: number(get(rec, "time")).unwrap_or(0.0),
          model: str(get(rec, "model")),
          subagent,
          fast: false,
          input: n(get(usage, "input")),
          cache_read: n(get(usage, "cacheRead")),
          cache_write: n(get(usage, "cacheWrite")),
          cache_write_long: 0.0,
          output: n(get(usage, "output")),
          calls: max_d(1.0, n(get(usage, "calls"))),
          context: told(get(rec, "context")),
          window: told(get(rec, "window")),
          gen_ms: 0.0,
        })
      }
      "cursor" | "devin" | "hermes" | "copilot" => {
        let usage = get(rec, "usage")
        let id = str(get(rec, "run"))
        guard str(get(rec, "type")) == Some("usage") && usage is Some(u) && !(u is Null) && id is Some(id) else {
          continue
        }
        out.push({
          id: runtime + ":" + id,
          at: number(get(rec, "time")).unwrap_or(0.0),
          model: str(get(rec, "model")),
          subagent,
          fast: false,
          input: n(get(usage, "inputTokens")),
          cache_read: n(get(usage, "cacheReadTokens")),
          cache_write: n(get(usage, "cacheWriteTokens")),
          cache_write_long: 0.0,
          output: n(get(usage, "outputTokens")),
          calls: max_d(1.0, n(get(rec, "calls"))),
          context: told(get(rec, "context")),
          window: told(get(rec, "window")),
          gen_ms: 0.0,
        })
      }
      "agy" => {
        let kind = str(get(rec, "type"))
        if kind == Some("user") {
          if get(rec, "steered") is Some(True) {
            continue
          }
          match valid_time(get(rec, "time")) {
            Some(t) => state.speed.agy = Some({ turn_start: Some(t), invalid: false, usages: [], tools: [] })
            None => state.speed.agy = Some({ turn_start: None, invalid: true, usages: [], tools: [] })
          }
        } else if kind == Some("tool") {
          if state.speed.agy is Some(agy) && !agy.invalid && agy.turn_start is Some(_) {
            match (valid_time(get(rec, "startedAt")), valid_time(get(rec, "time"))) {
              (Some(s), Some(e)) if e >= s => agy_add_tool(agy, s, e)
              (Some(s), Some(e)) if s - e <= agy_tool_skew_ms => ()
              _ => agy_invalidate(agy)
            }
          }
        } else if kind == Some("usage") {
          let usage = get(rec, "usage")
          let id = str(get(rec, "run"))
          guard usage is Some(u) && !(u is Null) && id is Some(id) else { continue }
          let call_id = "agy:" + id
          let at_opt = valid_time(get(rec, "time"))
          let at_val = number(get(rec, "time")).unwrap_or(0.0)
          let out_tokens = n(get(usage, "outputTokens"))
          let out_opt = match get(usage, "outputTokens") {
            None => Some(0.0)
            v => valid_safe_int(v)
          }
          if !at_index.contains(call_id) {
            at_index[call_id] = out.length()
          }
          out.push({
            id: call_id,
            at: at_val,
            model: str(get(rec, "model")),
            subagent,
            fast: false,
            input: n(get(usage, "inputTokens")),
            cache_read: n(get(usage, "cacheReadTokens")),
            cache_write: n(get(usage, "cacheWriteTokens")),
            cache_write_long: 0.0,
            output: out_tokens,
            calls: max_d(1.0, n(get(rec, "calls"))),
            context: told(get(rec, "context")),
            window: told(get(rec, "window")),
            gen_ms: 0.0,
          })
          if state.speed.agy is Some(agy) && !agy.invalid && agy.turn_start is Some(_) {
            match at_opt {
              None => agy_invalidate(agy)
              Some(ut) => agy_add_usage(agy, call_id, ut, out_opt)
            }
          }
        } else if kind == Some("end") {
          let end_opt = valid_time(get(rec, "time"))
          if state.speed.agy is Some(agy) {
            if !agy.invalid && agy.turn_start is Some(ts) && end_opt is Some(et) && agy.usages.length() > 0 {
              let mut valid = et >= ts
              if valid && agy.tools.length() > 0 && agy.tools[agy.tools.length() - 1].end > et {
                valid = false
              }
              let mut check_prev = ts
              if valid {
                for u in agy.usages {
                  if u.at < check_prev || u.at > et {
                    valid = false
                    break
                  }
                  check_prev = u.at
                }
              }
              if valid {
                let mut prev = ts
                for u in agy.usages {
                  let net = agy_segment_gen_ms(agy.tools, prev, u.at)
                  if net > 0.0 && u.output is Some(out_tok) && out_tok * 1000.0 <= net * agy_max_tps {
                    match at_index.get(u.id) {
                      Some(i) => out[i].gen_ms = max_d(out[i].gen_ms, net)
                      None =>
                        out.push({
                          id: u.id,
                          at: u.at,
                          model: None,
                          subagent,
                          fast: false,
                          input: 0.0,
                          cache_read: 0.0,
                          cache_write: 0.0,
                          cache_write_long: 0.0,
                          output: 0.0,
                          calls: 0.0,
                          context: None,
                          window: None,
                          gen_ms: net,
                        })
                    }
                  }
                  prev = u.at
                }
              }
            }
            state.speed.agy = None
          }
        }
      }
      "pi" => {
        // Each answer of the model's as Pi kept it in the session (agents/pi.ts): its usage pi-ai's, input apart from
        // the cache's; a failed or stopped one that used nothing is no call.
        let message = get(rec, "message")
        let usage = get(message, "usage")
        let id = str(get(rec, "id"))
        guard str(get(message, "role")) == Some("assistant") && usage is Some(u) && !(u is Null) && id is Some(id) else {
          continue
        }
        let input = n(get(usage, "input"))
        let cache_read = n(get(usage, "cacheRead"))
        let cache_write = n(get(usage, "cacheWrite"))
        let output = n(get(usage, "output"))
        if input + cache_read + cache_write + output == 0.0 {
          continue
        }
        out.push({
          id: "pi:" + id,
          at,
          model: str(get(message, "model")),
          subagent,
          fast: false,
          input,
          cache_read,
          cache_write,
          cache_write_long: 0.0,
          output,
          calls: 1.0,
          context: if subagent { None } else { Some(input + cache_read + cache_write) },
          window: state.window,
          gen_ms: 0.0,
        })
      }
      "dsh" => {
        let data = get(rec, "data")
        if str(get(rec, "type")) == Some("request/context") {
          state.window = match told(get(data, "contextWindow")) {
            Some(w) => Some(w)
            None => state.window
          }
          continue
        }
        let usage = get(data, "usage")
        let message = get(data, "message")
        let id = str(get(message, "id"))
        guard usage is Some(u) && !(u is Null) && id is Some(id) else { continue }
        let input = n(get(usage, "inputTokens"))
        let cache_read = n(get(usage, "cacheReadTokens"))
        let cache_write = n(get(usage, "cacheWriteTokens"))
        out.push({
          id: "dsh:" + id,
          at: number(get(rec, "time")).unwrap_or(0.0),
          model: str(get(get(message, "source"), "model")),
          subagent,
          fast: false,
          input,
          cache_read,
          cache_write,
          cache_write_long: 0.0,
          output: n(get(usage, "outputTokens")),
          calls: 1.0,
          context: if subagent { None } else { Some(input + cache_read + cache_write) },
          window: state.window,
          gen_ms: 0.0,
        })
      }
      "claude" => {
        guard str(get(rec, "type")) == Some("assistant") else { continue }
        let m = get(rec, "message")
        guard m is Some(_) else { continue }
        let usage = get(m, "usage")
        let id = str(get(m, "id"))
        guard usage is Some(_) && id is Some(id) else { continue }
        let name = str(get(m, "model"))
        guard name is Some(name) && name != "<synthetic>" else { continue }
        let written = n(get(usage, "cache_creation_input_tokens"))
        let split = get(usage, "cache_creation")
        let long = if split is None { 0.0 } else { n(get(split, "ephemeral_1h_input_tokens")) }
        let five = if split is None { None } else { Some(n(get(split, "ephemeral_5m_input_tokens"))) }
        let short = match five {
          Some(f) if f + long == written => f
          _ => written - long
        }
        let side = subagent || get(rec, "isSidechain") is Some(True)
        let input = n(get(usage, "input_tokens"))
        let cache_read = n(get(usage, "cache_read_input_tokens"))
        // Its time: from when it was asked (as its first line came) to its line (a block written), a sidechain's untold.
        if !side && state.speed.open_id != Some(id) {
          state.speed.open_id = Some(id)
          state.speed.open_start = state.speed.since
        }
        let call : Call = {
          id,
          at,
          model: Some(name),
          subagent: side,
          fast: str(get(usage, "speed")) == Some("fast"),
          input,
          cache_read,
          cache_write: short,
          cache_write_long: long,
          output: n(get(usage, "output_tokens")),
          calls: 1.0,
          context: if side { None } else { Some(input + cache_read + written) },
          window: None,
          gen_ms: if side { 0.0 } else { gen_of(state.speed.open_start, Some(at)) },
        }
        match at_index.get(id) {
          Some(i) => {
            out[i].output = max_d(out[i].output, call.output)
            out[i].gen_ms = max_d(out[i].gen_ms, call.gen_ms)
          }
          None => {
            at_index[id] = out.length()
            out.push(call)
          }
        }
      }
      _ => {
        let p = get(rec, "payload")
        let kind = str(get(rec, "type"))
        if kind == Some("session_meta") {
          if str(get(p, "id")) is Some(id) {
            state.codex_id = Some(id)
          }
        } else if kind == Some("turn_context") {
          if str(get(p, "model")) is Some(model) {
            state.model = Some(model)
          }
        } else if kind == Some("event_msg") && str(get(p, "type")) == Some("token_count") {
          let info = get(p, "info")
          let last = match info {
            None | Some(Null) => None
            _ => get(info, "last_token_usage")
          }
          guard last is Some(l) && !(l is Null) else { continue }
          let totals = get(info, "total_token_usage")
          let total = if totals is None { at } else { n(get(totals, "total_tokens")) }
          let sent = n(get(last, "input_tokens"))
          let cached = min_d(n(get(last, "cached_input_tokens")), sent)
          // Its time: from when it was asked to the last item it wrote; the next is asked from here on.
          let gen_ms = gen_of(state.speed.open_start, state.speed.ended)
          state.speed.open_start = None
          state.speed.ended = None
          state.speed.since = Some(at)
          out.push({
            id: "codex:" + state.codex_id.unwrap_or("") + ":" + js_number(total),
            at,
            model: state.model,
            subagent,
            fast: false,
            input: sent - cached,
            cache_read: cached,
            cache_write: 0.0,
            cache_write_long: 0.0,
            output: n(get(last, "output_tokens")),
            calls: 1.0,
            context: if subagent { None } else { Some(sent) },
            window: told(get(info, "model_context_window")),
            gen_ms,
          })
        }
      }
    }
  }
  out
}
