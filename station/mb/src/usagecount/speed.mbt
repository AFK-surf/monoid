// How long each call took, from when its model was asked to the last of what it wrote, as its transcript tells it
// (test/usage-counter-reference.ts `Speed`, which this is held to): Claude Code's from the line that asked (a person's
// message, a tool's result, a request sent) to each line of its response (a block written); Codex's from what asked
// (a turn begun, a person's message, a tool's output) to the last item it wrote before its token count. What Profile
// overview's 输出速度 is read of (usage.gen_ms, gen_output: store/usage-15m.ts). Where a reading stands is kept with the
// transcript's position (usage_files.speed), so that a response read in two parts is timed from its start.

///|
/// The longest a call is taken to have run: one longer is no call's alone (a pause the transcript does not tell).
let gen_most : Double = 1800000.0

///|
/// reference `Speed`.
pub(all) struct Speed {
  mut since : Double?
  mut open_start : Double?
  mut open_id : String?
  mut ended : Double?
}

///|
fn no_speed() -> Speed {
  { since: None, open_start: None, open_id: None, ended: None }
}

///|
/// usage_files.speed (reference `speedText`): the four, comma-separated, empty for none; None where none is known.
fn speed_text(s : Speed) -> String? {
  if s.since is None && s.open_start is None && s.open_id is None && s.ended is None {
    return None
  }
  let n = (v : Double?) => match v {
    Some(d) => js_number(d)
    None => ""
  }
  Some(n(s.since) + "," + n(s.open_start) + "," + n(s.ended) + "," + s.open_id.unwrap_or(""))
}

///|
/// usage_files.speed as this counter keeps it (reference `keptSpeed`): none known kept as `,,,` (`speed_of`: none), so
/// that NULL is only ever a transcript read before calls were timed, timed again as a counter starts.
fn kept_speed(s : Speed) -> String {
  speed_text(s).unwrap_or(",,,")
}

///|
/// reference `speedOf`.
fn speed_of(text : String?) -> Speed {
  guard text is Some(t) else { return no_speed() }
  let parts : Array[String] = t.split(",").map(p => p.to_owned()).collect()
  let id = if parts.length() > 3 { parts[3:].to_owned().join(",") } else { "" }
  {
    since: whole_ms(parts, 0),
    open_start: whole_ms(parts, 1),
    ended: whole_ms(parts, 2),
    open_id: if id == "" { None } else { Some(id) },
  }
}

///|
/// The `i`th of a speed's numbers: whole milliseconds, as `speed_text` writes them.
fn whole_ms(parts : Array[String], i : Int) -> Double? {
  if i >= parts.length() || parts[i] == "" {
    return None
  }
  let mut v = 0.0
  let mut sign = 1.0
  for c in parts[i] {
    if c == '-' {
      sign = -1.0
    } else if c >= '0' && c <= '9' {
      v = v * 10.0 + (c.to_int() - '0'.to_int()).to_double()
    } else {
      return None
    }
  }
  Some(sign * v)
}

///|
let timestamp_key : Bytes = b"\"timestamp\":\""

///|
let payload_key : Bytes = b"\"payload\":{\"type\":\""

///|
let api_request : Bytes = b"{\"type\":\"api-request\""

///|
let user_entry : Bytes = b"\"type\":\"user\",\"message\":{\"role\":\"user\""

///|
let response_item : Bytes = b"\"type\":\"response_item\""

///|
/// Where `p` first is in `b` (ASCII), from `from`.
fn index_of(b : BytesView, p : Bytes, from? : Int = 0) -> Int? {
  let m = p.length()
  let last = b.length() - m
  let mut i = from
  while i <= last {
    let mut j = 0
    while j < m && b[i + j] == p[j] {
      j += 1
    }
    if j == m {
      return Some(i)
    }
    i += 1
  }
  None
}

///|
/// The text after `key` up to its closing quote (reference `stampOf`'s and `payloadType`'s).
fn quoted_after(line : BytesView, key : Bytes) -> String? {
  guard index_of(line, key) is Some(at) else { return None }
  let start = at + key.length()
  let mut end = start
  while end < line.length() && line[end] != b'"' {
    end += 1
  }
  if end >= line.length() {
    return None
  }
  Some(@utf8.decode_lossy(line[start:end]))
}

///|
/// A line's own time (its first "timestamp"), where it says one.
fn stamp_of(line : BytesView) -> Double? {
  match quoted_after(line, timestamp_key) {
    Some(s) => parse_iso(s)
    None => None
  }
}

///|
/// The time from `start` to `end` as a call's, or 0: not known, or none a call takes alone.
fn gen_of(start : Double?, end : Double?) -> Double {
  match (start, end) {
    (Some(s), Some(e)) if e > s && e - s <= gen_most => e - s
    _ => 0.0
  }
}

///|
fn codex_asked(t : String) -> Bool {
  t == "task_started" ||
  t == "user_message" ||
  t == "function_call_output" ||
  t == "custom_tool_call_output" ||
  t == "local_shell_call_output"
}

///|
fn codex_writes(t : String) -> Bool {
  t == "reasoning" ||
  t == "function_call" ||
  t == "custom_tool_call" ||
  t == "local_shell_call" ||
  t == "web_search_call"
}

///|
/// When the model was asked, and (Codex) when it wrote, read of each line, those that hold no usage too.
fn speed_line(runtime : String, line : BytesView, speed : Speed) -> Unit {
  match runtime {
    "claude" =>
      if begins(line, api_request) || holds(line, user_entry) {
        if stamp_of(line) is Some(t) {
          speed.since = Some(t)
        }
      }
    "codex" =>
      match quoted_after(line, payload_key) {
        Some(t) if codex_asked(t) =>
          if stamp_of(line) is Some(at) {
            speed.since = Some(at)
          }
        Some(t) if codex_writes(t) ||
          (t == "message" &&
          holds(line, response_item) &&
          str(get(get(parse_line(@utf8.decode_lossy(line)), "payload"), "role")) == Some("assistant")) =>
          if stamp_of(line) is Some(at) {
            if speed.open_start is None {
              speed.open_start = speed.since
            }
            speed.ended = Some(at)
          }
        _ => ()
      }
    _ => ()
  }
}
